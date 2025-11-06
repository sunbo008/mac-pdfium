//
// macOS 原生前端（路线 B）：最小可用 PDF 渲染窗口
// - 启动后弹出选择 PDF，渲染到窗口
// - 支持 Home/End 翻页、PgUp/PgDn、Cmd +/- 缩放
//
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach.h>
#include <chrono>
#include <string>
#include <vector>
#include "../shared/logger.h"
#include "../shared/pdf_utils.h"
#include "../shared/pdfium_object_info.h"
#include "../shared/watermark_callback.h"  // [AP-FORM-IMAGE-WATERMARK]
#include "fpdfsdk/cpdfsdk_renderpage.h"    // [AP-FORM-IMAGE-WATERMARK]
#include "public/fpdf_annot.h"
#include "public/fpdf_doc.h"
#include "public/fpdf_edit.h"
#include "public/fpdf_text.h"
#include "public/fpdfview.h"

// 导入模块化组件
#import "Controllers/BookmarkDelegate.h"
#import "Controllers/BookmarkPanelController.h"
#import "Controllers/InspectorPanelController.h"
#import "Controllers/RecentFilesManager.h"
#import "Controllers/StatusBarController.h"
#import "Models/TocNode.h"
#import "Utils/LogManager.h"
#import "Utils/SettingsManager.h"
#import "Views/DragDropView.h"
#import "Views/PdfView.h"
#import "Views/SelectableTextView.h"

// ================= 界面布局常量 =================
static const CGFloat kBookmarkCollapsedWidth = 20.0;
static const CGFloat kBookmarkExpandedWidth = 260.0;
static const CGFloat kInspectorWidth = 300.0;
static const CGFloat kControlBarHeight = 30.0;
static const CGFloat kScrollBarWidth = 15.0;  // 垂直滚动条宽度

// ================= PDFium 错误辅助 =================
static inline void LogFPDFLastError(const char* where) {
  unsigned long code = FPDF_GetLastError();
  const char* msg = "Unknown";
  switch (code) {
    case FPDF_ERR_SUCCESS:
      msg = "SUCCESS";
      break;
    case FPDF_ERR_UNKNOWN:
      msg = "UNKNOWN";
      break;
    case FPDF_ERR_FILE:
      msg = "FILE";
      break;
    case FPDF_ERR_FORMAT:
      msg = "FORMAT";
      break;
    case FPDF_ERR_PASSWORD:
      msg = "PASSWORD";
      break;
    case FPDF_ERR_SECURITY:
      msg = "SECURITY";
      break;
    case FPDF_ERR_PAGE:
      msg = "PAGE";
      break;
    default:
      break;
  }
  NSLog(@"[PdfWinViewer] PDFium error at %s: %lu (%@)", where, code,
        [NSString stringWithUTF8String:msg]);
}

static inline std::string NSStringToUTF8(NSObject* obj) {
  if (!obj) {
    return {};
  }
  NSString* s = (NSString*)obj;
  return std::string([s UTF8String] ?: "");
}

@interface AppDelegate : NSObject <NSApplicationDelegate,
                                   NSOutlineViewDataSource,
                                   NSOutlineViewDelegate,
                                   PdfViewDelegate,
                                   NSSplitViewDelegate,
                                   NSTextViewDelegate,
                                   NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSSplitView* split;
@property(nonatomic, strong) NSOutlineView* outline;
@property(nonatomic, strong) NSScrollView* outlineScroll;
@property(nonatomic, strong) PdfView* view;
@property(nonatomic, strong) TocNode* tocRoot;
@property(nonatomic, strong) NSMutableArray<NSString*>* recentPaths;
@property(nonatomic, strong) NSMenu* recentMenu;
@property(nonatomic, strong) NSMenuItem* recentMenuItem;
@property(nonatomic, strong)
    NSMutableDictionary* settingsDict;  // 与 Windows 对齐的 settings.json 容器

// 底部状态栏相关属性
@property(nonatomic, strong) NSView* statusBar;
@property(nonatomic, strong) NSTextField* pageLabel;
@property(nonatomic, strong) NSTextField* pageInput;
@property(nonatomic, strong) NSTextField* totalPagesLabel;
@property(nonatomic, strong) NSButton* prevPageButton;
@property(nonatomic, strong) NSButton* nextPageButton;
@property(nonatomic, strong)
    NSView* mainContentView;  // 主内容区域（不包括状态栏）

// 书签控制栏相关属性
@property(nonatomic, strong) NSView* bookmarkControlBar;
@property(nonatomic, strong) NSButton* bookmarkToggleButton;
@property(nonatomic, strong) NSView* leftPanel;  // 左侧面板（包含控制栏和书签）
@property(nonatomic, assign) BOOL bookmarkVisible;  // 书签是否可见
@property(nonatomic, strong)
    NSView* expandedTopControlBar;  // 展开状态的顶部控制栏

// 右侧检查器面板相关属性
@property(nonatomic, strong)
    NSView* rightPanel;  // 右侧面板（包含PDF内容和检查器）
@property(nonatomic, strong) NSView* pdfContentView;  // PDF内容视图容器
@property(nonatomic, strong) NSView* inspectorPanel;  // 检查器面板
@property(nonatomic, strong)
    NSButton* inspectorToggleButton;  // 检查器展开/收起按钮
@property(nonatomic, assign) BOOL inspectorVisible;  // 检查器是否可见
@property(nonatomic, strong) NSTextView* inspectorTextView;  // 检查器文本视图
@property(nonatomic, strong)
    NSScrollView* inspectorScrollView;  // 检查器滚动视图
@property(nonatomic, strong)
    NSMutableDictionary* objectPositions;  // 对象号 -> 文本位置映射

// 页面查找功能
@property(nonatomic, strong) NSPanel* findPanel;          // 查找面板
@property(nonatomic, strong) NSTextField* findTextField;  // 查找输入框
@property(nonatomic, strong) NSString* lastSearchTerm;  // 上次查找的内容
@property(nonatomic, assign) NSInteger currentSearchIndex;  // 当前查找结果索引

// 模块化Controller
@property(nonatomic, strong) SettingsManager* settingsManager;
@property(nonatomic, strong) RecentFilesManager* recentFilesManager;
@property(nonatomic, strong) StatusBarController* statusBarController;
@property(nonatomic, strong) BookmarkPanelController* bookmarkPanelController;
@property(nonatomic, strong) InspectorPanelController* inspectorPanelController;
@property(nonatomic, strong) BookmarkDelegate* bookmarkDelegate;
@end

// 为在主实现中调用分类方法提供前置声明（命名分类，避免"primary
// class"重复实现告警）
@interface AppDelegate (ForwardDecls)
- (void)loadSettingsJSON;
- (void)extractRecentFromSettings;
- (void)rebuildRecentMenu;
- (void)persistRecentIntoSettings;
- (void)openPathAndAdjust:(NSString*)path;
- (void)createStatusBar;
- (void)updateStatusBar;
- (void)onPrevPage:(id)sender;
- (void)onNextPage:(id)sender;
- (void)onPageInputChanged:(id)sender;
- (void)createBookmarkControlBar;
- (void)toggleBookmarkVisibility:(id)sender;
- (void)setBookmarkVisible:(BOOL)visible animated:(BOOL)animated;
- (void)expandAllBookmarks:(id)sender;
- (void)collapseAllBookmarks:(id)sender;
- (void)highlightCurrentBookmark;
- (TocNode*)findBookmarkForPage:(int)pageIndex inNode:(TocNode*)node;
- (void)expandParentsOfItem:(TocNode*)item;
- (BOOL)findParentPathForItem:(TocNode*)targetItem
                       inNode:(TocNode*)currentNode
                   parentPath:(NSMutableArray*)path;
- (void)createExpandedBookmarkControls;
- (void)removeExpandedBookmarkControls;
- (void)updateBookmarkScrollView;
- (void)ensureBookmarkScrollBarVisible;
- (void)forceTraditionalScrollBar;
- (void)checkScrollBarOverlap;
- (void)ensureLeftPanelSize;
- (void)updateExpandedControlBarLayout;
- (void)createInspectorPanel;
- (void)toggleInspectorVisibility:(id)sender;
- (void)setInspectorVisible:(BOOL)visible animated:(BOOL)animated;
- (void)updateInspectorLayout;
- (void)displayObjectTreeNode:(PDFIUM_EX_OBJECT_TREE_NODE*)node
             attributedString:(NSMutableAttributedString*)attributedInfo
                  normalAttrs:(NSDictionary*)normalAttrs
                  objNumAttrs:(NSDictionary*)objNumAttrs;
- (void)updateInspectorContent;
- (void)handleShowWindowNotification:(NSNotification*)notification;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  // 注意：日志清理已移到 main() 函数开头，以保留单例检测日志
  NSRect rect = NSMakeRect(200, 200, 1200, 800);
  self.window = [[NSWindow alloc]
      initWithContentRect:rect
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable |
                           NSWindowStyleMaskMiniaturizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];

  // 确保窗口可见
  [self.window setBackgroundColor:[NSColor windowBackgroundColor]];
  [self.window setIsVisible:YES];
  [self.window setAlphaValue:1.0];
  NSLog(@"[Window] 窗口创建完成，frame: %@, visible: %@",
        NSStringFromRect(self.window.frame),
        self.window.isVisible ? @"YES" : @"NO");

  // 创建主容器视图，包含主内容区域和底部状态栏(支持拖拽打开PDF)
  DragDropView* containerView =
      [[DragDropView alloc] initWithFrame:self.window.contentView.bounds];
  containerView.appDelegate = self;
  containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // ========== 初始化模块化Controller ==========
  // 1. 设置管理器
  self.settingsManager = [[SettingsManager alloc] init];
  [self.settingsManager loadSettingsJSON];
  [self.settingsManager extractRecentFromSettings];

  // 创建主内容区域（占据除状态栏外的所有空间）
  self.mainContentView = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 30, rect.size.width, rect.size.height - 30)];
  self.mainContentView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [containerView addSubview:self.mainContentView];

  // 2. 状态栏控制器
  self.statusBarController = [[StatusBarController alloc] init];
  self.statusBarController.appDelegate = self;
  [self.statusBarController createStatusBar];
  self.statusBar = self.statusBarController.statusBar;
  self.statusBar.frame = NSMakeRect(0, 0, rect.size.width, 30);
  self.statusBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [containerView addSubview:self.statusBar];
  NSLog(@"[StatusBar] 状态栏已添加到容器视图，frame: %@",
        NSStringFromRect(self.statusBar.frame));

  // 初始化书签可见性状态（默认展开）
  self.bookmarkVisible = YES;

  // 左侧书签，右侧渲染（在主内容区域内）
  self.split = [[NSSplitView alloc] initWithFrame:self.mainContentView.bounds];
  self.split.dividerStyle = NSSplitViewDividerStyleThin;
  self.split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.split.delegate = self;    // 设置委托以监听宽度变化
  [self.split setVertical:YES];  // 左右分栏：左侧书签，右侧内容

  // 创建左侧面板（包含顶部控制栏和书签区域）
  CGFloat initialWidth = kBookmarkExpandedWidth;  // 默认展开状态
  self.leftPanel = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, initialWidth,
                               self.mainContentView.bounds.size.height)];

  // 创建右侧面板（包含PDF内容和检查器面板）
  CGFloat rightPanelX = initialWidth;
  CGFloat rightPanelWidth =
      self.mainContentView.bounds.size.width - initialWidth;
  self.rightPanel = [[NSView alloc]
      initWithFrame:NSMakeRect(rightPanelX, 0, rightPanelWidth,
                               self.mainContentView.bounds.size.height)];

  // 初始化检查器可见性状态（默认收起）
  self.inspectorVisible = NO;

  // 3. 书签面板控制器
  self.bookmarkPanelController = [[BookmarkPanelController alloc] init];
  self.bookmarkPanelController.appDelegate = self;
  self.bookmarkPanelController.leftPanel = self.leftPanel;
  self.bookmarkPanelController.bookmarkVisible = self.bookmarkVisible;
  [self.bookmarkPanelController createBookmarkControlBar];
  self.bookmarkControlBar = self.bookmarkPanelController.bookmarkControlBar;

  // 由于默认展开，直接创建展开状态的控件并隐藏收起状态的控制栏
  [self.bookmarkPanelController createExpandedBookmarkControls];

  // 隐藏收起状态的控制栏（因为默认展开）
  self.bookmarkControlBar.hidden = YES;

  // Outline（书签区域，位于控制栏下方，初始时隐藏）
  // 为滚动条预留空间，outline的宽度应该小于滚动视图的宽度
  CGFloat outlineWidth =
      kBookmarkExpandedWidth - kScrollBarWidth;  // 为滚动条预留空间
  NSRect outlineFrame =
      NSMakeRect(0, 0, outlineWidth,
                 self.leftPanel.bounds.size.height - kControlBarHeight);
  NSLog(@"[ScrollDebug] outline宽度: %.1f (预留滚动条空间: %.1f)", outlineWidth,
        kScrollBarWidth);

  self.outline = [[NSOutlineView alloc] initWithFrame:outlineFrame];
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"toc"];
  col.title = @"书签";
  col.width = outlineWidth - 20;  // 为滚动条和边距预留空间
  col.minWidth = 100;
  col.maxWidth = outlineWidth - 10;
  NSLog(@"[ScrollDebug] 表格列宽度: %.1f", col.width);
  [self.outline addTableColumn:col];
  self.outline.outlineTableColumn = col;
  self.outline.headerView = nil;
  self.outline.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.outline.rowSizeStyle = NSTableViewRowSizeStyleDefault;
  self.outline.allowsEmptySelection = YES;    // 允许空选择
  self.outline.allowsMultipleSelection = NO;  // 禁用多选

  // 4. 书签委托（设置为outline的dataSource和delegate）
  self.bookmarkDelegate = [[BookmarkDelegate alloc] init];
  self.bookmarkDelegate.appDelegate = self;
  self.bookmarkDelegate.outline = self.outline;
  self.bookmarkDelegate.outlineScroll = self.outlineScroll;  // 将在后面初始化
  self.bookmarkDelegate.tocRoot = self.tocRoot;
  self.outline.delegate = self.bookmarkDelegate;
  self.outline.dataSource = self.bookmarkDelegate;

  NSLog(@"[ScrollDebug] ========== 初始化书签滚动视图 ==========");
  NSLog(@"[ScrollDebug] outlineFrame: %@", NSStringFromRect(outlineFrame));

  // 滚动视图应该占据整个展开宽度，为滚动条提供空间
  NSRect scrollFrame =
      NSMakeRect(0, 0, kBookmarkExpandedWidth,
                 self.leftPanel.bounds.size.height - kControlBarHeight);
  NSLog(@"[ScrollDebug] scrollFrame: %@", NSStringFromRect(scrollFrame));

  self.outlineScroll = [[NSScrollView alloc] initWithFrame:scrollFrame];
  self.outlineScroll.documentView = self.outline;

  NSLog(@"[ScrollDebug] 滚动视图创建完成，frame: %@",
        NSStringFromRect(self.outlineScroll.frame));

  // 垂直滚动条配置 - 确保始终可见且功能正常
  self.outlineScroll.hasVerticalScroller = YES;
  self.outlineScroll.hasHorizontalScroller =
      NO;  // 禁用水平滚动条，避免占用空间
  self.outlineScroll.autohidesScrollers =
      NO;  // 始终显示滚动条，提供更好的用户反馈

  NSLog(@"[ScrollDebug] 基本滚动条配置完成 - hasVertical: YES, hasHorizontal: "
        @"NO, autohides: NO");

  // 为了调试，暂时使用传统滚动条样式，更容易看到
  self.outlineScroll.scrollerStyle =
      NSScrollerStyleLegacy;  // 传统滚动条，更明显可见
  NSLog(@"[ScrollDebug] 使用传统滚动条样式: NSScrollerStyleLegacy (调试模式)");

  // 滚动行为优化
  self.outlineScroll.verticalScrollElasticity =
      NSScrollElasticityAllowed;  // 允许弹性滚动
  self.outlineScroll.horizontalScrollElasticity =
      NSScrollElasticityNone;                  // 禁用水平弹性滚动
  self.outlineScroll.borderType = NSNoBorder;  // 无边框，更简洁
  self.outlineScroll.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;

  NSLog(@"[ScrollDebug] 滚动行为配置完成");

  // 检查初始滚动条状态
  NSScroller* initialVScroller = self.outlineScroll.verticalScroller;
  if (initialVScroller) {
    NSLog(@"[ScrollDebug] ✅ 初始垂直滚动条已创建");
    NSLog(@"[ScrollDebug] 初始滚动条 frame: %@",
          NSStringFromRect(initialVScroller.frame));
    NSLog(@"[ScrollDebug] 初始滚动条 hidden: %@",
          initialVScroller.hidden ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] 初始滚动条 enabled: %@",
          initialVScroller.enabled ? @"YES" : @"NO");

    // 滚动条宽度和位置优化
    initialVScroller.controlSize = NSControlSizeRegular;
    NSLog(@"[ScrollDebug] 滚动条控件大小设置为 Regular");
  } else {
    NSLog(@"[ScrollDebug] ❌ 初始垂直滚动条未创建！");
  }

  // 确保滚动视图内容正确更新
  [self.outlineScroll setNeedsDisplay:YES];

  self.outlineScroll.hidden = NO;  // 默认显示
  NSLog(@"[ScrollDebug] 滚动视图设置为显示状态");

  [self.leftPanel addSubview:self.outlineScroll];
  NSLog(@"[ScrollDebug] 滚动视图已添加到左侧面板");

  // 更新bookmarkDelegate和bookmarkPanelController的outlineScroll引用
  self.bookmarkDelegate.outlineScroll = self.outlineScroll;
  self.bookmarkPanelController.outlineScroll = self.outlineScroll;
  self.bookmarkPanelController.outline = self.outline;

  // 检查视图层次结构
  NSLog(@"[ScrollDebug] leftPanel frame: %@",
        NSStringFromRect(self.leftPanel.frame));
  NSLog(@"[ScrollDebug] leftPanel subviews count: %lu",
        (unsigned long)self.leftPanel.subviews.count);
  for (NSUInteger i = 0; i < self.leftPanel.subviews.count; i++) {
    NSView* subview = self.leftPanel.subviews[i];
    NSLog(@"[ScrollDebug] leftPanel subview[%lu]: %@ frame: %@",
          (unsigned long)i, NSStringFromClass([subview class]),
          NSStringFromRect(subview.frame));
  }

  NSLog(@"[ScrollDebug] ========== 书签滚动视图初始化完成 ==========");

  // 5. 检查器面板控制器
  self.inspectorPanelController = [[InspectorPanelController alloc] init];
  self.inspectorPanelController.appDelegate = self;
  self.inspectorPanelController.rightPanel = self.rightPanel;
  self.inspectorPanelController.inspectorVisible = self.inspectorVisible;
  [self.inspectorPanelController createInspectorPanel];
  self.inspectorPanel = self.inspectorPanelController.inspectorPanel;
  self.inspectorTextView = self.inspectorPanelController.inspectorTextView;

  // 在右侧面板内创建PDF内容视图和检查器的分割视图
  NSSplitView* rightSplit =
      [[NSSplitView alloc] initWithFrame:self.rightPanel.bounds];
  rightSplit.dividerStyle = NSSplitViewDividerStyleThin;
  rightSplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  rightSplit.delegate = self;  // 设置委托以控制最小宽度
  [rightSplit setVertical:YES];  // 左右分栏：左侧PDF内容，右侧检查器

  // 创建PDF内容视图容器
  CGFloat pdfContentWidth = self.rightPanel.bounds.size.width -
                            (self.inspectorVisible ? kInspectorWidth : 0);
  self.pdfContentView = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, pdfContentWidth,
                               self.rightPanel.bounds.size.height)];
  self.pdfContentView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;

  // 创建PDF视图
  self.view = [[PdfView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  self.view.delegate = self;

  // 现在PdfView已创建，设置需要它的Controller
  self.statusBarController.pdfView = self.view;
  self.bookmarkDelegate.pdfView = self.view;
  self.inspectorPanelController.pdfView = self.view;

  NSScrollView* scroll =
      [[NSScrollView alloc] initWithFrame:self.pdfContentView.bounds];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = YES;
  scroll.borderType = NSNoBorder;
  scroll.documentView = self.view;
  [self.pdfContentView addSubview:scroll];

  // 将PDF内容视图和检查器面板添加到右侧分割视图
  [rightSplit addSubview:self.pdfContentView];
  [rightSplit addSubview:self.inspectorPanel];

  // 保存 rightSplit 的引用（用于 delegate 方法中识别）
  // 注意：由于 rightSplit 是局部变量，我们通过判断 splitView 是否在 rightPanel
  // 的子视图中来识别

  // 设置初始分割位置（检查器默认收起，完全隐藏）
  [rightSplit setPosition:self.rightPanel.bounds.size.width ofDividerAtIndex:0];

  // 初始状态下隐藏检查器面板（即使有宽度也不显示）
  self.inspectorPanel.hidden = YES;

  [self.rightPanel addSubview:rightSplit];

  // 添加悬浮的检查器展开/收起按钮到右侧面板（在滚动条上方，独立悬浮）
  CGFloat buttonWidth = kBookmarkCollapsedWidth * 1.5;  // 调大50%
  CGFloat buttonHeight = kControlBarHeight * 1.5;       // 调大50%
  CGFloat buttonY = (self.rightPanel.bounds.size.height - buttonHeight) / 2;
  // 滚动条宽度约为15-20px，按钮距离右边缘需要避开滚动条
  CGFloat scrollBarWidth = 15.0;  // 滚动条宽度
  CGFloat buttonX = self.rightPanel.bounds.size.width - buttonWidth -
                    scrollBarWidth;  // 距离滚动条2像素
  self.inspectorToggleButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(buttonX, buttonY, buttonWidth, buttonHeight)];
  self.inspectorToggleButton.title = @"◀";
  self.inspectorToggleButton.font =
      [NSFont systemFontOfSize:21];          // 字体也调大50%（14 * 1.5）
  self.inspectorToggleButton.bordered = NO;  // 无边框，悬浮效果
  self.inspectorToggleButton.bezelStyle =
      NSBezelStyleTexturedSquare;  // 使用最简单的样式
  // 设置按钮样式为悬浮效果
  self.inspectorToggleButton.wantsLayer = YES;
  self.inspectorToggleButton.layer.backgroundColor =
      [[NSColor clearColor] CGColor];
  self.inspectorToggleButton.layer.cornerRadius = 4.0;
  self.inspectorToggleButton.layer.borderWidth = 0.0;  // 移除边框
  self.inspectorToggleButton.layer.borderColor =
      [[NSColor clearColor] CGColor];  // 边框颜色设为透明
  self.inspectorToggleButton.layer.shadowOpacity = 0.0;
  self.inspectorToggleButton.layer.shadowRadius = 0.0;
  self.inspectorToggleButton.layer.shadowOffset = NSZeroSize;
  // 设置按钮的 cell 背景为透明
  if ([self.inspectorToggleButton.cell
          respondsToSelector:@selector(setBackgroundColor:)]) {
    [self.inspectorToggleButton.cell setBackgroundColor:[NSColor clearColor]];
  }
  self.inspectorToggleButton.target = self;
  self.inspectorToggleButton.action = @selector(toggleInspectorVisibility:);
  self.inspectorToggleButton.autoresizingMask =
      NSViewMinXMargin | NSViewMaxYMargin | NSViewMinYMargin;
  // 将按钮添加到 rightPanel，并确保它在 rightSplit 上方（不被遮挡）
  [self.rightPanel addSubview:self.inspectorToggleButton
                   positioned:NSWindowAbove
                   relativeTo:rightSplit];

  [self.split addSubview:self.leftPanel];
  [self.split addSubview:self.rightPanel];
  [self.split setPosition:initialWidth ofDividerAtIndex:0];  // 默认显示展开宽度
  [self.mainContentView addSubview:self.split];

  // 设置容器视图为窗口的内容视图
  self.window.contentView = containerView;
  NSLog(@"[StatusBar] 容器视图设置为窗口内容视图，容器frame: %@",
        NSStringFromRect(containerView.frame));
  NSLog(@"[StatusBar] 窗口contentView: %@", self.window.contentView);
  [self.window setTitle:@"PdfWinViewer (macOS)"];

  // 确保窗口可见并显示在前台
  [self.window setReleasedWhenClosed:NO];
  [self.window center];
  [NSApp activateIgnoringOtherApps:YES];
  [self.window makeKeyAndOrderFront:nil];
  [self.window orderFrontRegardless];

  NSLog(@"[Window] 窗口已显示，frame: %@", NSStringFromRect(self.window.frame));

  // 设置窗口关闭时退出应用
  self.window.delegate = self;

  // 构建主菜单（应用/文件/编辑/视图）并设置为主菜单
  NSMenu* mainMenu = [NSMenu new];
  // App 菜单
  NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:@"App"
                                                   action:nil
                                            keyEquivalent:@""];
  NSMenu* appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"关于 PdfWinViewer" action:nil keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"退出"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  [appItem setSubmenu:appMenu];
  [mainMenu addItem:appItem];

  // 文件菜单
  NSMenuItem* fileItem = [[NSMenuItem alloc] initWithTitle:@"文件"
                                                    action:nil
                                             keyEquivalent:@""];
  NSMenu* fileMenu = [NSMenu new];
  NSMenuItem* openItem = [fileMenu addItemWithTitle:@"打开…"
                                             action:@selector(openDocument:)
                                      keyEquivalent:@"o"];
  openItem.target = self;
  NSMenuItem* exportItem = [fileMenu addItemWithTitle:@"导出当前页为 PNG"
                                               action:@selector(exportPNG:)
                                        keyEquivalent:@"e"];
  exportItem.target = self;
  exportItem.tag = 9901;  // 用于后续查找
  [exportItem setEnabled:NO];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  // 最近浏览子菜单
  self.recentMenuItem = [[NSMenuItem alloc] initWithTitle:@"最近浏览"
                                                   action:nil
                                            keyEquivalent:@""];
  self.recentMenu = [NSMenu new];
  [self.recentMenuItem setSubmenu:self.recentMenu];
  [fileMenu addItem:self.recentMenuItem];
  NSLog(
      @"[PdfWinViewer] File menu constructed. recentMenuItem=%@ recentMenu=%@",
      self.recentMenuItem, self.recentMenu);
  // 调试：枚举文件菜单条目
  for (NSInteger i = 0; i < fileMenu.numberOfItems; ++i) {
    NSMenuItem* mi = [fileMenu itemAtIndex:i];
    NSLog(@"[PdfWinViewer] File menu item[%ld]: title='%@' hasSubmenu=%@ "
          @"action=%@",
          (long)i, mi.title, (mi.submenu ? @"YES" : @"NO"),
          NSStringFromSelector(mi.action));
  }
  [fileItem setSubmenu:fileMenu];
  [mainMenu addItem:fileItem];

  // 编辑菜单
  NSMenuItem* editItem = [[NSMenuItem alloc] initWithTitle:@"编辑"
                                                    action:nil
                                             keyEquivalent:@""];
  NSMenu* editMenu = [NSMenu new];
  [editMenu addItemWithTitle:@"复制"
                      action:@selector(copy:)
               keyEquivalent:@"c"];
  [editItem setSubmenu:editMenu];
  [mainMenu addItem:editItem];

  // 视图/导航菜单
  NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"视图"
                                                    action:nil
                                             keyEquivalent:@""];
  NSMenu* viewMenu = [NSMenu new];
  NSMenuItem* zoomInItem = [viewMenu addItemWithTitle:@"放大"
                                               action:@selector(zoomIn:)
                                        keyEquivalent:@"="];
  zoomInItem.target = self.view;
  NSMenuItem* zoomOutItem = [viewMenu addItemWithTitle:@"缩小"
                                                action:@selector(zoomOut:)
                                         keyEquivalent:@"-"];
  zoomOutItem.target = self.view;
  NSMenuItem* zoomActualItem = [viewMenu addItemWithTitle:@"实际大小"
                                                   action:@selector(zoomActual:)
                                            keyEquivalent:@"0"];
  zoomActualItem.target = self.view;
  [viewMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* homeItem = [viewMenu addItemWithTitle:@"第一页"
                                             action:@selector(goHome:)
                                      keyEquivalent:@""];
  homeItem.target = self.view;
  NSMenuItem* endItem = [viewMenu addItemWithTitle:@"最后一页"
                                            action:@selector(goEnd:)
                                     keyEquivalent:@""];
  endItem.target = self.view;
  NSMenuItem* prevItem = [viewMenu addItemWithTitle:@"上一页"
                                             action:@selector(goPrevPage:)
                                      keyEquivalent:@"["];
  prevItem.target = self.view;
  NSMenuItem* nextItem = [viewMenu addItemWithTitle:@"下一页"
                                             action:@selector(goNextPage:)
                                      keyEquivalent:@"]"];
  nextItem.target = self.view;
  NSMenuItem* gotoItem = [viewMenu addItemWithTitle:@"跳转页…"
                                             action:@selector(gotoPage:)
                                      keyEquivalent:@"g"];
  gotoItem.target = self.view;
  [viewMenu addItem:[NSMenuItem separatorItem]];
  // 日志窗口入口
  NSMenuItem* logItem = [viewMenu addItemWithTitle:@"日志"
                                            action:@selector(openLogWindow:)
                                     keyEquivalent:@"l"];
  logItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  logItem.target = self;
  [viewItem setSubmenu:viewMenu];
  [mainMenu addItem:viewItem];

  [NSApp setMainMenu:mainMenu];
  // 移除窗口顶部"黑块"来源：不给 window.contentView 额外填充视图，直接使用
  // splitView； 当前实现中黑块通常来自未初始化的上方填充或 titlebar
  // 自定义区域，这里无需额外处理。

  // 启动时设定 first responder，确保菜单快捷键能落到 PdfView
  [self.window makeFirstResponder:self.view];

  // 6. 最近文件管理器（需要在菜单创建之后初始化）
  self.recentFilesManager = [[RecentFilesManager alloc] init];
  self.recentFilesManager.appDelegate = self;
  self.recentFilesManager.settingsManager = self.settingsManager;
  self.recentFilesManager.recentMenu = self.recentMenu;
  self.recentFilesManager.recentMenuItem = self.recentMenuItem;
  [self.recentFilesManager rebuildRecentMenu];
  // 初始时禁用"导出"
  NSMenuItem* exp = [fileMenu itemWithTag:9901];
  if (exp) {
    [exp setEnabled:NO];
  }

  // 由于默认展开书签，需要确保布局正确
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"[ScrollDebug] 初始化后更新展开状态布局...");
    [self ensureLeftPanelSize];
    [self updateExpandedControlBarLayout];
    [self forceTraditionalScrollBar];
    [self updateBookmarkScrollView];
    [self ensureBookmarkScrollBarVisible];
  });

  // 添加全局键盘事件监听，确保PageUp/PageDown总是控制PDF翻页，并支持cmd+f查找
  [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                        handler:^NSEvent* _Nullable(
                                            NSEvent* _Nonnull event) {
                                          return
                                              [self handleGlobalKeyDown:event];
                                        }];
  MacLog_DebugNS(@"[GlobalKey] 全局键盘事件监听已设置");

  // 诊断信息
  MacLog_DebugNS(@"========================================");
  MacLog_DebugNS(@"[AppInit] applicationDidFinishLaunching 完成");
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[AppInit] self.window = %@", self.window]);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[AppInit] self.view = %@", self.view]);
  MacLog_DebugNS([NSString
      stringWithFormat:@"[AppInit] NSApp.delegate = %@", NSApp.delegate]);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[AppInit] 菜单项数量 = %ld",
                                 (long)[NSApp.mainMenu numberOfItems]]);
  MacLog_DebugNS(@"[AppInit] 应用已准备就绪，可以通过菜单或拖拽打开PDF文件");
  MacLog_DebugNS(@"========================================");
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
    (NSApplication*)sender {
  FPDF_DestroyLibrary();
  return NSTerminateNow;
}

// 当最后一个窗口关闭时退出应用
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  return YES;
}

#pragma mark - Global Keyboard Event Handling

- (NSEvent*)handleGlobalKeyDown:(NSEvent*)event {
  NSString* chars = [event charactersIgnoringModifiers];
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

  // 处理cmd+f查找功能
  if (c == 'f' && (mods & NSEventModifierFlagCommand)) {
    NSLog(@"[GlobalKey] 拦截到Cmd+F，显示查找面板");
    [self showFindPanel];
    return nil;  // 消费事件
  }

  // 拦截翻页相关的键盘事件，总是路由到PDF视图
  BOOL isPageNavigationKey = NO;

  if (c == NSPageUpFunctionKey || c == NSPageDownFunctionKey) {
    isPageNavigationKey = YES;
    NSLog(@"[GlobalKey] 拦截到%@键",
          c == NSPageUpFunctionKey ? @"PageUp" : @"PageDown");
  } else if (c == NSHomeFunctionKey || c == NSEndFunctionKey) {
    isPageNavigationKey = YES;
    NSLog(@"[GlobalKey] 拦截到%@键", c == NSHomeFunctionKey ? @"Home" : @"End");
  } else if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey) {
    // 只有在没有修饰键时才拦截箭头键（避免影响其他功能）
    if (mods == 0) {
      isPageNavigationKey = YES;
      NSLog(@"[GlobalKey] 拦截到%@箭头键",
            c == NSUpArrowFunctionKey ? @"上" : @"下");
    }
  }

  if (isPageNavigationKey) {
    NSLog(@"[GlobalKey] 路由翻页键到PDF视图");

    // 直接调用PDF视图的键盘处理
    if (self.view && [self.view respondsToSelector:@selector(keyDown:)]) {
      [self.view keyDown:event];
      return nil;  // 消费事件，不再传递
    }
  }

  return event;  // 其他键盘事件正常传递
}

#pragma mark - Find Panel Implementation

// 显示查找面板
- (void)showFindPanel {
  if (!self.findPanel) {
    // 创建查找面板
    NSRect panelFrame = NSMakeRect(0, 0, 300, 80);
    self.findPanel =
        [[NSPanel alloc] initWithContentRect:panelFrame
                                   styleMask:(NSWindowStyleMaskTitled |
                                              NSWindowStyleMaskClosable)
                                     backing:NSBackingStoreBuffered
                                       defer:NO];
    self.findPanel.title = @"在检查器中查找";
    self.findPanel.level = NSFloatingWindowLevel;

    // 创建查找输入框
    NSRect textFieldFrame = NSMakeRect(20, 30, 200, 25);
    self.findTextField = [[NSTextField alloc] initWithFrame:textFieldFrame];
    self.findTextField.placeholderString = @"在页面元素窗口中查找...";
    self.findTextField.target = self;
    self.findTextField.action = @selector(performFind:);

    // 创建查找按钮
    NSRect findButtonFrame = NSMakeRect(230, 30, 50, 25);
    NSButton* findButton = [[NSButton alloc] initWithFrame:findButtonFrame];
    findButton.title = @"查找";
    findButton.target = self;
    findButton.action = @selector(performFind:);
    findButton.keyEquivalent = @"\r";  // Enter键

    [self.findPanel.contentView addSubview:self.findTextField];
    [self.findPanel.contentView addSubview:findButton];
  }

  // 显示面板并聚焦输入框
  [self.findPanel center];
  [self.findPanel makeKeyAndOrderFront:nil];
  [self.findPanel makeFirstResponder:self.findTextField];
}

// 执行查找
- (void)performFind:(id)sender {
  NSString* searchTerm = self.findTextField.stringValue;
  if (!searchTerm || searchTerm.length == 0) {
    return;
  }

  // 检查检查器是否可见和可用
  if (!self.inspectorVisible || !self.inspectorTextView) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"查找提示";
    alert.informativeText = @"请先打开检查器窗口（右侧面板）";
    [alert addButtonWithTitle:@"确定"];
    [alert runModal];
    return;
  }

  NSString* inspectorText = self.inspectorTextView.string;
  if (!inspectorText || inspectorText.length == 0) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"查找提示";
    alert.informativeText = @"检查器窗口中没有内容可搜索";
    [alert addButtonWithTitle:@"确定"];
    [alert runModal];
    return;
  }

  // 检查是否是新的搜索词
  NSRange searchRange;
  if (![searchTerm isEqualToString:self.lastSearchTerm]) {
    self.lastSearchTerm = searchTerm;
    self.currentSearchIndex = 0;
    searchRange = NSMakeRange(0, inspectorText.length);
  } else {
    // 从上次找到的位置之后开始搜索
    NSUInteger startPos =
        self.currentSearchIndex + [self.lastSearchTerm length];
    if (startPos >= inspectorText.length) {
      // 到达末尾，从头开始
      startPos = 0;
    }
    searchRange = NSMakeRange(startPos, inspectorText.length - startPos);
  }

  // 在检查器文本中查找
  NSRange foundRange = [inspectorText rangeOfString:searchTerm
                                            options:NSCaseInsensitiveSearch
                                              range:searchRange];

  if (foundRange.location != NSNotFound) {
    // 找到了，更新索引并高亮显示
    self.currentSearchIndex = foundRange.location;

    // 滚动到找到的位置并高亮显示
    [self.inspectorTextView scrollRangeToVisible:foundRange];
    [self.inspectorTextView setSelectedRange:foundRange];
    [self.inspectorTextView showFindIndicatorForRange:foundRange];

    NSLog(@"[Find] 在检查器中找到文本: %@ at 位置: %lu", searchTerm,
          foundRange.location);
  } else if (self.currentSearchIndex > 0) {
    // 没找到，尝试从头开始搜索
    foundRange =
        [inspectorText rangeOfString:searchTerm
                             options:NSCaseInsensitiveSearch
                               range:NSMakeRange(0, inspectorText.length)];
    if (foundRange.location != NSNotFound) {
      self.currentSearchIndex = foundRange.location;
      [self.inspectorTextView scrollRangeToVisible:foundRange];
      [self.inspectorTextView setSelectedRange:foundRange];
      [self.inspectorTextView showFindIndicatorForRange:foundRange];
      NSLog(@"[Find] 在检查器中找到文本（从头开始）: %@ at 位置: %lu",
            searchTerm, foundRange.location);
    } else {
      // 真的没找到
      [self showNotFoundAlert:searchTerm];
    }
  } else {
    // 没找到
    [self showNotFoundAlert:searchTerm];
  }
}

// 显示未找到文本的提示
- (void)showNotFoundAlert:(NSString*)searchTerm {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"查找结果";
  alert.informativeText =
      [NSString stringWithFormat:@"在检查器窗口中未找到文本: %@", searchTerm];
  [alert addButtonWithTitle:@"确定"];
  [alert runModal];
  NSLog(@"[Find] 在检查器中未找到文本: %@", searchTerm);
}

// 为对象引用着色的辅助方法
- (NSMutableAttributedString*)colorizeObjectReferences:(NSString*)text
                                           normalAttrs:
                                               (NSDictionary*)normalAttrs {
  NSMutableAttributedString* result =
      [[NSMutableAttributedString alloc] initWithString:text
                                             attributes:normalAttrs];

  // 创建绿色属性
  NSDictionary* greenAttrs = @{
    NSForegroundColorAttributeName : [NSColor systemGreenColor],
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12
                                                      weight:NSFontWeightBold]
  };

  // 查找所有对象引用（格式：数字 0 R）
  NSError* error = nil;
  NSRegularExpression* regex = [NSRegularExpression
      regularExpressionWithPattern:@"\\b(\\d+)\\s+0\\s+R\\b"
                           options:0
                             error:&error];
  if (error) {
    NSLog(@"[Inspector] 对象引用正则表达式错误: %@",
          error.localizedDescription);
    return result;
  }

  // 应用绿色到所有匹配的对象引用
  [regex enumerateMatchesInString:text
                          options:0
                            range:NSMakeRange(0, text.length)
                       usingBlock:^(NSTextCheckingResult* match,
                                    NSMatchingFlags flags, BOOL* stop) {
                         NSRange matchRange = [match range];
                         [result setAttributes:greenAttrs range:matchRange];
                       }];

  return result;
}

// PDF视图对象点击处理
- (void)pdfViewDidClickObject:(NSValue*)objectValue atIndex:(NSNumber*)index {
  NSLog(@"[Inspector] PDF视图点击了对象，索引: %@", index);

  // 从NSValue中提取FPDF_PAGEOBJECT
  FPDF_PAGEOBJECT object = (FPDF_PAGEOBJECT)[objectValue pointerValue];

  // 这里我们需要将FPDF_PAGEOBJECT映射到实际的PDF对象号
  // 由于这比较复杂，我们先简单地刷新检查器内容，然后尝试跳转到相关对象
  [self updateInspectorContent];

  // TODO: 实现更精确的对象映射和跳转
  NSLog(@"[Inspector] 已刷新检查器内容以响应PDF对象点击");
}

#pragma mark - 桥接方法（转发到Controller）

// 书签相关桥接方法
- (void)rebuildToc {
  [self.bookmarkDelegate rebuildToc];
}

- (void)highlightCurrentBookmark {
  [self.bookmarkDelegate highlightCurrentBookmark];
}

// 状态栏相关桥接方法
- (void)updateStatusBar {
  [self.statusBarController updateStatusBar];
}

// 最近文件相关桥接方法
- (void)addRecentPath:(NSString*)path {
  [self.recentFilesManager addRecentPath:path];
}

- (IBAction)openRecent:(id)sender {
  [self.recentFilesManager openRecent:sender];
}

- (IBAction)clearRecent:(id)sender {
  [self.recentFilesManager clearRecent:sender];
}

// 书签面板相关桥接方法
- (void)toggleBookmarkVisibility:(id)sender {
  [self.bookmarkPanelController toggleBookmarkVisibility:sender];
}

- (void)expandAllBookmarks:(id)sender {
  [self.bookmarkPanelController expandAllBookmarks:sender];
}

- (void)collapseAllBookmarks:(id)sender {
  [self.bookmarkPanelController collapseAllBookmarks:sender];
}

- (void)updateBookmarkScrollView {
  [self.bookmarkPanelController updateBookmarkScrollView];
}

- (void)ensureBookmarkScrollBarVisible {
  [self.bookmarkPanelController ensureBookmarkScrollBarVisible];
}

- (void)forceTraditionalScrollBar {
  [self.bookmarkPanelController forceTraditionalScrollBar];
}

- (void)ensureLeftPanelSize {
  [self.bookmarkPanelController ensureLeftPanelSize];
}

- (void)updateExpandedControlBarLayout {
  [self.bookmarkPanelController updateExpandedControlBarLayout];
}

// 检查器面板相关桥接方法
- (void)toggleInspectorVisibility:(id)sender {
  [self.inspectorPanelController toggleInspectorVisibility:sender];
}

- (void)updateInspectorContent {
  [self.inspectorPanelController updateInspectorContent];
}

@end

#pragma mark - TOC (Outline) - 已迁移到BookmarkDelegate
/*
@implementation AppDelegate (TOC)

- (void)rebuildToc {
  FPDF_DOCUMENT doc = [self.view document];
  if (!doc) {
    self.tocRoot = nil;
    [self.outline reloadData];
    return;
  }
  self.tocRoot = BuildBookmarksTree(doc);
  [self.outline reloadData];
  // 默认折叠所有顶层书签
  [self.outline collapseItem:nil collapseChildren:YES];
  NSLog(@"[BookmarkControl] 书签重建完成，默认折叠所有顶层书签");

  // 确保滚动条正确更新
  [self updateBookmarkScrollView];
  [self ensureBookmarkScrollBarVisible];
}

- (void)updateBookmarkScrollView {
  NSLog(@"[ScrollDebug] ========== updateBookmarkScrollView 开始 ==========");

  // 强制更新滚动视图的内容大小和滚动条
  if (self.outlineScroll && !self.outlineScroll.hidden) {
    NSLog(@"[ScrollDebug] 滚动视图存在且未隐藏");

    // 打印滚动视图基本信息
    NSLog(@"[ScrollDebug] outlineScroll frame: %@",
          NSStringFromRect(self.outlineScroll.frame));
    NSLog(@"[ScrollDebug] outlineScroll bounds: %@",
          NSStringFromRect(self.outlineScroll.bounds));
    NSLog(@"[ScrollDebug] outlineScroll superview: %@",
          self.outlineScroll.superview);
    NSLog(@"[ScrollDebug] outlineScroll hidden: %@",
          self.outlineScroll.hidden ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] outlineScroll alphaValue: %.2f",
          self.outlineScroll.alphaValue);

    // 确保outline view布局正确
    [self.outline setNeedsLayout:YES];
    [self.outline layoutSubtreeIfNeeded];

    // 打印outline view信息
    NSLog(@"[ScrollDebug] outline frame: %@",
          NSStringFromRect(self.outline.frame));
    NSLog(@"[ScrollDebug] outline bounds: %@",
          NSStringFromRect(self.outline.bounds));
    NSLog(@"[ScrollDebug] outline numberOfRows: %ld",
          (long)[self.outline numberOfRows]);
    NSLog(@"[ScrollDebug] outline rowHeight: %.1f", [self.outline rowHeight]);

    // 更新滚动视图内容大小
    [self.outlineScroll.documentView setNeedsLayout:YES];
    [self.outlineScroll reflectScrolledClipView:self.outlineScroll.contentView];

    // 打印内容视图信息
    NSView* contentView = self.outlineScroll.contentView;
    NSLog(@"[ScrollDebug] contentView frame: %@",
          NSStringFromRect(contentView.frame));
    NSLog(@"[ScrollDebug] contentView bounds: %@",
          NSStringFromRect(contentView.bounds));
    NSLog(@"[ScrollDebug] documentView frame: %@",
          NSStringFromRect(self.outlineScroll.documentView.frame));

    // 强制重新计算滚动条
    [self.outlineScroll setNeedsDisplay:YES];

    // 详细检查滚动条状态
    NSLog(@"[ScrollDebug] hasVerticalScroller: %@",
          self.outlineScroll.hasVerticalScroller ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] hasHorizontalScroller: %@",
          self.outlineScroll.hasHorizontalScroller ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] autohidesScrollers: %@",
          self.outlineScroll.autohidesScrollers ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] scrollerStyle: %ld",
          (long)self.outlineScroll.scrollerStyle);
    NSLog(@"[ScrollDebug] borderType: %ld",
          (long)self.outlineScroll.borderType);

    // 确保滚动条可见性正确
    if (self.outlineScroll.hasVerticalScroller) {
      NSScroller* vScroller = self.outlineScroll.verticalScroller;
      if (vScroller) {
        NSLog(@"[ScrollDebug] verticalScroller 存在");
        NSLog(@"[ScrollDebug] verticalScroller frame: %@",
              NSStringFromRect(vScroller.frame));
        NSLog(@"[ScrollDebug] verticalScroller bounds: %@",
              NSStringFromRect(vScroller.bounds));
        NSLog(@"[ScrollDebug] verticalScroller hidden: %@",
              vScroller.hidden ? @"YES" : @"NO");
        NSLog(@"[ScrollDebug] verticalScroller enabled: %@",
              vScroller.enabled ? @"YES" : @"NO");
        NSLog(@"[ScrollDebug] verticalScroller alphaValue: %.2f",
              vScroller.alphaValue);
        NSLog(@"[ScrollDebug] verticalScroller controlSize: %ld",
              (long)vScroller.controlSize);
        NSLog(@"[ScrollDebug] verticalScroller scrollerStyle: %ld",
              (long)vScroller.scrollerStyle);
        NSLog(@"[ScrollDebug] verticalScroller knobProportion: %.3f",
              vScroller.knobProportion);
        NSLog(@"[ScrollDebug] verticalScroller doubleValue: %.3f",
              vScroller.doubleValue);

        [vScroller setEnabled:YES];
        [vScroller setHidden:NO];
        [vScroller setNeedsDisplay:YES];

        NSLog(@"[ScrollDebug] 滚动条属性已强制设置");
      } else {
        NSLog(@"[ScrollDebug] ❌ verticalScroller 为 nil！");
      }
    } else {
      NSLog(@"[ScrollDebug] ❌ hasVerticalScroller 为 NO！");
    }

    NSLog(@"[BookmarkControl] 书签滚动视图已更新，滚动条状态已刷新");
  } else {
    if (!self.outlineScroll) {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 为 nil！");
    } else if (self.outlineScroll.hidden) {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 被隐藏！");
    }
  }

  NSLog(@"[ScrollDebug] ========== updateBookmarkScrollView 结束 ==========");
}

- (void)ensureBookmarkScrollBarVisible {
  NSLog(@"[ScrollDebug] ========== ensureBookmarkScrollBarVisible 开始 "
        @"==========");

  if (!self.outlineScroll || self.outlineScroll.hidden) {
    if (!self.outlineScroll) {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 为 nil，退出");
    } else {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 被隐藏，退出");
    }
    return;
  }

  NSLog(@"[ScrollDebug] 检查并确保滚动条可见性");

  // 获取outline view的内容高度
  NSInteger rowCount = [self.outline numberOfRows];
  CGFloat rowHeight = [self.outline rowHeight];
  CGFloat totalContentHeight = rowCount * rowHeight;
  CGFloat visibleHeight = self.outlineScroll.contentView.bounds.size.height;
  CGFloat scrollViewHeight = self.outlineScroll.bounds.size.height;

  NSLog(@"[ScrollDebug] 行数: %ld", (long)rowCount);
  NSLog(@"[ScrollDebug] 行高: %.1f", rowHeight);
  NSLog(@"[ScrollDebug] 总内容高度: %.1f", totalContentHeight);
  NSLog(@"[ScrollDebug] 可见高度(contentView): %.1f", visibleHeight);
  NSLog(@"[ScrollDebug] 滚动视图高度: %.1f", scrollViewHeight);

  // 如果内容高度超过可见高度，确保滚动条可见
  BOOL shouldShowScrollBar = (totalContentHeight > visibleHeight);
  NSLog(@"[ScrollDebug] 是否应该显示滚动条: %@",
        shouldShowScrollBar ? @"YES" : @"NO");

  if (shouldShowScrollBar) {
    NSLog(@"[ScrollDebug] 内容超出可见区域，强制显示滚动条");

    // 强制显示滚动条
    self.outlineScroll.hasVerticalScroller = YES;
    self.outlineScroll.autohidesScrollers = NO;

    NSLog(@"[ScrollDebug] 设置 hasVerticalScroller = YES, autohidesScrollers = "
          @"NO");

    NSScroller* vScroller = self.outlineScroll.verticalScroller;
    if (vScroller) {
      NSLog(@"[ScrollDebug] 找到 verticalScroller，开始配置");
      NSLog(@"[ScrollDebug] 配置前 - hidden: %@, enabled: %@",
            vScroller.hidden ? @"YES" : @"NO",
            vScroller.enabled ? @"YES" : @"NO");

      [vScroller setEnabled:YES];
      [vScroller setHidden:NO];
      [vScroller setNeedsDisplay:YES];

      // 设置滚动条样式和大小
      vScroller.controlSize = NSControlSizeRegular;
      if (@available(macOS 10.7, *)) {
        vScroller.scrollerStyle = NSScrollerStyleOverlay;
      }

      NSLog(@"[ScrollDebug] 配置后 - hidden: %@, enabled: %@, style: %ld",
            vScroller.hidden ? @"YES" : @"NO",
            vScroller.enabled ? @"YES" : @"NO", (long)vScroller.scrollerStyle);
      NSLog(@"[ScrollDebug] 滚动条 frame: %@",
            NSStringFromRect(vScroller.frame));

      NSLog(@"[BookmarkControl] 滚动条已强制显示，样式: %ld",
            (long)vScroller.scrollerStyle);
    } else {
      NSLog(@"[ScrollDebug] ❌ verticalScroller 仍然为 nil！");

      // 尝试重新创建滚动条
      NSLog(@"[ScrollDebug] 尝试重新设置滚动条...");
      self.outlineScroll.hasVerticalScroller = NO;
      self.outlineScroll.hasVerticalScroller = YES;

      vScroller = self.outlineScroll.verticalScroller;
      if (vScroller) {
        NSLog(@"[ScrollDebug] ✅ 重新创建滚动条成功！");
        [vScroller setEnabled:YES];
        [vScroller setHidden:NO];
        [vScroller setNeedsDisplay:YES];
      } else {
        NSLog(@"[ScrollDebug] ❌ 重新创建滚动条失败！");
      }
    }
  } else {
    NSLog(@"[ScrollDebug] 内容较少，滚动条可能自动隐藏");
    NSLog(@"[ScrollDebug] 但仍然尝试确保滚动条存在...");

    // 即使内容较少，也确保滚动条存在（可能处于禁用状态）
    self.outlineScroll.hasVerticalScroller = YES;
    NSScroller* vScroller = self.outlineScroll.verticalScroller;
    if (vScroller) {
      NSLog(@"[ScrollDebug] 滚动条存在，frame: %@",
            NSStringFromRect(vScroller.frame));
    }
  }

  // 刷新滚动视图
  [self.outlineScroll setNeedsDisplay:YES];
  [self.outlineScroll.contentView setNeedsDisplay:YES];

  NSLog(@"[ScrollDebug] ========== ensureBookmarkScrollBarVisible 结束 "
        @"==========");
}

- (void)forceTraditionalScrollBar {
  NSLog(@"[ScrollDebug] ========== 强制使用传统滚动条样式 ==========");

  if (!self.outlineScroll) {
    NSLog(@"[ScrollDebug] ❌ outlineScroll 为 nil，无法设置滚动条样式");
    return;
  }

  // 强制使用传统滚动条样式，更容易看到
  self.outlineScroll.scrollerStyle = NSScrollerStyleLegacy;
  self.outlineScroll.autohidesScrollers = NO;
  self.outlineScroll.hasVerticalScroller = YES;

  NSLog(@"[ScrollDebug] 设置为传统滚动条样式");

  NSScroller* vScroller = self.outlineScroll.verticalScroller;
  if (vScroller) {
    vScroller.scrollerStyle = NSScrollerStyleLegacy;
    vScroller.controlSize = NSControlSizeRegular;
    [vScroller setEnabled:YES];
    [vScroller setHidden:NO];
    [vScroller setNeedsDisplay:YES];

    NSLog(@"[ScrollDebug] 传统滚动条配置完成");
    NSLog(@"[ScrollDebug] 滚动条 frame: %@", NSStringFromRect(vScroller.frame));
    NSLog(@"[ScrollDebug] 滚动条 style: %ld", (long)vScroller.scrollerStyle);
  } else {
    NSLog(@"[ScrollDebug] ❌ 无法获取垂直滚动条");
  }

  // 强制刷新
  [self.outlineScroll setNeedsDisplay:YES];
  [self.outlineScroll.contentView setNeedsDisplay:YES];

  NSLog(@"[ScrollDebug] ========== 传统滚动条样式设置完成 ==========");
}

- (void)checkScrollBarOverlap {
  NSLog(@"[ScrollDebug] ========== 检查滚动条遮挡情况 ==========");

  if (!self.outlineScroll || self.outlineScroll.hidden) {
    NSLog(@"[ScrollDebug] 滚动视图不存在或被隐藏，跳过检查");
    return;
  }

  NSScroller* vScroller = self.outlineScroll.verticalScroller;
  if (!vScroller) {
    NSLog(@"[ScrollDebug] ❌ 垂直滚动条不存在");
    return;
  }

  NSLog(@"[ScrollDebug] 滚动条信息:");
  NSLog(@"[ScrollDebug] - frame: %@", NSStringFromRect(vScroller.frame));
  NSLog(@"[ScrollDebug] - bounds: %@", NSStringFromRect(vScroller.bounds));
  NSLog(@"[ScrollDebug] - superview: %@", vScroller.superview);
  NSLog(@"[ScrollDebug] - hidden: %@", vScroller.hidden ? @"YES" : @"NO");
  NSLog(@"[ScrollDebug] - alphaValue: %.2f", vScroller.alphaValue);

  // 检查滚动视图的布局
  NSLog(@"[ScrollDebug] 滚动视图布局:");
  NSLog(@"[ScrollDebug] - outlineScroll frame: %@",
        NSStringFromRect(self.outlineScroll.frame));
  NSLog(@"[ScrollDebug] - outlineScroll bounds: %@",
        NSStringFromRect(self.outlineScroll.bounds));
  NSLog(@"[ScrollDebug] - contentView frame: %@",
        NSStringFromRect(self.outlineScroll.contentView.frame));
  NSLog(@"[ScrollDebug] - documentView frame: %@",
        NSStringFromRect(self.outlineScroll.documentView.frame));

  // 检查左侧面板的所有子视图
  NSLog(@"[ScrollDebug] 左侧面板子视图:");
  for (NSUInteger i = 0; i < self.leftPanel.subviews.count; i++) {
    NSView* subview = self.leftPanel.subviews[i];
    NSRect subviewFrame = subview.frame;
    NSRect scrollerFrame = vScroller.frame;

    // 转换坐标系进行比较
    NSRect scrollerInPanel = [self.leftPanel convertRect:scrollerFrame
                                                fromView:vScroller.superview];

    BOOL overlaps = NSIntersectsRect(subviewFrame, scrollerInPanel);

    NSLog(@"[ScrollDebug] - subview[%lu]: %@ frame: %@ %@", (unsigned long)i,
          NSStringFromClass([subview class]), NSStringFromRect(subviewFrame),
          overlaps ? @"⚠️ 可能遮挡滚动条" : @"✅ 无遮挡");
  }

  NSLog(@"[ScrollDebug] ========== 滚动条遮挡检查完成 ==========");
}

- (void)ensureLeftPanelSize {
  NSLog(@"[ScrollDebug] ========== 确保左侧面板尺寸正确 ==========");

  CGFloat expectedWidth =
      self.bookmarkVisible ? kBookmarkExpandedWidth : kBookmarkCollapsedWidth;
  NSRect currentFrame = self.leftPanel.frame;

  NSLog(@"[ScrollDebug] 当前面板宽度: %.1f, 期望宽度: %.1f",
        currentFrame.size.width, expectedWidth);

  if (fabs(currentFrame.size.width - expectedWidth) > 1.0) {
    NSLog(@"[ScrollDebug] ⚠️ 面板宽度不匹配，强制修正");

    // 强制修正面板宽度
    NSRect correctedFrame = currentFrame;
    correctedFrame.size.width = expectedWidth;
    self.leftPanel.frame = correctedFrame;

    // 同时修正分割视图位置
    [self.split setPosition:expectedWidth ofDividerAtIndex:0];

    NSLog(@"[ScrollDebug] ✅ 面板宽度已修正为: %@",
          NSStringFromRect(self.leftPanel.frame));
  } else {
    NSLog(@"[ScrollDebug] ✅ 面板宽度正确");
  }

  // 如果书签可见，确保滚动视图frame正确
  if (self.bookmarkVisible && self.outlineScroll) {
    NSRect expectedScrollFrame =
        NSMakeRect(0, 0, kBookmarkExpandedWidth,
                   self.leftPanel.bounds.size.height - kControlBarHeight);
    NSRect currentScrollFrame = self.outlineScroll.frame;

    NSLog(@"[ScrollDebug] 滚动视图当前frame: %@",
          NSStringFromRect(currentScrollFrame));
    NSLog(@"[ScrollDebug] 滚动视图期望frame: %@",
          NSStringFromRect(expectedScrollFrame));

    if (!NSEqualRects(currentScrollFrame, expectedScrollFrame)) {
      NSLog(@"[ScrollDebug] ⚠️ 滚动视图frame不匹配，强制修正");
      self.outlineScroll.frame = expectedScrollFrame;
      NSLog(@"[ScrollDebug] ✅ 滚动视图frame已修正");
    }
  }

  NSLog(@"[ScrollDebug] ========== 左侧面板尺寸检查完成 ==========");
}

- (void)updateExpandedControlBarLayout {
  NSLog(@"[ScrollDebug] ========== 更新展开状态控制栏布局 ==========");

  if (!self.bookmarkVisible || !self.expandedTopControlBar) {
    NSLog(@"[ScrollDebug] 书签未展开或控制栏不存在，跳过更新");
    return;
  }

  // 计算正确的控制栏位置和大小
  CGFloat expandedWidth =
      self.leftPanel.bounds.size.width;  // 使用实际面板宽度而不是常量
  CGFloat controlBarY = self.leftPanel.bounds.size.height - kControlBarHeight;
  NSRect correctFrame =
      NSMakeRect(0, controlBarY, expandedWidth, kControlBarHeight);
  NSRect currentFrame = self.expandedTopControlBar.frame;

  NSLog(@"[ScrollDebug] 控制栏当前frame: %@", NSStringFromRect(currentFrame));
  NSLog(@"[ScrollDebug] 控制栏期望frame: %@", NSStringFromRect(correctFrame));
  NSLog(@"[ScrollDebug] 左侧面板bounds: %@",
        NSStringFromRect(self.leftPanel.bounds));
  NSLog(@"[ScrollDebug] 使用实际面板宽度: %.1f", expandedWidth);

  // 总是更新控制栏frame和子视图位置
  self.expandedTopControlBar.frame = correctFrame;

  // 更新子视图的位置和大小
  for (NSView* subview in self.expandedTopControlBar.subviews) {
    if (subview.frame.size.height == 1) {  // 分隔线
      NSRect separatorFrame = subview.frame;
      separatorFrame.size.width = expandedWidth;
      subview.frame = separatorFrame;
      NSLog(@"[ScrollDebug] 分隔线宽度已更新: %.1f", expandedWidth);
    } else if ([subview isKindOfClass:[NSButton class]]) {
      NSButton* button = (NSButton*)subview;
      if ([button.title isEqualToString:@"◀"]) {  // 收起按钮
        // 重新计算按钮位置（右对齐）
        CGFloat buttonWidth = 16;
        CGFloat buttonHeight = 16;
        CGFloat rightMargin = 4;
        CGFloat yCenter = (kControlBarHeight - buttonHeight) / 2;
        CGFloat buttonX = expandedWidth - buttonWidth - rightMargin;
        NSRect newButtonFrame =
            NSMakeRect(buttonX, yCenter, buttonWidth, buttonHeight);
        button.frame = newButtonFrame;
        NSLog(@"[ScrollDebug] ◀按钮位置已更新: %@",
              NSStringFromRect(newButtonFrame));
      }
    }
  }

  NSLog(@"[ScrollDebug] ✅ 控制栏布局更新完成");

  NSLog(@"[ScrollDebug] ========== 控制栏布局更新完成 ==========");
}

#pragma mark - NSSplitViewDelegate

- (void)splitViewDidResizeSubviews:(NSNotification*)notification {
  NSSplitView* splitView = (NSSplitView*)notification.object;

  // 只处理左侧书签面板的 splitView，不处理右侧检查器的 splitView
  if (splitView != self.split) {
    return;
  }

  NSLog(@"[ScrollDebug] ========== 分割视图尺寸改变 ==========");
  NSLog(@"[ScrollDebug] 左侧面板新尺寸: %@",
        NSStringFromRect(self.leftPanel.frame));

  // 当分割视图尺寸改变时，更新控制栏布局
  if (self.bookmarkVisible && self.expandedTopControlBar) {
    NSLog(@"[ScrollDebug] 由于分割视图变化，更新展开状态控制栏布局");
    [self updateExpandedControlBarLayout];
  }

  // 更新检查器布局以适应新的窗口大小
  if (self.inspectorVisible) {
    NSLog(@"[Inspector] 由于分割视图变化，更新检查器布局");
    [self updateInspectorLayout];
  }

  NSLog(@"[ScrollDebug] ========== 分割视图尺寸改变处理完成 ==========");
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMinCoordinate:(CGFloat)proposedMin
               ofSubviewAt:(NSInteger)dividerIndex {
  // 判断是左侧书签面板的 splitView 还是右侧检查器面板的 splitView
  if (splitView == self.split) {
    // 左侧面板最小宽度
    if (dividerIndex == 0) {
      return kBookmarkCollapsedWidth;
    }
  } else if (splitView.superview == self.rightPanel) {
    // 右侧检查器面板的 splitView
    // 如果检查器隐藏，允许完全收起（分割位置可以设置为 rightPanel 的完整宽度）
    if (dividerIndex == 0 && !self.inspectorVisible) {
      // 允许设置到完整宽度，这样检查器面板宽度为0
      return self.rightPanel.bounds.size.width;
    }
    // 检查器显示时，最小宽度为检查器宽度
    if (dividerIndex == 0) {
      return self.rightPanel.bounds.size.width - kInspectorWidth;
    }
  }
  return proposedMin;
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMaxCoordinate:(CGFloat)proposedMax
               ofSubviewAt:(NSInteger)dividerIndex {
  if (splitView == self.split) {
    if (dividerIndex == 0) {
      // 左侧面板最大宽度
      return kBookmarkExpandedWidth + 50;  // 允许稍微超过标准宽度
    }
  } else if (splitView.superview == self.rightPanel) {
    // 右侧检查器面板的 splitView
    // 如果检查器显示，最大宽度就是检查器宽度
    if (dividerIndex == 0 && self.inspectorVisible) {
      return self.rightPanel.bounds.size.width - kInspectorWidth;
    }
  }
  return proposedMax;
}

- (BOOL)splitView:(NSSplitView*)splitView
    shouldAdjustSizeOfSubview:(NSView*)subview {
  // 如果是右侧检查器的 splitView，且检查器处于隐藏状态，不允许自动调整
  if (splitView.superview == self.rightPanel &&
      subview == self.inspectorPanel && !self.inspectorVisible) {
    return NO;
  }
  // 对于其他情况，允许自动调整
  return YES;
}

// DataSource
- (NSInteger)outlineView:(NSOutlineView*)outlineView
    numberOfChildrenOfItem:(id)item {
  TocNode* n = item ?: self.tocRoot;
  return n ? (NSInteger)n.children.count : 0;
}
- (id)outlineView:(NSOutlineView*)outlineView
            child:(NSInteger)index
           ofItem:(id)item {
  TocNode* n = item ?: self.tocRoot;
  return (index >= 0 && index < (NSInteger)n.children.count)
             ? n.children[(NSUInteger)index]
             : nil;
}
- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(id)item {
  TocNode* n = (TocNode*)item;
  return n.children.count > 0;
}
- (NSView*)outlineView:(NSOutlineView*)outlineView
    viewForTableColumn:(NSTableColumn*)tableColumn
                  item:(id)item {
  NSTableCellView* cell = [outlineView makeViewWithIdentifier:@"tocCell"
                                                        owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
    cell.identifier = @"tocCell";
    NSTextField* text = [[NSTextField alloc] initWithFrame:cell.bounds];
    text.bezeled = NO;
    text.drawsBackground = NO;
    text.editable = NO;
    text.selectable = NO;
    text.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cell.textField = text;
    [cell addSubview:text];
  }
  TocNode* n = (TocNode*)item;
  cell.textField.stringValue = n.title ?: @"";
  return cell;
}

// Delegate: 双击跳页
- (void)outlineView:(NSOutlineView*)outlineView
    didClickTableColumn:(NSTableColumn*)tableColumn {
}
- (void)outlineViewSelectionDidChange:(NSNotification*)notification {
  NSInteger row = self.outline.selectedRow;
  if (row < 0) {
    return;
  }
  id item = [self.outline itemAtRow:row];
  TocNode* n = (TocNode*)item;
  if (n.pageIndex >= 0) {
    [self.view goToPage:n.pageIndex];
  }
}

// NSTextView点击处理
- (BOOL)textView:(NSTextView*)textView
    clickedOnLink:(id)link
          atIndex:(NSUInteger)charIndex {
  return NO;  // 我们不使用链接，而是自定义处理
}

// 检查器文本视图点击处理
- (void)inspectorTextViewClicked:(NSClickGestureRecognizer*)recognizer {
  if (!self.inspectorTextView || !self.objectPositions) {
    return;
  }

  NSPoint clickPoint = [recognizer locationInView:self.inspectorTextView];

  // 获取点击位置的字符索引
  NSUInteger charIndex =
      [self.inspectorTextView characterIndexForInsertionAtPoint:clickPoint];
  NSString* text = self.inspectorTextView.string;

  NSLog(@"[Inspector] 点击位置: (%.1f, %.1f), 字符索引: %lu", clickPoint.x,
        clickPoint.y, charIndex);

  // 查找点击位置附近的对象引用（格式：数字 0 R）
  NSError* error = nil;
  NSRegularExpression* regex =
      [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s+0\\s+R"
                                                options:0
                                                  error:&error];
  if (error) {
    NSLog(@"[Inspector] 正则表达式错误: %@", error.localizedDescription);
    return;
  }

  __block uint32_t targetObjNum = 0;
  __block NSRange foundRange = NSMakeRange(NSNotFound, 0);
  [regex enumerateMatchesInString:text
                          options:0
                            range:NSMakeRange(0, text.length)
                       usingBlock:^(NSTextCheckingResult* match,
                                    NSMatchingFlags flags, BOOL* stop) {
                         NSRange matchRange = [match range];
                         NSLog(@"[Inspector] 找到匹配: %@, 范围: %@",
                               [text substringWithRange:matchRange],
                               NSStringFromRange(matchRange));

                         if (charIndex >= matchRange.location &&
                             charIndex <=
                                 matchRange.location + matchRange.length) {
                           NSString* objNumStr =
                               [text substringWithRange:[match rangeAtIndex:1]];
                           targetObjNum = (uint32_t)[objNumStr integerValue];
                           foundRange = matchRange;
                           NSLog(@"[Inspector] 点击命中对象引用: %u",
                                 targetObjNum);
                           *stop = YES;
                         }
                       }];

  // 如果找到目标对象号，跳转到对应位置
  if (targetObjNum > 0) {
    NSString* objKey = [NSString stringWithFormat:@"%u", targetObjNum];
    NSNumber* position = [self.objectPositions objectForKey:objKey];
    NSLog(@"[Inspector] 查找对象 %u 的位置，映射表中有 %lu 个对象",
          targetObjNum, self.objectPositions.count);

    if (position) {
      NSUInteger targetPos = [position unsignedIntegerValue];
      NSRange targetRange = NSMakeRange(targetPos, 0);
      [self.inspectorTextView scrollRangeToVisible:targetRange];
      [self.inspectorTextView
          setSelectedRange:NSMakeRange(targetPos, 20)];  // 高亮显示更多字符
      NSLog(@"[Inspector] 成功跳转到对象 %u，位置：%lu", targetObjNum,
            targetPos);
    } else {
      NSLog(@"[Inspector] 未找到对象 %u 的位置信息", targetObjNum);
      // 打印所有可用的对象号
      NSArray* allKeys = [self.objectPositions.allKeys
          sortedArrayUsingSelector:@selector(compare:)];
      NSLog(@"[Inspector] 可用对象号: %@", allKeys);
    }
  } else {
    NSLog(@"[Inspector] 点击位置未找到对象引用");
  }
}

}
*/

#pragma mark - File menu actions

@implementation AppDelegate (FileActions)

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
  if (menuItem.action == @selector(exportPNG:)) {
    BOOL enable = ([self.view document] != nullptr);
    MacLog_DebugNS(
        [NSString stringWithFormat:@"[MenuValidate] exportPNG enable=%@",
                                   enable ? @"YES" : @"NO"]);
    return enable;
  }
  if (menuItem.action == @selector(openDocument:)) {
    MacLog_DebugNS(@"[MenuValidate] openDocument - 返回 YES（允许）");
    return YES;
  }
  return YES;
}

- (IBAction)openDocument:(id)sender {
  MacLog_DebugNS(@"========================================");
  MacLog_DebugNS(@"[MenuAction] openDocument: 方法被调用！");
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[MenuAction] sender = %@", sender]);
  MacLog_DebugNS([NSString stringWithFormat:@"[MenuAction] self = %@", self]);
  MacLog_DebugNS(@"========================================");
  [NSApp activateIgnoringOtherApps:YES];
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  if (@available(macOS 12.0, *)) {
    panel.allowedContentTypes = @[ UTTypePDF ];
  } else {
    // 避免直接引用已废弃 API 引发告警，使用 KVC 设置
    [panel setValue:@[ @"pdf" ] forKey:@"allowedFileTypes"];
  }
  MacLog_DebugNS(@"[MenuAction] 显示文件选择对话框");
  NSModalResponse resp = [panel runModal];
  MacLog_DebugNS([NSString
      stringWithFormat:@"[MenuAction] 对话框返回结果: %ld", (long)resp]);
  if (resp == NSModalResponseOK) {
    NSString* path = panel.URL.path;
    MacLog_DebugNS(
        [NSString stringWithFormat:@"[MenuAction] 用户选择了文件: %@", path]);
    [self openPathAndAdjust:path];
  } else {
    MacLog_DebugNS(@"[MenuAction] 用户取消了文件选择");
  }
}

- (IBAction)exportPNG:(id)sender {
  if ([self.view document]) {
    [self.view exportCurrentPagePNG];
  }
}

- (IBAction)openLogWindow:(id)sender {
  // 日志记录默认已启用，这里只是显示窗口
  Log_ShowWindow();
}

@end

#pragma mark - Recent menu实现（部分方法仍在使用）

@implementation AppDelegate (Recent)

- (void)openPathAndAdjust:(NSString*)path {
  if (path.length == 0) {
    LOG_WARNING("openPathAndAdjust: 路径为空");
    return;
  }

  NSLog(@"[PdfWinViewer] openPathAndAdjust: %@", path);
  LOG_INFO_F("用户请求打开文件：%s", [[path lastPathComponent] UTF8String]);

  // 检查文件是否存在
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    LOG_ERROR_F("文件不存在：%s", [path UTF8String]);
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"文件不存在";
    alert.informativeText = path;
    [alert runModal];
    return;
  }

  // 获取文件大小
  NSError* error = nil;
  NSDictionary* attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
  if (attrs) {
    unsigned long long fileSize = [attrs fileSize];
    LOG_INFO_F("文件大小：%.2f MB", fileSize / (1024.0 * 1024.0));
  }

  MacLog_DebugNS(@"[OpenFile] 准备调用 [self.view openPDFAtPath:path]");
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[OpenFile] self.view = %@", self.view]);

  if ([self.view openPDFAtPath:path]) {
    MacLog_DebugNS(@"[StatusBar] PDF文件打开成功，准备更新状态栏");
    LOG_INFO("PDF 文件加载成功，开始初始化界面");

    MacLog_DebugNS(@"[OpenFile] 调用 rebuildToc");
    [self rebuildToc];

    MacLog_DebugNS(@"[OpenFile] 设置 first responder");
    [self.window makeFirstResponder:self.view];

    // 更新状态栏显示（确保状态栏已初始化）
    MacLog_DebugNS(
        [NSString stringWithFormat:@"[OpenFile] 更新状态栏，statusBar = %@",
                                   self.statusBar]);
    if (self.statusBar) {
      [self updateStatusBar];
    } else {
      MacLog_DebugNS(@"[StatusBar] 状态栏尚未初始化，跳过更新");
    }

    // 高亮当前书签
    MacLog_DebugNS(@"[OpenFile] 高亮书签");
    [self highlightCurrentBookmark];

    // 先调整窗口大小（不显示、不动画），避免触发额外的重绘
    NSSize s = [self.view currentPageSizePt];
    MacLog_DebugNS(
        [NSString stringWithFormat:@"[OpenFile] 当前页面大小：%.0f x %.0f",
                                   s.width, s.height]);
    CGFloat newW = MIN(MAX(800, s.width + 300), 1600);  // 预留左栏与边距
    CGFloat newH = MIN(MAX(600, s.height + 120), 1200);
    NSRect f = self.window.frame;
    f.size = NSMakeSize(newW, newH);
    [self.window setFrame:f display:NO animate:NO];
    LOG_DEBUG_F("窗口大小调整为：%.0f x %.0f", newW, newH);
    MacLog_DebugNS(
        [NSString stringWithFormat:@"[OpenFile] 窗口大小已调整为：%.0f x %.0f",
                                   newW, newH]);

    // 然后更新视图尺寸，setFrameSize 会自动触发 drawRect（唯一的渲染）
    MacLog_DebugNS(@"[OpenFile] 调用 updateViewSizeToFitPage");
    [self.view updateViewSizeToFitPage];
    MacLog_DebugNS([NSString
        stringWithFormat:
            @"[OpenFile] PdfView frame after updateViewSizeToFitPage: %@",
            NSStringFromRect(self.view.frame)]);

    // 更新窗口标题
    self.window.title = [NSString
        stringWithFormat:@"PdfWinViewer - %@", path.lastPathComponent];
    // 写入最近
    [self addRecentPath:path];
    NSLog(@"[PdfWinViewer] after addRecentPath, recent count=%lu",
          (unsigned long)self.recentPaths.count);
    LOG_DEBUG_F("已添加到最近文件列表，当前列表数量：%lu",
                (unsigned long)self.recentPaths.count);

    // 启用"导出当前页为 PNG"
    NSMenu* fileMenu = [[[NSApp mainMenu] itemWithTitle:@"文件"] submenu];
    NSMenuItem* exp = [fileMenu itemWithTag:9901];
    if (exp) {
      [exp setEnabled:YES];
    }

    LOG_INFO_F("文件打开完成：%s", [[path lastPathComponent] UTF8String]);
    LOG_INFO_F("========================================");
  } else {
    LOG_ERROR_F("无法打开 PDF 文件：%s", [path UTF8String]);
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"无法打开 PDF";
    alert.informativeText = path ?: @"";
    [alert runModal];
  }
}

@end

#pragma mark - Recent menu - 已迁移到SettingsManager和RecentFilesManager（下面的方法已注释）
/*
// 与 Windows 保持一致：统一使用 settings.json，包含 recent_files 数组
- (NSString*)settingsJSONPath {
  NSString* execPath = [[NSBundle mainBundle] executablePath];
  NSString* execDir = [execPath stringByDeletingLastPathComponent];
  NSString* path = [execDir stringByAppendingPathComponent:@"settings.json"];
  NSLog(@"[PdfWinViewer] settings.json path=%@", path);
  return path;
}

- (void)loadSettingsJSON {
  self.settingsDict = [NSMutableDictionary new];
  NSString* path = [self settingsJSONPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSLog(@"[PdfWinViewer] settings.json not found");
    return;
  }
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    NSLog(@"[PdfWinViewer] settings.json read failed");
    return;
  }
  NSError* err = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err || ![json isKindOfClass:[NSDictionary class]]) {
    NSLog(@"[PdfWinViewer] settings.json parse failed: %@", err);
    return;
  }
  self.settingsDict = [((NSDictionary*)json) mutableCopy];
  NSLog(@"[PdfWinViewer] settings loaded with %lu keys",
        (unsigned long)self.settingsDict.count);
}

- (void)saveSettingsJSON {
  if (!self.settingsDict) {
    self.settingsDict = [NSMutableDictionary new];
  }
  NSError* err = nil;
  NSData* data =
      [NSJSONSerialization dataWithJSONObject:self.settingsDict
                                      options:NSJSONWritingPrettyPrinted
                                        error:&err];
  if (err || !data) {
    NSLog(@"[PdfWinViewer] Failed to serialize settings.json: %@", err);
    return;
  }
  NSString* path = [self settingsJSONPath];
  BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&err];
  if (!ok || err) {
    NSLog(@"[PdfWinViewer] Failed to write settings.json: %@", err);
  } else {
    NSLog(@"[PdfWinViewer] settings.json saved OK");
  }
}

- (void)extractRecentFromSettings {
  self.recentPaths = [NSMutableArray new];
  id arr = self.settingsDict[@"recent_files"];
  if (![arr isKindOfClass:[NSArray class]]) {
    NSLog(@"[PdfWinViewer] settings has no recent_files (or wrong type)");
    return;
  }
  for (id item in (NSArray*)arr) {
    if ([item isKindOfClass:[NSString class]] &&
        [((NSString*)item) length] > 0) {
      if (![self.recentPaths containsObject:item]) {
        [self.recentPaths addObject:item];
      }
      if (self.recentPaths.count >= 10) {
        break;
      }
    }
  }
  NSLog(@"[PdfWinViewer] recent_files loaded: %@", self.recentPaths);
}

- (void)persistRecentIntoSettings {
  if (!self.settingsDict) {
    self.settingsDict = [NSMutableDictionary new];
  }
  self.settingsDict[@"recent_files"] = [self.recentPaths copy];
  [self saveSettingsJSON];
}

- (void)openPathAndAdjust:(NSString*)path {
  if (path.length == 0) {
    LOG_WARNING("openPathAndAdjust: 路径为空");
    return;
  }

  NSLog(@"[PdfWinViewer] openPathAndAdjust: %@", path);
  LOG_INFO_F("用户请求打开文件：%s", [[path lastPathComponent] UTF8String]);

  // 检查文件是否存在
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    LOG_ERROR_F("文件不存在：%s", [path UTF8String]);
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"文件不存在";
    alert.informativeText = path;
    [alert runModal];
    return;
  }

  // 获取文件大小
  NSError* error = nil;
  NSDictionary* attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
  if (attrs) {
    unsigned long long fileSize = [attrs fileSize];
    LOG_INFO_F("文件大小：%.2f MB", fileSize / (1024.0 * 1024.0));
  }

  MacLog_DebugNS(@"[OpenFile] 准备调用 [self.view openPDFAtPath:path]");
  MacLog_DebugNS([NSString stringWithFormat:@"[OpenFile] self.view = %@",
self.view]);

  if ([self.view openPDFAtPath:path]) {
    MacLog_DebugNS(@"[StatusBar] PDF文件打开成功，准备更新状态栏");
    LOG_INFO("PDF 文件加载成功，开始初始化界面");

    MacLog_DebugNS(@"[OpenFile] 调用 rebuildToc");
    [self rebuildToc];

    MacLog_DebugNS(@"[OpenFile] 设置 first responder");
    [self.window makeFirstResponder:self.view];

    // 更新状态栏显示（确保状态栏已初始化）
    MacLog_DebugNS([NSString stringWithFormat:@"[OpenFile] 更新状态栏，statusBar
= %@", self.statusBar]); if (self.statusBar) { [self updateStatusBar]; } else {
      MacLog_DebugNS(@"[StatusBar] 状态栏尚未初始化，跳过更新");
    }

    // 高亮当前书签
    MacLog_DebugNS(@"[OpenFile] 高亮书签");
    [self highlightCurrentBookmark];

    // 先调整窗口大小（不显示、不动画），避免触发额外的重绘
    NSSize s = [self.view currentPageSizePt];
    MacLog_DebugNS([NSString stringWithFormat:@"[OpenFile] 当前页面大小：%.0f x
%.0f", s.width, s.height]); CGFloat newW = MIN(MAX(800, s.width + 300), 1600);
// 预留左栏与边距 CGFloat newH = MIN(MAX(600, s.height + 120), 1200); NSRect f =
self.window.frame; f.size = NSMakeSize(newW, newH); [self.window setFrame:f
display:NO animate:NO]; LOG_DEBUG_F("窗口大小调整为：%.0f x %.0f", newW, newH);
    MacLog_DebugNS([NSString stringWithFormat:@"[OpenFile]
窗口大小已调整为：%.0f x %.0f", newW, newH]);

    // 然后更新视图尺寸，setFrameSize 会自动触发 drawRect（唯一的渲染）
    MacLog_DebugNS(@"[OpenFile] 调用 updateViewSizeToFitPage");
    [self.view updateViewSizeToFitPage];
    MacLog_DebugNS([NSString stringWithFormat:@"[OpenFile] PdfView frame after
updateViewSizeToFitPage: %@", NSStringFromRect(self.view.frame)]);

    // 更新窗口标题
    self.window.title = [NSString
        stringWithFormat:@"PdfWinViewer - %@", path.lastPathComponent];
    // 写入最近
    [self addRecentPath:path];
    NSLog(@"[PdfWinViewer] after addRecentPath, recent count=%lu",
          (unsigned long)self.recentPaths.count);
    LOG_DEBUG_F("已添加到最近文件列表，当前列表数量：%lu",
                (unsigned long)self.recentPaths.count);

    // 启用"导出当前页为 PNG"
    NSMenu* fileMenu = [[[NSApp mainMenu] itemWithTitle:@"文件"] submenu];
    NSMenuItem* exp = [fileMenu itemWithTag:9901];
    if (exp) {
      [exp setEnabled:YES];
    }

    LOG_INFO_F("文件打开完成：%s", [[path lastPathComponent] UTF8String]);
    LOG_INFO_F("========================================");
  } else {
    LOG_ERROR_F("无法打开 PDF 文件：%s", [path UTF8String]);
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"无法打开 PDF";
    alert.informativeText = path ?: @"";
    [alert runModal];
  }
}

- (void)rebuildRecentMenu {
  if (!self.recentMenu) {
    return;
  }
  [self.recentMenu removeAllItems];
  NSUInteger count = self.recentPaths.count;
  NSLog(@"[PdfWinViewer] rebuildRecentMenu count=%lu", (unsigned long)count);
  if (count == 0) {
    NSMenuItem* none = [[NSMenuItem alloc] initWithTitle:@"无最近项目"
                                                  action:nil
                                           keyEquivalent:@""];
    none.enabled = NO;
    [self.recentMenu addItem:none];
    self.recentMenuItem.enabled = NO;
    return;
  }
  self.recentMenuItem.enabled = YES;
  NSUInteger idx = 0;
  for (NSString* path in self.recentPaths) {
    NSLog(@"[PdfWinViewer] recent item %lu: %@", (unsigned long)idx, path);
    NSString* title =
        path.lastPathComponent.length ? path.lastPathComponent : path;
    // 带序号
    NSString* label =
        [NSString stringWithFormat:@"%lu. %@", (unsigned long)(idx + 1), title];
    NSMenuItem* it = [self.recentMenu addItemWithTitle:label
                                                action:@selector(openRecent:)
                                         keyEquivalent:@""];
    it.target = self;
    it.representedObject = path;
    idx++;
  }
  [self.recentMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* clear = [self.recentMenu addItemWithTitle:@"清空最近浏览"
                                                 action:@selector(clearRecent:)
                                          keyEquivalent:@""];
  clear.target = self;
}

- (void)addRecentPath:(NSString*)path {
  if (path.length == 0) {
    return;
  }
  if (!self.recentPaths) {
    self.recentPaths = [NSMutableArray new];
  }
  // 去重并置顶
  [self.recentPaths removeObject:path];
  [self.recentPaths insertObject:path atIndex:0];
  // 限制为最多 10 条
  while (self.recentPaths.count > 10) {
    [self.recentPaths removeLastObject];
  }
  // 持久化到 settings.json
  [self persistRecentIntoSettings];
  // 重建菜单
  [self rebuildRecentMenu];
  NSLog(@"[PdfWinViewer] addRecentPath done. paths=%@", self.recentPaths);
}

- (IBAction)openRecent:(id)sender {
  if (![sender isKindOfClass:[NSMenuItem class]]) {
    return;
  }
  NSString* path = ((NSMenuItem*)sender).representedObject;
  NSLog(@"[PdfWinViewer] openRecent: %@", path);
  if (path.length == 0) {
    return;
  }
  BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
  if (!exists) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"文件不存在";
    alert.informativeText = path;
    [alert runModal];
    // 从列表中移除并更新
    [self.recentPaths removeObject:path];
    [self persistRecentIntoSettings];
    [self rebuildRecentMenu];
    return;
  }
  [self openPathAndAdjust:path];
}

- (IBAction)clearRecent:(id)sender {
  [self.recentPaths removeAllObjects];
  [self persistRecentIntoSettings];
  [self rebuildRecentMenu];
}
*/

#pragma mark - 状态栏相关方法 - 已迁移到StatusBarController
/*
- (void)createStatusBar {
  NSLog(@"[StatusBar] 开始创建状态栏");
  // 创建状态栏容器
  self.statusBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 30)];
  self.statusBar.wantsLayer = YES;
  // 使用macOS原生的窗口背景色
  self.statusBar.layer.backgroundColor =
      [[NSColor windowBackgroundColor] CGColor];
  // 添加顶部分隔线
  self.statusBar.layer.borderWidth = 0.5;
  self.statusBar.layer.borderColor = [[NSColor separatorColor] CGColor];
  NSLog(@"[StatusBar] 状态栏容器创建完成，frame: %@",
        NSStringFromRect(self.statusBar.frame));

  // 添加分隔线
  NSView* separator = [[NSView alloc] initWithFrame:NSMakeRect(0, 29, 800, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable;
  [self.statusBar addSubview:separator];

  // 页码标签 "页码:"
  self.pageLabel =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 7, 40, 16)];
  self.pageLabel.stringValue = @"页码:";
  self.pageLabel.bezeled = NO;
  self.pageLabel.drawsBackground = NO;
  self.pageLabel.editable = NO;
  self.pageLabel.selectable = NO;
  self.pageLabel.font = [NSFont systemFontOfSize:12];
  self.pageLabel.textColor = [NSColor labelColor];
  [self.statusBar addSubview:self.pageLabel];

  // 页码输入框
  self.pageInput =
      [[NSTextField alloc] initWithFrame:NSMakeRect(55, 6, 50, 18)];
  self.pageInput.stringValue = @"1";
  self.pageInput.font = [NSFont systemFontOfSize:12];
  self.pageInput.alignment = NSTextAlignmentCenter;
  self.pageInput.target = self;
  self.pageInput.action = @selector(onPageInputChanged:);
  [self.statusBar addSubview:self.pageInput];

  // 总页数标签
  self.totalPagesLabel =
      [[NSTextField alloc] initWithFrame:NSMakeRect(110, 7, 60, 16)];
  self.totalPagesLabel.stringValue = @"/ 0";
  self.totalPagesLabel.bezeled = NO;
  self.totalPagesLabel.drawsBackground = NO;
  self.totalPagesLabel.editable = NO;
  self.totalPagesLabel.selectable = NO;
  self.totalPagesLabel.font = [NSFont systemFontOfSize:12];
  self.totalPagesLabel.textColor = [NSColor labelColor];
  [self.statusBar addSubview:self.totalPagesLabel];

  // 上一页按钮
  self.prevPageButton = [NSButton buttonWithTitle:@"上一页"
                                           target:self
                                           action:@selector(onPrevPage:)];
  self.prevPageButton.frame = NSMakeRect(180, 4, 60, 22);
  self.prevPageButton.font = [NSFont systemFontOfSize:11];
  self.prevPageButton.bezelStyle = NSBezelStyleRounded;
  self.prevPageButton.enabled = NO;
  [self.statusBar addSubview:self.prevPageButton];

  // 下一页按钮
  self.nextPageButton = [NSButton buttonWithTitle:@"下一页"
                                           target:self
                                           action:@selector(onNextPage:)];
  self.nextPageButton.frame = NSMakeRect(250, 4, 60, 22);
  self.nextPageButton.font = [NSFont systemFontOfSize:11];
  self.nextPageButton.bezelStyle = NSBezelStyleRounded;
  self.nextPageButton.enabled = NO;
  [self.statusBar addSubview:self.nextPageButton];

  NSLog(@"[StatusBar] 状态栏创建完成，所有子视图已添加");
}
*/

#pragma mark - 书签控制栏相关方法 - 已迁移到BookmarkPanelController
/*
- (void)createBookmarkControlBar {
  NSLog(@"[BookmarkControl] 开始创建书签控制栏");

  // 创建控制栏容器（只在收起状态下可见）
  self.bookmarkControlBar = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, kBookmarkCollapsedWidth,
                               self.leftPanel.bounds.size.height)];
  self.bookmarkControlBar.wantsLayer = YES;
  self.bookmarkControlBar.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];
  self.bookmarkControlBar.autoresizingMask =
      NSViewHeightSizable;  // 只允许高度自适应，宽度固定

  // 创建展开/收起按钮（垂直居中，水平居中）
  CGFloat buttonWidth = 16;
  CGFloat buttonHeight = 16;
  CGFloat xCenter =
      (self.bookmarkControlBar.bounds.size.width - buttonWidth) / 2;
  CGFloat yCenter =
      (self.bookmarkControlBar.bounds.size.height - buttonHeight) / 2;
  self.bookmarkToggleButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(xCenter, yCenter, buttonWidth, buttonHeight)];
  self.bookmarkToggleButton.title =
      @"▶";  // 右箭头表示可以展开（收起状态下显示）
  self.bookmarkToggleButton.font = [NSFont systemFontOfSize:10];
  self.bookmarkToggleButton.bordered = NO;
  self.bookmarkToggleButton.target = self;
  self.bookmarkToggleButton.action = @selector(toggleBookmarkVisibility:);
  [self.bookmarkControlBar addSubview:self.bookmarkToggleButton];

  [self.leftPanel addSubview:self.bookmarkControlBar];

  NSLog(@"[BookmarkControl] 书签控制栏创建完成");
}

- (void)toggleBookmarkVisibility:(id)sender {
  NSLog(@"[BookmarkControl] 切换书签可见性，当前状态: %@",
        self.bookmarkVisible ? @"可见" : @"隐藏");
  [self setBookmarkVisible:!self.bookmarkVisible animated:YES];
}

- (void)setBookmarkVisible:(BOOL)visible animated:(BOOL)animated {
  if (self.bookmarkVisible == visible) {
    return;  // 状态未改变
  }

  self.bookmarkVisible = visible;
  NSLog(@"[BookmarkControl] 设置书签可见性: %@", visible ? @"显示" : @"隐藏");

  // 计算新的宽度 - 使用常量确保一致性
  CGFloat newWidth = visible ? kBookmarkExpandedWidth : kBookmarkCollapsedWidth;
  NSLog(@"[ScrollDebug] 准备调整左侧面板宽度从当前到: %.1f", newWidth);
  NSLog(@"[ScrollDebug] 当前左侧面板 frame: %@",
        NSStringFromRect(self.leftPanel.frame));

  if (animated) {
    // 如果要展开，先创建展开状态的控件并隐藏收起状态的控制栏
    if (visible) {
      [self createExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = YES;  // 隐藏收起状态的控制栏
    } else {
      // 如果要收起，显示收起状态的控制栏
      self.bookmarkControlBar.hidden = NO;
    }

    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.25;  // 动画持续时间
          context.allowsImplicitAnimation = YES;

          // 调整左侧面板宽度 - 这是关键修复
          NSRect leftFrame = self.leftPanel.frame;
          leftFrame.size.width = newWidth;
          NSLog(@"[ScrollDebug] 动画中设置左侧面板 frame: %@",
                NSStringFromRect(leftFrame));
          self.leftPanel.animator.frame = leftFrame;

          // 调整分割视图位置
          [self.split.animator setPosition:newWidth ofDividerAtIndex:0];

          // 在动画过程中也更新控制栏布局
          if (visible && self.expandedTopControlBar) {
            [self updateExpandedControlBarLayout];
          }
        }
        completionHandler:^{
          // 动画完成后的处理
          NSLog(@"[ScrollDebug] 动画完成，最终左侧面板 frame: %@",
                NSStringFromRect(self.leftPanel.frame));

          if (!visible) {
            // 收起完成，移除展开状态的控件
            [self removeExpandedBookmarkControls];
            NSLog(@"[BookmarkControl] 收起完成，显示收起状态控制栏");
          } else {
            // 展开完成，确保控制栏布局正确
            [self updateExpandedControlBarLayout];
            NSLog(@"[BookmarkControl] 展开完成，隐藏收起状态控制栏");
          }
          NSLog(@"[BookmarkControl] 书签切换动画完成");
        }];
  } else {
    // 立即切换
    NSRect leftFrame = self.leftPanel.frame;
    leftFrame.size.width = newWidth;
    NSLog(@"[ScrollDebug] 立即设置左侧面板 frame: %@",
          NSStringFromRect(leftFrame));
    self.leftPanel.frame = leftFrame;

    [self.split setPosition:newWidth ofDividerAtIndex:0];

    if (visible) {
      [self createExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = YES;  // 隐藏收起状态的控制栏
      // 立即更新控制栏布局
      [self updateExpandedControlBarLayout];
      NSLog(@"[BookmarkControl] 立即展开，隐藏收起状态控制栏");
    } else {
      [self removeExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = NO;  // 显示收起状态的控制栏
      NSLog(@"[BookmarkControl] 立即收起，显示收起状态控制栏");
    }
  }
}

- (void)expandAllBookmarks:(id)sender {
  NSLog(@"[BookmarkControl] 展开所有书签");
  [self.outline expandItem:nil expandChildren:YES];

  // 延迟更新滚动条，确保展开动画完成
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self updateBookmarkScrollView];
        [self ensureBookmarkScrollBarVisible];
      });
}

- (void)collapseAllBookmarks:(id)sender {
  NSLog(@"[BookmarkControl] 折叠所有书签");
  [self.outline collapseItem:nil collapseChildren:YES];

  // 延迟更新滚动条，确保折叠动画完成
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self updateBookmarkScrollView];
        [self ensureBookmarkScrollBarVisible];
      });
}

- (TocNode*)findBookmarkForPage:(int)pageIndex inNode:(TocNode*)node {
  if (!node) {
    return nil;
  }

  NSLog(@"[BookmarkSearch] 搜索页面 %d，检查节点: %@ (页面: %d)", pageIndex,
        node.title, node.pageIndex);

  // 检查当前节点是否精确匹配
  if (node.pageIndex == pageIndex) {
    NSLog(@"[BookmarkSearch] 找到精确匹配: %@", node.title);
    return node;
  }

  // 查找最接近的书签（页面索引小于等于当前页面的最大值）
  TocNode* bestMatch = nil;
  if (node.pageIndex >= 0 && node.pageIndex <= pageIndex) {
    bestMatch = node;
    NSLog(@"[BookmarkSearch] 当前最佳匹配: %@ (页面: %d)", bestMatch.title,
          bestMatch.pageIndex);
  }

  // 递归搜索子节点
  for (TocNode* child in node.children) {
    TocNode* childMatch = [self findBookmarkForPage:pageIndex inNode:child];
    if (childMatch) {
      // 如果找到精确匹配，直接返回
      if (childMatch.pageIndex == pageIndex) {
        NSLog(@"[BookmarkSearch] 子节点中找到精确匹配: %@", childMatch.title);
        return childMatch;
      }
      // 否则选择页面索引更接近的那个
      if (!bestMatch || childMatch.pageIndex > bestMatch.pageIndex) {
        bestMatch = childMatch;
        NSLog(@"[BookmarkSearch] 更新最佳匹配: %@ (页面: %d)", bestMatch.title,
              bestMatch.pageIndex);
      }
    }
  }

  return bestMatch;
}

- (void)highlightCurrentBookmark {
  if (!self.tocRoot || !self.view) {
    NSLog(@"[BookmarkHighlight] tocRoot或view为空，跳过高亮");
    return;
  }

  int currentPage = [self.view currentPageIndex];
  NSLog(@"[BookmarkHighlight] 当前页面: %d", currentPage);

  // 查找对应的书签
  TocNode* targetBookmark = [self findBookmarkForPage:currentPage
                                               inNode:self.tocRoot];
  if (targetBookmark) {
    NSLog(@"[BookmarkHighlight] 找到匹配书签: %@ (页面 %d)",
          targetBookmark.title, targetBookmark.pageIndex);

    // 确保书签的父节点都是展开的，这样才能看到目标书签
    [self expandParentsOfItem:targetBookmark];

    // 在outline view中选中该书签
    NSInteger row = [self.outline rowForItem:targetBookmark];
    if (row >= 0) {
      [self.outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                byExtendingSelection:NO];

      // 平滑滚动到选中的书签，确保其可见
      [NSAnimationContext
          runAnimationGroup:^(NSAnimationContext* context) {
            context.duration = 0.3;  // 平滑滚动动画
            context.allowsImplicitAnimation = YES;
            [self.outline.animator scrollRowToVisible:row];
          }
          completionHandler:^{
            // 滚动完成后确保滚动条状态正确
            [self updateBookmarkScrollView];
            [self ensureBookmarkScrollBarVisible];
          }];

      NSLog(@"[BookmarkHighlight] 书签已高亮，行号: %ld", (long)row);
    } else {
      NSLog(@"[BookmarkHighlight] 无法找到书签对应的行，可能书签被折叠了");
    }
  } else {
    NSLog(@"[BookmarkHighlight] 未找到匹配的书签");
    // 清除选择
    [self.outline deselectAll:nil];
  }
}

- (void)expandParentsOfItem:(TocNode*)item {
  if (!item || !self.tocRoot) {
    return;
  }

  // 查找item的父节点路径
  NSMutableArray* parentPath = [NSMutableArray array];
  [self findParentPathForItem:item inNode:self.tocRoot parentPath:parentPath];

  // 展开所有父节点
  for (TocNode* parent in parentPath) {
    if (parent != self.tocRoot) {  // 不展开根节点
      [self.outline expandItem:parent];
      NSLog(@"[BookmarkHighlight] 展开父节点: %@", parent.title);
    }
  }
}

- (BOOL)findParentPathForItem:(TocNode*)targetItem
                       inNode:(TocNode*)currentNode
                   parentPath:(NSMutableArray*)path {
  if (!currentNode) {
    return NO;
  }

  // 将当前节点加入路径
  [path addObject:currentNode];

  // 检查是否找到目标项
  if (currentNode == targetItem) {
    return YES;
  }

  // 在子节点中搜索
  for (TocNode* child in currentNode.children) {
    if ([self findParentPathForItem:targetItem inNode:child parentPath:path]) {
      return YES;
    }
  }

  // 如果在这个分支中没找到，从路径中移除当前节点
  [path removeLastObject];
  return NO;
}

- (void)createExpandedBookmarkControls {
  NSLog(@"[BookmarkControl] 创建展开状态的书签控件");

  // 完全隐藏收起状态的控制栏，确保不会阻挡事件
  self.bookmarkControlBar.hidden = YES;
  self.bookmarkControlBar.alphaValue = 0.0;       // 完全透明
  [self.bookmarkControlBar removeFromSuperview];  // 临时从视图层次中移除

  // 创建顶部控制栏（包含标题、+/-按钮）
  CGFloat expandedWidth = self.leftPanel.bounds.size.width;  // 使用实际面板宽度
  CGFloat controlBarY = self.leftPanel.bounds.size.height - kControlBarHeight;
  NSLog(@"[ScrollDebug] 创建expandedTopControlBar: width=%.1f, y=%.1f, "
        @"leftPanel.bounds=%@",
        expandedWidth, controlBarY, NSStringFromRect(self.leftPanel.bounds));

  self.expandedTopControlBar =
      [[NSView alloc] initWithFrame:NSMakeRect(0, controlBarY, expandedWidth,
                                               kControlBarHeight)];
  self.expandedTopControlBar.wantsLayer = YES;
  self.expandedTopControlBar.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];

  // 设置自动调整掩码，确保状态栏跟随面板大小变化
  self.expandedTopControlBar.autoresizingMask =
      NSViewWidthSizable | NSViewMinYMargin;

  // 添加底部分隔线
  NSView* separator =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, expandedWidth, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable;  // 分隔线随宽度自动调整
  [self.expandedTopControlBar addSubview:separator];

  // 添加标题标签
  NSTextField* titleLabel =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, 50, 18)];
  titleLabel.stringValue = @"书签";
  titleLabel.font = [NSFont systemFontOfSize:13];
  titleLabel.textColor = [NSColor labelColor];
  titleLabel.backgroundColor = [NSColor clearColor];
  titleLabel.bordered = NO;
  titleLabel.editable = NO;
  titleLabel.selectable = NO;
  [self.expandedTopControlBar addSubview:titleLabel];

  // 添加展开所有按钮（+）
  NSButton* expandAllButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(70, 3, 24, 24)];
  expandAllButton.title = @"+";
  expandAllButton.font = [NSFont systemFontOfSize:14];
  expandAllButton.bordered = NO;
  expandAllButton.target = self;
  expandAllButton.action = @selector(expandAllBookmarks:);
  [self.expandedTopControlBar addSubview:expandAllButton];
  NSLog(@"[BookmarkControl] +按钮创建: frame=%@, superview=%@",
        NSStringFromRect(expandAllButton.frame), expandAllButton.superview);

  // 添加折叠所有按钮（-）
  NSButton* collapseAllButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(100, 3, 24, 24)];
  collapseAllButton.title = @"−";
  collapseAllButton.font = [NSFont systemFontOfSize:14];
  collapseAllButton.bordered = NO;
  collapseAllButton.target = self;
  collapseAllButton.action = @selector(collapseAllBookmarks:);
  [self.expandedTopControlBar addSubview:collapseAllButton];
  NSLog(@"[BookmarkControl] -按钮创建: frame=%@, superview=%@",
        NSStringFromRect(collapseAllButton.frame), collapseAllButton.superview);

  // 添加展开状态的收起按钮（位于右侧边缘）
  CGFloat buttonWidth = 16;
  CGFloat buttonHeight = 16;
  CGFloat rightMargin = 4;
  CGFloat yCenter = (kControlBarHeight - buttonHeight) / 2;
  CGFloat buttonX = expandedWidth - buttonWidth - rightMargin;
  NSButton* collapseButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(buttonX, yCenter, buttonWidth, buttonHeight)];
  collapseButton.title = @"◀";  // 左箭头表示可以收起
  collapseButton.font = [NSFont systemFontOfSize:10];
  collapseButton.bordered = NO;
  collapseButton.target = self;
  collapseButton.action = @selector(toggleBookmarkVisibility:);
  collapseButton.autoresizingMask = NSViewMinXMargin;  // 右对齐，随面板宽度调整
  [self.expandedTopControlBar addSubview:collapseButton];
  NSLog(
      @"[BookmarkControl] ◀按钮创建: frame=%@, expandedTopControlBar.bounds=%@",
      NSStringFromRect(collapseButton.frame),
      NSStringFromRect(self.expandedTopControlBar.bounds));

  [self.leftPanel addSubview:self.expandedTopControlBar];
  NSLog(@"[BookmarkControl] expandedTopControlBar创建: frame=%@, "
        @"leftPanel.bounds=%@",
        NSStringFromRect(self.expandedTopControlBar.frame),
        NSStringFromRect(self.leftPanel.bounds));

  // 显示书签列表
  NSLog(@"[ScrollDebug] 准备显示书签列表，设置 outlineScroll.hidden = NO");
  NSLog(@"[ScrollDebug] 显示前 outlineScroll frame: %@",
        NSStringFromRect(self.outlineScroll.frame));
  NSLog(@"[ScrollDebug] 显示前 leftPanel bounds: %@",
        NSStringFromRect(self.leftPanel.bounds));

  self.outlineScroll.hidden = NO;

  NSLog(@"[ScrollDebug] 显示后 outlineScroll hidden: %@",
        self.outlineScroll.hidden ? @"YES" : @"NO");

  // 立即检查滚动条状态
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"[ScrollDebug] 异步检查滚动条状态...");

    // 首先确保左侧面板和滚动视图尺寸正确
    [self ensureLeftPanelSize];

    // 更新展开状态控制栏布局
    [self updateExpandedControlBarLayout];

    [self forceTraditionalScrollBar];  // 强制使用传统滚动条
    [self updateBookmarkScrollView];
    [self ensureBookmarkScrollBarVisible];
    [self checkScrollBarOverlap];  // 检查滚动条是否被遮挡
  });
}

- (void)removeExpandedBookmarkControls {
  NSLog(@"[BookmarkControl] 移除展开状态的书签控件");

  // 移除顶部控制栏
  if (self.expandedTopControlBar) {
    [self.expandedTopControlBar removeFromSuperview];
    self.expandedTopControlBar = nil;
  }

  // 恢复收起状态的控制栏
  [self.leftPanel addSubview:self.bookmarkControlBar];
  self.bookmarkControlBar.hidden = NO;
  self.bookmarkControlBar.alphaValue = 1.0;  // 恢复不透明

  // 隐藏书签列表
  self.outlineScroll.hidden = YES;
}

- (void)updateStatusBar {
  NSLog(@"[StatusBar] updateStatusBar被调用");

  @try {
    NSLog(@"[StatusBar] 检查self.view...");
    if (!self.view) {
      NSLog(@"[StatusBar] self.view为nil");
      return;
    }
    NSLog(@"[StatusBar] self.view: %@", self.view);

    NSLog(@"[StatusBar] 检查document...");
    FPDF_DOCUMENT doc = [self.view document];
    NSLog(@"[StatusBar] document: %p", doc);

    NSLog(@"[StatusBar] 检查状态栏组件...");
    NSLog(@"[StatusBar] statusBar: %@", self.statusBar);
    NSLog(@"[StatusBar] pageInput: %@", self.pageInput);
    NSLog(@"[StatusBar] totalPagesLabel: %@", self.totalPagesLabel);
    NSLog(@"[StatusBar] prevPageButton: %@", self.prevPageButton);
    NSLog(@"[StatusBar] nextPageButton: %@", self.nextPageButton);

    // 检查状态栏组件是否已初始化
    if (!self.statusBar || !self.pageInput || !self.totalPagesLabel ||
        !self.prevPageButton || !self.nextPageButton) {
      NSLog(@"[StatusBar] 状态栏组件未初始化，跳过更新");
      return;
    }

    if (!doc) {
      NSLog(@"[StatusBar] 没有文档，设置默认值");
      self.pageInput.stringValue = @"1";
      self.totalPagesLabel.stringValue = @"/ 0";
      self.prevPageButton.enabled = NO;
      self.nextPageButton.enabled = NO;
      return;
    }

    NSLog(@"[StatusBar] 获取页面信息...");
    int currentPage = [self.view currentPageIndex] + 1;  // 显示从1开始的页码
    int totalPages = FPDF_GetPageCount(doc);

    NSLog(@"[StatusBar] 当前页: %d, 总页数: %d", currentPage, totalPages);

    NSLog(@"[StatusBar] 更新UI组件...");
    self.pageInput.stringValue = [NSString stringWithFormat:@"%d", currentPage];
    self.totalPagesLabel.stringValue =
        [NSString stringWithFormat:@"/ %d", totalPages];

    self.prevPageButton.enabled = (currentPage > 1);
    self.nextPageButton.enabled = (currentPage < totalPages);

    NSLog(@"[StatusBar] 状态栏更新完成: %@ %@", self.pageInput.stringValue,
          self.totalPagesLabel.stringValue);
  } @catch (NSException* exception) {
    NSLog(@"[StatusBar] 异常: %@", exception);
  }
}

- (void)onPrevPage:(id)sender {
  if (!self.view || ![self.view document]) {
    return;
  }
  int currentPage = [self.view currentPageIndex];
  if (currentPage > 0) {
    [self.view goToPage:currentPage - 1];
    [self updateStatusBar];
  }
}

- (void)onNextPage:(id)sender {
  if (!self.view || ![self.view document]) {
    return;
  }
  int totalPages = FPDF_GetPageCount([self.view document]);
  int currentPage = [self.view currentPageIndex];
  if (currentPage < totalPages - 1) {
    [self.view goToPage:currentPage + 1];
    [self updateStatusBar];
  }
}

- (void)onPageInputChanged:(id)sender {
  if (!self.view || ![self.view document]) {
    return;
  }

  NSString* input = self.pageInput.stringValue;
  int pageNum = [input intValue];
  int totalPages = FPDF_GetPageCount([self.view document]);

  // 边界检查：确保页码在有效范围内
  int validPageNum = pageNum;
  if (pageNum < 1) {
    validPageNum = 1;  // 小于最小值时使用最小值
    NSLog(@"[PageNavigation] 状态栏输入页码%d小于1，调整为最小值: %d", pageNum,
          validPageNum);
  } else if (pageNum > totalPages) {
    validPageNum = totalPages;  // 大于最大值时使用最大值
    NSLog(@"[PageNavigation] 状态栏输入页码%d超过最大值%d，调整为最大值: %d",
          pageNum, totalPages, validPageNum);
  }

  // 应用有效的页码
  [self.view goToPage:validPageNum - 1];  // 转换为0开始的索引
  NSLog(@"[PageNavigation] 状态栏页码设置为: %d (索引: %d)", validPageNum,
        validPageNum - 1);
  [self updateStatusBar];
}

@end
*/

#pragma mark - PdfViewDelegate

@implementation AppDelegate (PdfViewDelegate)

- (void)pdfViewDidChangePage:(id)sender {
  NSLog(@"[StatusBar] pdfViewDidChangePage被调用");
  if (self.statusBar) {
    [self updateStatusBar];
  } else {
    NSLog(@"[StatusBar] 状态栏尚未初始化，跳过更新");
  }

  // 高亮当前书签
  [self highlightCurrentBookmark];

  // 更新检查器内容
  [self updateInspectorContent];
}

@end

#pragma mark - 检查器面板相关方法 - 已迁移到InspectorPanelController
/*
- (void)createInspectorPanel {
  NSLog(@"[Inspector] 开始创建检查器面板");

  // 创建检查器面板容器
  self.inspectorPanel = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, kInspectorWidth,
                               self.rightPanel.bounds.size.height)];
  self.inspectorPanel.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  self.inspectorPanel.wantsLayer = YES;
  self.inspectorPanel.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];

  // 添加标题栏
  NSView* titleBar = [[NSView alloc]
      initWithFrame:NSMakeRect(0,
                               self.inspectorPanel.bounds.size.height -
                                   kControlBarHeight,
                               kInspectorWidth, kControlBarHeight)];
  titleBar.wantsLayer = YES;
  titleBar.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
  titleBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

  // 添加标题
  NSTextField* titleLabel =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, 100, 18)];
  titleLabel.stringValue = @"页面元素";
  titleLabel.font = [NSFont boldSystemFontOfSize:13];
  titleLabel.textColor = [NSColor labelColor];
  titleLabel.backgroundColor = [NSColor clearColor];
  titleLabel.bordered = NO;
  titleLabel.editable = NO;
  titleLabel.selectable = NO;
  [titleBar addSubview:titleLabel];

  // 添加收起按钮
  NSButton* collapseButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(kInspectorWidth - 30, 5, 20, 20)];
  collapseButton.title = @"◀";
  collapseButton.font = [NSFont systemFontOfSize:10];
  collapseButton.bordered = NO;
  collapseButton.target = self;
  collapseButton.action = @selector(toggleInspectorVisibility:);
  collapseButton.autoresizingMask = NSViewMinXMargin;
  [titleBar addSubview:collapseButton];

  // 添加底部分隔线
  NSView* separator =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kInspectorWidth, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable;
  [titleBar addSubview:separator];

  [self.inspectorPanel addSubview:titleBar];

  // 创建文本视图用于显示页面信息(使用自定义类支持Cmd+A)
  NSRect textFrame =
      NSMakeRect(0, 0, kInspectorWidth,
                 self.inspectorPanel.bounds.size.height - kControlBarHeight);
  self.inspectorTextView = [[SelectableTextView alloc] initWithFrame:textFrame];
  self.inspectorTextView.editable = NO;
  self.inspectorTextView.selectable = YES;

  // 启用 Cmd+A 全选功能
  self.inspectorTextView.usesFindPanel = YES;
  self.inspectorTextView.allowsUndo = NO;

  // 初始化对象位置映射
  self.objectPositions = [[NSMutableDictionary alloc] init];
  self.inspectorTextView.delegate = self;  // 设置代理以处理点击事件
  self.inspectorTextView.font =
      [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  self.inspectorTextView.textColor = [NSColor labelColor];
  self.inspectorTextView.backgroundColor = [NSColor textBackgroundColor];

  // 设置自动换行和文本容器属性
  self.inspectorTextView.textContainer.containerSize =
      NSMakeSize(textFrame.size.width, CGFLOAT_MAX);
  self.inspectorTextView.textContainer.widthTracksTextView = YES;
  self.inspectorTextView.textContainer.heightTracksTextView = NO;
  self.inspectorTextView.textContainer.lineBreakMode =
      NSLineBreakByWordWrapping;

  // 设置文本视图的自动调整行为
  self.inspectorTextView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  self.inspectorTextView.horizontallyResizable = NO;  // 禁用水平调整
  self.inspectorTextView.verticallyResizable = YES;   // 启用垂直调整

  // 添加鼠标点击事件监听
  NSClickGestureRecognizer* clickGesture = [[NSClickGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(inspectorTextViewClicked:)];
  [self.inspectorTextView addGestureRecognizer:clickGesture];

  NSLog(@"[Inspector] 文本视图自动换行配置完成，容器宽度: %.1f",
        textFrame.size.width);

  // 创建滚动视图
  self.inspectorScrollView = [[NSScrollView alloc] initWithFrame:textFrame];
  self.inspectorScrollView.documentView = self.inspectorTextView;
  self.inspectorScrollView.hasVerticalScroller = YES;
  self.inspectorScrollView.hasHorizontalScroller = YES;
  self.inspectorScrollView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [self.inspectorPanel addSubview:self.inspectorScrollView];

  NSLog(@"[Inspector] 检查器面板创建完成");
}

- (void)toggleInspectorVisibility:(id)sender {
  NSLog(@"[Inspector] 切换检查器可见性，当前状态: %@",
        self.inspectorVisible ? @"可见" : @"隐藏");
  [self setInspectorVisible:!self.inspectorVisible animated:YES];
}

- (void)setInspectorVisible:(BOOL)visible animated:(BOOL)animated {
  if (self.inspectorVisible == visible) {
    return;  // 状态未改变
  }

  self.inspectorVisible = visible;
  NSLog(@"[Inspector] 设置检查器可见性: %@", visible ? @"显示" : @"隐藏");

  // 更新按钮文本
  //
检查器隐藏时显示◀（表示点击打开右侧窗口），检查器显示时显示▶（表示点击关闭右侧窗口）
  self.inspectorToggleButton.title = visible ? @"▶" : @"◀";

  // 获取右侧分割视图
  NSSplitView* rightSplit = (NSSplitView*)self.rightPanel.subviews.firstObject;
  if (![rightSplit isKindOfClass:[NSSplitView class]]) {
    return;
  }

  // 使用 NSSplitView 的折叠功能来完全收起/展开面板
  // inspectorPanel 是第二个子视图（index 1）
  BOOL inspectorAttached =
      [rightSplit.subviews containsObject:self.inspectorPanel];

  if (visible) {
    // 确保检查器面板已经添加到 split view 中
    if (!inspectorAttached) {
      [rightSplit addSubview:self.inspectorPanel];
    }

    // 展开：显示检查器面板
    CGFloat newPosition = self.rightPanel.bounds.size.width - kInspectorWidth;

    // 先取消隐藏，让 NSSplitView 知道需要为该子视图分配空间
    self.inspectorPanel.hidden = NO;

    // 立即调整现有子视图，防止旧尺寸影响布局
    [rightSplit adjustSubviews];

    // 设置新的分割位置
    [rightSplit setPosition:newPosition ofDividerAtIndex:0];
    [rightSplit layoutSubtreeIfNeeded];

    NSLog(@"[Inspector] 检查器面板展开，frame: %@",
          NSStringFromRect(self.inspectorPanel.frame));

    // 更新面板布局和内容
    [self updateInspectorLayout];
    [self updateInspectorContent];
  } else {
    // 收起：完全隐藏检查器面板
    CGFloat collapsedPosition = self.rightPanel.bounds.size.width;

    NSLog(@"[Inspector] 收起检查器，rightPanel宽度: %.1f, 目标位置: %.1f",
          self.rightPanel.bounds.size.width, collapsedPosition);

    // 设置位置，让 PDF 内容占满
    [rightSplit setPosition:collapsedPosition ofDividerAtIndex:0];
    [rightSplit layoutSubtreeIfNeeded];

    // 隐藏检查器面板
    self.inspectorPanel.hidden = YES;

    // 从 split view 中移除检查器面板，防止占用布局空间
    if (inspectorAttached) {
      [self.inspectorPanel removeFromSuperview];
      [rightSplit adjustSubviews];
    }

    NSLog(@"[Inspector] 检查器收起完成，pdfContentView frame: %@, "
          @"inspectorPanel frame: %@, 按钮 frame: %@",
          NSStringFromRect(self.pdfContentView.frame),
          NSStringFromRect(self.inspectorPanel.frame),
          NSStringFromRect(self.inspectorToggleButton.frame));
  }
}

- (void)updateInspectorLayout {
  if (!self.inspectorVisible || !self.inspectorTextView) {
    return;
  }

  // 更新文本容器大小以适应窗口变化
  NSRect currentFrame = self.inspectorScrollView.frame;
  CGFloat newWidth = currentFrame.size.width - 20;  // 减去滚动条和边距

  self.inspectorTextView.textContainer.containerSize =
      NSMakeSize(newWidth, CGFLOAT_MAX);
  [self.inspectorTextView setNeedsDisplay:YES];

  NSLog(@"[Inspector] 文本容器宽度已更新为: %.1f", newWidth);
}

// 递归显示对象树节点
- (void)displayObjectTreeNode:(PDFIUM_EX_OBJECT_TREE_NODE*)node
             attributedString:(NSMutableAttributedString*)attributedInfo
                  normalAttrs:(NSDictionary*)normalAttrs
                  objNumAttrs:(NSDictionary*)objNumAttrs {
  if (!node || !attributedInfo || !normalAttrs || !objNumAttrs) {
    return;
  }

  // 安全检查：防止递归过深
  if (node->depth > 10) {
    NSString* warningStr = [NSString
        stringWithFormat:@"[警告] 对象 %u 递归深度过深，已停止展开\n\n",
                         node->obj_num];
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:warningStr
                                                   attributes:normalAttrs]];
    return;
  }

  // 记录对象在文本中的位置（用于点击跳转）
  NSUInteger objStartPosition = attributedInfo.length;
  NSString* objKey = [NSString stringWithFormat:@"%u", node->obj_num];
  [self.objectPositions setObject:@(objStartPosition) forKey:objKey];

  // 显示对象号（天空蓝色）
  NSString* objNumStr =
      [NSString stringWithFormat:@"%u %u obj", node->obj_num, node->gen_num];
  if (objNumStr) {
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:objNumStr
                                                   attributes:objNumAttrs]];
  }
  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:@"\n<<\n"
                                                 attributes:normalAttrs]];

  // 显示对象内容（安全检查）
  if (node->raw_content && strlen(node->raw_content) > 0) {
    NSString* contentStr = [NSString stringWithUTF8String:node->raw_content];
    if (contentStr && contentStr.length > 0) {
      // 创建带颜色的内容字符串，将对象引用标记为绿色
      NSMutableAttributedString* coloredContent =
          [self colorizeObjectReferences:contentStr normalAttrs:normalAttrs];
      [attributedInfo appendAttributedString:coloredContent];
      [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                                 initWithString:@"\n"
                                                     attributes:normalAttrs]];
    }
  }

  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:@">>\nendobj\n\n"
                                                 attributes:normalAttrs]];

  // 如果有子节点，直接显示子节点（添加安全检查）
  if (node->children && node->child_count > 0) {
    // 限制显示的子节点数量，避免界面卡顿
    int maxDisplayChildren = 1000;
    int displayCount = (node->child_count < maxDisplayChildren)
                           ? node->child_count
                           : maxDisplayChildren;

    for (int i = 0; i < displayCount; i++) {
      if (node->children[i]) {
        [self displayObjectTreeNode:node->children[i]
                   attributedString:attributedInfo
                        normalAttrs:normalAttrs
                        objNumAttrs:objNumAttrs];
      }
    }

    // 如果子节点数量超过限制，显示提示信息
    if (node->child_count > maxDisplayChildren) {
      NSString* warningStr = [NSString
          stringWithFormat:@"[提示] 对象 %u 有 %d 个子节点，仅显示前 %d 个\n\n",
                           node->obj_num, node->child_count,
                           maxDisplayChildren];
      [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                                 initWithString:warningStr
                                                     attributes:normalAttrs]];
    }
  }
}

- (void)updateInspectorContent {
  if (!self.inspectorVisible || !self.inspectorTextView || !self.view) {
    return;
  }

  FPDF_DOCUMENT doc = [self.view document];
  if (!doc) {
    self.inspectorTextView.string = @"没有打开的PDF文档";
    return;
  }

  int currentPage = [self.view currentPageIndex];
  int totalPages = FPDF_GetPageCount(doc);

  // 获取当前页面
  FPDF_PAGE page = FPDF_LoadPage(doc, currentPage);
  if (!page) {
    self.inspectorTextView.string = @"无法加载当前页面";
    return;
  }

  // 获取页面尺寸
  double pageWidth = FPDF_GetPageWidth(page);
  double pageHeight = FPDF_GetPageHeight(page);

  // 获取页面对象数量（内容流中的绘图对象）
  int pageObjectCount = FPDFPage_CountObjects(page);

  // 获取注释数量
  int annotCount = FPDFPage_GetAnnotCount(page);

  // 构建带颜色的属性文本
  NSMutableAttributedString* attributedInfo =
      [[NSMutableAttributedString alloc] init];

  // 基础文本属性
  NSDictionary* normalAttrs = @{
    NSForegroundColorAttributeName : [NSColor textColor],
    NSFontAttributeName :
        [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
  };

  // 天空蓝色对象号属性
  NSDictionary* objNumAttrs = @{
    NSForegroundColorAttributeName : [NSColor systemBlueColor],
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12
                                                      weight:NSFontWeightBold]
  };

  // 清空对象位置映射
  [self.objectPositions removeAllObjects];

  // 构建PDF对象引用树
  PDFIUM_EX_OBJECT_TREE_NODE* object_tree =
      PdfiumEx_BuildObjectTree(doc, page, 1000000);  // 最大深度，支持完整分析

  // 统计对象树中的总对象数
  int totalObjectCount = 0;
  if (object_tree) {
    totalObjectCount = PdfiumEx_CountObjectTreeNodes(object_tree);
  }

  // 添加基础信息
  NSString* basicInfo = [NSString
      stringWithFormat:@"PDF 文档信息\n================\n\n当前页面: %d / "
                       @"%d\n页面尺寸: %.2f x %.2f pt\n"
                       @"页面绘图对象: %d\n注释对象: %d\n对象树节点数: %d\n\n"
                       @"PDF对象引用树\n================\n",
                       currentPage + 1, totalPages, pageWidth, pageHeight,
                       pageObjectCount, annotCount, totalObjectCount];
  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:basicInfo
                                                 attributes:normalAttrs]];

  if (object_tree) {
    // 递归显示树结构
    [self displayObjectTreeNode:object_tree
               attributedString:attributedInfo
                    normalAttrs:normalAttrs
                    objNumAttrs:objNumAttrs];

    PdfiumEx_ReleaseObjectTree(object_tree);
  } else {
    // 如果对象树不可用，显示提示信息
    NSString* treeInfo = @"\n注意: PDF对象引用树功能暂未实现\n";
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:treeInfo
                                                   attributes:normalAttrs]];
  }

  FPDF_ClosePage(page);

  // 更新文本视图
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.inspectorTextView.textStorage setAttributedString:attributedInfo];
    NSLog(@"[Inspector] 检查器内容已更新，页面 %d", currentPage + 1);
  });
}

// 处理显示窗口通知（用于单实例功能）
- (void)handleShowWindowNotification:(NSNotification*)notification {
  NSLog(@"[PdfWinViewer] 收到显示窗口通知，激活应用并显示窗口");
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp activateIgnoringOtherApps:YES];
    if (self.window) {
      [self.window makeKeyAndOrderFront:nil];
      [self.window orderFrontRegardless];
    }
  });
}

// 应用即将退出时的清理工作
- (void)applicationWillTerminate:(NSNotification*)notification {
  LOG_INFO("========================================");
  LOG_INFO("Application will terminate");
  LOG_INFO("Flushing logs...");
  pdfium_viewer::Logger::GetInstance().Flush();
  LOG_INFO("Application terminated gracefully");
  LOG_INFO("========================================");
}

// 当最后一个窗口关闭时退出应用
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  return YES;
}
*/

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    // ========== 清空旧的 debug.log 文件（MacLog 系统） ==========
#if PDFWV_ENABLE_LOGGING
    MacLog_ResetFileOnStartup();
#endif

    // ========== 初始化全局日志系统 ==========
    NSString* execPath = [[NSBundle mainBundle] executablePath];
    std::string app_path = [execPath UTF8String];

    // 初始化日志：10MB 文件大小，保留 5 个历史文件
    pdfium_viewer::Logger::GetInstance().Initialize(app_path, 10 * 1024 * 1024,
                                                    5);

    // 设置为 DEBUG 级别（开发阶段）
    pdfium_viewer::Logger::GetInstance().SetLevel(
        pdfium_viewer::LogLevel::DEBUG);

// 开发时启用控制台输出（可选）
#ifdef DEBUG
    pdfium_viewer::Logger::GetInstance().SetConsoleOutput(true);
#endif

    LOG_INFO("========================================");
    LOG_INFO("PdfWinViewer Application Starting");
    LOG_INFO_F("Version: %s", "1.0.0");
    LOG_INFO_F("PID: %d", getpid());
    LOG_INFO_F("Executable: %s", app_path.c_str());
    LOG_INFO("========================================");

    // ========== [AP-FORM-IMAGE-WATERMARK] 初始化水印回调 ==========
    static WatermarkCallback* g_watermark_callback = new WatermarkCallback();
    CPDFSDK_SetApFormImageCallback(g_watermark_callback);
    LOG_INFO("[AP-FORM-IMAGE-WATERMARK] Watermark callback registered");
    // ================================================================

    // 检查是否已有实例运行
    LOG_INFO("========================================");
    LOG_INFO("Checking for existing instances...");
    NSString* bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    LOG_INFO_F("Bundle identifier: %s", [bundleIdentifier UTF8String]);

    NSArray<NSRunningApplication*>* runningApps = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:bundleIdentifier];
    LOG_INFO_F("Found %lu running instances", (unsigned long)runningApps.count);

    // 获取当前进程 ID
    pid_t currentPID = [NSProcessInfo processInfo].processIdentifier;
    LOG_INFO_F("Current PID: %d", currentPID);

    // 检查是否有其他实例运行（排除当前进程）
    NSRunningApplication* existingApp = nil;
    for (NSRunningApplication* app in runningApps) {
      LOG_INFO_F("  - Instance PID: %d (current: %s)", app.processIdentifier,
                 (app.processIdentifier == currentPID ? "YES" : "NO"));
      if (app.processIdentifier != currentPID) {
        existingApp = app;
        break;
      }
    }

    // 如果已有其他实例运行，激活它并退出
    if (existingApp) {
      LOG_WARNING_F(
          "⚠️  Detected existing instance (PID: %d), activating and exiting",
          existingApp.processIdentifier);
      LOG_INFO_F("检测到已有实例运行（PID: %d），激活现有窗口并退出",
                 existingApp.processIdentifier);
      NSLog(@"[PdfWinViewer] 检测到已有实例运行（PID: %d），激活现有窗口并退出",
            existingApp.processIdentifier);

      // 激活现有实例
      [existingApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];

      // 发送通知让已运行的实例显示窗口
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:@"com.zfleng.PdfWinViewer.ShowWindow"
                          object:nil
                        userInfo:nil
              deliverImmediately:YES];
      });

      // 退出当前进程
      return 0;
    }

    LOG_INFO("单实例检查通过，启动应用");
    NSApplication* app = [NSApplication sharedApplication];

    // 设置为前台应用（非后台应用）
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    AppDelegate* del = [AppDelegate new];
    app.delegate = del;

    // 监听显示窗口通知
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:del
           selector:@selector(handleShowWindowNotification:)
               name:@"com.zfleng.PdfWinViewer.ShowWindow"
             object:nil];

    // 激活应用并显示窗口
    [app activateIgnoringOtherApps:YES];
    [app run];
  }
  return 0;
}
