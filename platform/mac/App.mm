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
#include "CustomImageCallback.h"           // [AP-FORM-IMAGE-REPLACEMENT]
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

// ================= 自定义按钮类：支持手型光标 =================
@interface HandCursorButton : NSButton
@end

@implementation HandCursorButton
- (void)resetCursorRects {
  [super resetCursorRects];
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

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
  LOG_TAG_NS("PdfWinViewer", "PDFium error at %s: %lu (%@)", where, code,
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

// 水印相关属性
@property(nonatomic, assign) BOOL watermarkEnabled;  // 水印是否启用
@property(nonatomic, assign) WatermarkCallback* watermarkCallback;  // 水印回调实例

// [AP-FORM-IMAGE-REPLACEMENT] 图片替换相关属性
@property(nonatomic, assign) CustomImageCallback* imageCallback;  // 图片替换回调实例
@property(nonatomic, assign) BOOL imageReplacementEnabled;  // 图片替换是否启用
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
  LOG_TAG_NS("Window", "窗口创建完成，frame: %@, visible: %@",
             NSStringFromRect(self.window.frame),
             self.window.isVisible ? @"YES" : @"NO");

  // 创建主容器视图，包含主内容区域和底部状态栏(支持拖拽打开PDF)
  DragDropView* containerView =
      [[DragDropView alloc] initWithFrame:self.window.contentView.bounds];
  containerView.appDelegate = self;
  containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // ========== 初始化模块化Controller ==========
  // 初始化水印状态（默认关闭）
  self.watermarkEnabled = NO;
  
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
  LOG_TAG_NS("StatusBar", "状态栏已添加到容器视图，frame: %@",
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
  LOG_TAG_NS("ScrollDebug", "outline宽度: %.1f (预留滚动条空间: %.1f)",
             outlineWidth, kScrollBarWidth);

  self.outline = [[NSOutlineView alloc] initWithFrame:outlineFrame];
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"toc"];
  col.title = @"书签";
  col.width = outlineWidth - 20;  // 为滚动条和边距预留空间
  col.minWidth = 100;
  col.maxWidth = outlineWidth - 10;
  LOG_TAG_NS("ScrollDebug", "表格列宽度: %.1f", col.width);
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

  LOG_TAG_NS("ScrollDebug", "========== 初始化书签滚动视图 ==========");
  LOG_TAG_NS("ScrollDebug", "outlineFrame: %@", NSStringFromRect(outlineFrame));

  // 滚动视图应该占据整个展开宽度，为滚动条提供空间
  NSRect scrollFrame =
      NSMakeRect(0, 0, kBookmarkExpandedWidth,
                 self.leftPanel.bounds.size.height - kControlBarHeight);
  LOG_TAG_NS("ScrollDebug", "scrollFrame: %@", NSStringFromRect(scrollFrame));

  self.outlineScroll = [[NSScrollView alloc] initWithFrame:scrollFrame];
  self.outlineScroll.documentView = self.outline;

  LOG_TAG_NS("ScrollDebug", "滚动视图创建完成，frame: %@",
             NSStringFromRect(self.outlineScroll.frame));

  // 垂直滚动条配置 - 确保始终可见且功能正常
  self.outlineScroll.hasVerticalScroller = YES;
  self.outlineScroll.hasHorizontalScroller =
      NO;  // 禁用水平滚动条，避免占用空间
  self.outlineScroll.autohidesScrollers =
      NO;  // 始终显示滚动条，提供更好的用户反馈

  LOG_TAG_NS("ScrollDebug",
             "基本滚动条配置完成 - hasVertical: YES, hasHorizontal: "
            @"NO, autohides: NO");

  // 为了调试，暂时使用传统滚动条样式，更容易看到
  self.outlineScroll.scrollerStyle =
      NSScrollerStyleLegacy;  // 传统滚动条，更明显可见
  LOG_TAG_NS("ScrollDebug",
             "使用传统滚动条样式: NSScrollerStyleLegacy (调试模式)");

  // 滚动行为优化
  self.outlineScroll.verticalScrollElasticity =
      NSScrollElasticityAllowed;  // 允许弹性滚动
  self.outlineScroll.horizontalScrollElasticity =
      NSScrollElasticityNone;                  // 禁用水平弹性滚动
  self.outlineScroll.borderType = NSNoBorder;  // 无边框，更简洁
  self.outlineScroll.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;

  LOG_TAG_NS("ScrollDebug", "滚动行为配置完成");

  // 检查初始滚动条状态
  NSScroller* initialVScroller = self.outlineScroll.verticalScroller;
  if (initialVScroller) {
    LOG_TAG_NS("ScrollDebug", "✅ 初始垂直滚动条已创建");
    LOG_TAG_NS("ScrollDebug", "初始滚动条 frame: %@",
               NSStringFromRect(initialVScroller.frame));
    LOG_TAG_NS("ScrollDebug", "初始滚动条 hidden: %@",
               initialVScroller.hidden ? @"YES" : @"NO");
    LOG_TAG_NS("ScrollDebug", "初始滚动条 enabled: %@",
               initialVScroller.enabled ? @"YES" : @"NO");

    // 滚动条宽度和位置优化
    initialVScroller.controlSize = NSControlSizeRegular;
    LOG_TAG_NS("ScrollDebug", "滚动条控件大小设置为 Regular");
  } else {
    LOG_TAG_NS("ScrollDebug", "❌ 初始垂直滚动条未创建！");
  }

  // 确保滚动视图内容正确更新
  [self.outlineScroll setNeedsDisplay:YES];

  self.outlineScroll.hidden = NO;  // 默认显示
  LOG_TAG_NS("ScrollDebug", "滚动视图设置为显示状态");

  [self.leftPanel addSubview:self.outlineScroll];
  LOG_TAG_NS("ScrollDebug", "滚动视图已添加到左侧面板");

  // 更新bookmarkDelegate和bookmarkPanelController的outlineScroll引用
  self.bookmarkDelegate.outlineScroll = self.outlineScroll;
  self.bookmarkPanelController.outlineScroll = self.outlineScroll;
  self.bookmarkPanelController.outline = self.outline;

  // 检查视图层次结构
  LOG_TAG_NS("ScrollDebug", "leftPanel frame: %@",
             NSStringFromRect(self.leftPanel.frame));
  LOG_TAG_NS("ScrollDebug", "leftPanel subviews count: %lu",
             (unsigned long)self.leftPanel.subviews.count);
  for (NSUInteger i = 0; i < self.leftPanel.subviews.count; i++) {
    NSView* subview = self.leftPanel.subviews[i];
    LOG_TAG_NS("ScrollDebug", "leftPanel subview[%lu]: %@ frame: %@",
               (unsigned long)i, NSStringFromClass([subview class]),
               NSStringFromRect(subview.frame));
  }

  LOG_TAG_NS("ScrollDebug", "========== 书签滚动视图初始化完成 ==========");

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
  NSColor* pdfBackdropColor =
      [NSColor colorWithCalibratedWhite:0.16 alpha:1.0];
  self.pdfContentView.wantsLayer = YES;
  self.pdfContentView.layer.backgroundColor = pdfBackdropColor.CGColor;

  // 创建PDF视图
  self.view = [[PdfView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  self.view.delegate = self;
  
  // [FIX-COLOR-MISMATCH] 将PDF视图背景色设置为与外层容器一致的深灰色(0.16)，
  // 消除PDF区域(红色框)与背景区域(蓝色框)之间的颜色差异
  if ([self.view respondsToSelector:@selector(setBackgroundColor:)]) {
    [self.view setBackgroundColor:pdfBackdropColor];
  }

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
  scroll.drawsBackground = YES;
  scroll.backgroundColor = pdfBackdropColor;
  scroll.contentView.drawsBackground = YES;
  if ([scroll.contentView respondsToSelector:@selector(setBackgroundColor:)]) {
    scroll.contentView.backgroundColor = pdfBackdropColor;
  }
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
  // 使用自定义按钮类，支持鼠标悬停时显示手型光标
  self.inspectorToggleButton = [[HandCursorButton alloc]
      initWithFrame:NSMakeRect(buttonX, buttonY, buttonWidth, buttonHeight)];
  self.inspectorToggleButton.title = @"◀";  // 初始隐藏状态，显示向左箭头
  self.inspectorToggleButton.font =
      [NSFont systemFontOfSize:21];          // 字体也调大50%（14 * 1.5）
  self.inspectorToggleButton.bordered = NO;  // 无边框，悬浮效果
  self.inspectorToggleButton.bezelStyle =
      NSBezelStyleTexturedSquare;  // 使用最简单的样式
  // 设置按钮样式为悬浮效果
  self.inspectorToggleButton.wantsLayer = YES;
  // 使用半透明灰色背景，让按钮更明显
  self.inspectorToggleButton.layer.backgroundColor =
      [[NSColor colorWithWhite:0.5 alpha:0.3] CGColor];
  self.inspectorToggleButton.layer.cornerRadius = 4.0;
  self.inspectorToggleButton.layer.borderWidth = 1.0;  // 添加细边框
  self.inspectorToggleButton.layer.borderColor =
      [[NSColor colorWithWhite:0.7 alpha:0.5] CGColor];  // 半透明边框
  // 添加阴影效果，让按钮更明显
  self.inspectorToggleButton.layer.shadowOpacity = 0.3;
  self.inspectorToggleButton.layer.shadowRadius = 3.0;
  self.inspectorToggleButton.layer.shadowOffset = NSMakeSize(0, -1);
  self.inspectorToggleButton.layer.shadowColor = [[NSColor blackColor] CGColor];
  // 设置更高的 z-index，确保在最上层
  self.inspectorToggleButton.layer.zPosition = 1000;
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

  // 将按钮赋值给控制器，以便控制器可以更新按钮状态
  self.inspectorPanelController.inspectorToggleButton =
      self.inspectorToggleButton;

  // 初始化按钮位置（初始状态为隐藏）
  [self.inspectorPanelController updateInspectorButtonPosition:NO];

  [self.split addSubview:self.leftPanel];
  [self.split addSubview:self.rightPanel];
  [self.split setPosition:initialWidth ofDividerAtIndex:0];  // 默认显示展开宽度
  [self.mainContentView addSubview:self.split];

  // 设置容器视图为窗口的内容视图
  self.window.contentView = containerView;
  LOG_TAG_NS("StatusBar", "容器视图设置为窗口内容视图，容器frame: %@",
             NSStringFromRect(containerView.frame));
  LOG_TAG_NS("StatusBar", "窗口contentView: %@", self.window.contentView);
  [self.window setTitle:@"PdfWinViewer (macOS)"];

  // 确保窗口可见并显示在前台
  [self.window setReleasedWhenClosed:NO];
  [self.window center];
  [NSApp activateIgnoringOtherApps:YES];
  [self.window makeKeyAndOrderFront:nil];
  [self.window orderFrontRegardless];

  LOG_TAG_NS("Window", "窗口已显示，frame: %@",
             NSStringFromRect(self.window.frame));

  // 设置窗口delegate以处理窗口事件（如关闭、resize等）
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
  LOG_TAG_NS("PdfWinViewer",
             "File menu constructed. recentMenuItem=%@ recentMenu=%@",
             self.recentMenuItem, self.recentMenu);
  // 调试：枚举文件菜单条目
  for (NSInteger i = 0; i < fileMenu.numberOfItems; ++i) {
    NSMenuItem* mi = [fileMenu itemAtIndex:i];
    LOG_TAG_NS("PdfWinViewer",
               "File menu item[%ld]: title='%@' hasSubmenu=%@ "
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
    LOG_TAG_NS("ScrollDebug", "初始化后更新展开状态布局...");
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
    LOG_TAG_NS("GlobalKey", "拦截到Cmd+F，显示查找面板");
    [self showFindPanel];
    return nil;  // 消费事件
  }

  // 拦截翻页相关的键盘事件，总是路由到PDF视图
  BOOL isPageNavigationKey = NO;

  if (c == NSPageUpFunctionKey || c == NSPageDownFunctionKey) {
    isPageNavigationKey = YES;
    LOG_TAG_NS("GlobalKey", "拦截到%@键",
               c == NSPageUpFunctionKey ? @"PageUp" : @"PageDown");
  } else if (c == NSHomeFunctionKey || c == NSEndFunctionKey) {
    isPageNavigationKey = YES;
    LOG_TAG_NS("GlobalKey", "拦截到%@键",
               c == NSHomeFunctionKey ? @"Home" : @"End");
  } else if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey) {
    // 只有在没有修饰键时才拦截箭头键（避免影响其他功能）
    if (mods == 0) {
      isPageNavigationKey = YES;
      LOG_TAG_NS("GlobalKey", "拦截到%@箭头键",
                 c == NSUpArrowFunctionKey ? @"上" : @"下");
    }
  }

  if (isPageNavigationKey) {
    LOG_TAG_NS("GlobalKey", "路由翻页键到PDF视图");

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

    LOG_TAG_NS("Find", "在检查器中找到文本: %@ at 位置: %lu", searchTerm,
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
      LOG_TAG_NS("Find", "在检查器中找到文本（从头开始）: %@ at 位置: %lu",
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
  LOG_TAG_NS("Find", "在检查器中未找到文本: %@", searchTerm);
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
    LOG_TAG_NS("Inspector", "对象引用正则表达式错误: %@",
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
  LOG_TAG_NS("Inspector", "PDF视图点击了对象，索引: %@", index);

  // 从NSValue中提取FPDF_PAGEOBJECT
  FPDF_PAGEOBJECT object = (FPDF_PAGEOBJECT)[objectValue pointerValue];

  // 这里我们需要将FPDF_PAGEOBJECT映射到实际的PDF对象号
  // 由于这比较复杂，我们先简单地刷新检查器内容，然后尝试跳转到相关对象
  [self updateInspectorContent];

  // TODO: 实现更精确的对象映射和跳转
  LOG_TAG_NS("Inspector", "已刷新检查器内容以响应PDF对象点击");
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

  LOG_TAG_NS("PdfWinViewer", "openPathAndAdjust: %@", path);
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

  MacLog_DebugNS(@"[OpenFile] 准备调用 [self.view openPDFAtPath:path]（异步）");
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[OpenFile] self.view = %@", self.view]);

  // 启动异步加载，结果将通过 delegate 回调返回
  [self.view openPDFAtPath:path];
  // 注意：后续的UI更新逻辑已移至 pdfView:didFinishLoadingDocument:error: 回调
}

@end

#pragma mark - NSWindowDelegate

@implementation AppDelegate (WindowDelegate)

- (void)windowDidResize:(NSNotification*)notification {
  // 窗口大小改变时的处理
  // 当前不需要特殊处理，留空以防止崩溃
}

@end

#pragma mark - PdfViewDelegate

@implementation AppDelegate (PdfViewDelegate)

- (void)pdfViewDidChangePage:(id)sender {
  LOG_TAG_NS("StatusBar", "pdfViewDidChangePage被调用");
  if (self.statusBar) {
    [self updateStatusBar];
  } else {
    LOG_TAG_NS("StatusBar", "状态栏尚未初始化，跳过更新");
  }

  // 高亮当前书签
  [self highlightCurrentBookmark];

  // 更新检查器内容
  [self updateInspectorContent];
}

- (void)pdfView:(id)sender
    didFinishLoadingDocument:(BOOL)success
                       error:(NSError*)error {
  if (!success) {
    // 加载失败
    if (error) {
      LOG_ERROR_F("PDF 文档加载失败：%s",
                  [[error localizedDescription] UTF8String]);

      // 如果不是用户取消，显示错误提示
      if (error.code != 2) {  // 2 = 用户取消
        NSAlert* alert = [NSAlert new];
        alert.messageText = @"无法打开 PDF";
        alert.informativeText = error.localizedDescription;
        [alert runModal];
      } else {
        LOG_INFO("用户取消了文档加载");
      }
    }
    return;
  }

  // 加载成功，执行UI初始化
  MacLog_DebugNS(@"[StatusBar] PDF文件加载成功，准备更新状态栏");
  LOG_INFO("PDF 文件加载成功，开始初始化界面");

  MacLog_DebugNS(@"[OpenFile] 调用 rebuildToc");
  [self rebuildToc];

  MacLog_DebugNS(@"[OpenFile] 设置 first responder");
  [self.window makeFirstResponder:self.view];

  // 更新状态栏显示
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

  // 先调整窗口大小
  NSSize s = [self.view currentPageSizePt];
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[OpenFile] 当前页面大小：%.0f x %.0f",
                                 s.width, s.height]);
  CGFloat newW = MIN(MAX(800, s.width + 300), 1600);
  CGFloat newH = MIN(MAX(600, s.height + 120), 1200);
  NSRect f = self.window.frame;
  f.size = NSMakeSize(newW, newH);
  [self.window setFrame:f display:NO animate:NO];
  LOG_DEBUG_F("窗口大小调整为：%.0f x %.0f", newW, newH);

  // 更新视图尺寸
  MacLog_DebugNS(@"[OpenFile] 调用 updateViewSizeToFitPage");
  [self.view updateViewSizeToFitPage];
  MacLog_DebugNS([NSString
      stringWithFormat:
          @"[OpenFile] PdfView frame after updateViewSizeToFitPage: %@",
          NSStringFromRect(self.view.frame)]);

  // 更新窗口标题
  NSString* currentPath = self.view.currentPath;
  if (currentPath) {
    self.window.title = [NSString
        stringWithFormat:@"PdfWinViewer - %@", currentPath.lastPathComponent];

    // 写入最近文件列表
    [self addRecentPath:currentPath];
    LOG_TAG_NS("PdfWinViewer", "after addRecentPath, recent count=%lu",
               (unsigned long)self.recentPaths.count);
    LOG_DEBUG_F("已添加到最近文件列表，当前列表数量：%lu",
                (unsigned long)self.recentPaths.count);
  }

  // 启用"导出当前页为 PNG"
  NSMenu* fileMenu = [[[NSApp mainMenu] itemWithTitle:@"文件"] submenu];
  NSMenuItem* exp = [fileMenu itemWithTag:9901];
  if (exp) {
    [exp setEnabled:YES];
  }

  LOG_INFO_F(
      "文件打开完成：%s",
      currentPath ? [[currentPath lastPathComponent] UTF8String] : "unknown");
  LOG_INFO_F("========================================");
}

@end

#pragma mark - Watermark Control

@implementation AppDelegate (WatermarkControl)

- (void)toggleWatermark:(id)sender {
  // 切换水印状态
  self.watermarkEnabled = !self.watermarkEnabled;
  
  // [FIX] 同步开关状态到 callback
  if (self.imageCallback) {
    self.imageCallback->SetWatermarkEnabled(self.watermarkEnabled);
    LOG_INFO_F("[Watermark] Switch set to: %s", self.watermarkEnabled ? "ON" : "OFF");
  }
  
  // 更新按钮标题
  if (self.statusBarController.watermarkToggleButton) {
    NSString* title = self.watermarkEnabled ? @"关闭水印" : @"启用水印";
    self.statusBarController.watermarkToggleButton.title = title;
  }
  
  // 更新全局水印回调
  extern void CPDFSDK_SetApFormImageCallback(void* pCallback);
  
  if (self.watermarkEnabled) {
    // 启用水印
    if (self.watermarkCallback) {
      CPDFSDK_SetApFormImageCallback(self.watermarkCallback);
      LOG_INFO("[Watermark] 水印已启用");
    } else {
      LOG_ERROR("[Watermark] 水印回调未初始化");
    }
  } else {
    // 禁用水印（如果没有启用图片替换）
    if (!self.imageReplacementEnabled) {
      CPDFSDK_SetApFormImageCallback(nullptr);
      LOG_INFO("[Watermark] 水印已禁用，callback 已清除");
    } else {
      LOG_INFO("[Watermark] 水印已禁用，但保留 callback（图片替换仍在使用）");
    }
  }
  
  // 重新渲染当前页面
  if (self.view) {
    [self.view setNeedsDisplay:YES];
    LOG_INFO("[Watermark] 页面重新渲染中...");
  }
}

@end

#pragma mark - Image Replacement Control

@implementation AppDelegate (ImageReplacementControl)

- (void)selectReplacementImage:(id)sender {
  // 如果已启用替换，则清除；否则选择新图片
  if (self.imageReplacementEnabled) {
    [self clearImageReplacement];
    return;
  }
  
  // [DEBUG] 添加测试路径选项
  NSEventModifierFlags flags = [NSEvent modifierFlags];
  if (flags & NSEventModifierFlagOption) {
    // 按住 Option 键时使用测试路径
    const char* test_path = "/Volumes/Lzf-MoveDisk/图片/ymhd.png";
    LOG_INFO_F("[ImageReplacement] [DEBUG] 使用测试路径: %s", test_path);
    
    if (self.imageCallback) {
      // [FIX] 必须先设置模式
      self.imageCallback->SetReplacementMode(CustomImageCallback::ReplacementMode::kGlobal);
      
      if (self.imageCallback->LoadReplacementImageFromFile(test_path)) {
        LOG_INFO("[ImageReplacement] [DEBUG] 测试路径加载成功！");
        self.imageReplacementEnabled = YES;
        
        // [FIX] 设置开关状态
        self.imageCallback->SetReplacementEnabled(true);
        LOG_INFO("[ImageReplacement] [DEBUG] Replacement switch enabled");
        
        // [FIX] 设置全局回调
        extern void CPDFSDK_SetApFormImageCallback(void* pCallback);
        CPDFSDK_SetApFormImageCallback(self.imageCallback);
        LOG_INFO("[ImageReplacement] [DEBUG] PDFium callback 已设置");
        
        if (self.statusBarController.imageReplacementButton) {
          self.statusBarController.imageReplacementButton.title = @"清除替换";
        }
        if (self.view) {
          [self.view setNeedsDisplay:YES];
        }
      } else {
        LOG_ERROR("[ImageReplacement] [DEBUG] 测试路径加载失败！");
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"[DEBUG] 测试失败";
        alert.informativeText = @"请查看控制台日志";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"确定"];
        [alert runModal];
      }
    }
    return;
  }
  
  // 打开文件选择对话框
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"选择替换图片";
  panel.message = @"选择一张图片用于替换 AP-Form 中的图片\n\n提示：按住 Option 键点击此按钮可测试固定路径";
  panel.allowedContentTypes = @[
    [UTType typeWithFilenameExtension:@"png"],
    [UTType typeWithFilenameExtension:@"jpg"],
    [UTType typeWithFilenameExtension:@"jpeg"]
  ];
  panel.allowsMultipleSelection = NO;
  panel.canChooseDirectories = NO;
  
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
    if (result == NSModalResponseOK) {
      NSURL* url = panel.URL;
      if (url && url.isFileURL) {
        const char* path = [url.path UTF8String];
        LOG_INFO_F("[ImageReplacement] 用户选择了图片: %s", path);
        
        // 加载图片并设置为全局替换
        if (self.imageCallback) {
          // [FIX] 必须先设置模式，LoadReplacementImageFromFile 才会保存图片
          self.imageCallback->SetReplacementMode(CustomImageCallback::ReplacementMode::kGlobal);
          
          if (self.imageCallback->LoadReplacementImageFromFile(path)) {
            LOG_INFO_F("[ImageReplacement] 图片加载成功，启用全局替换");
            self.imageReplacementEnabled = YES;
            
            // [FIX] 设置开关状态
            self.imageCallback->SetReplacementEnabled(true);
            LOG_INFO("[ImageReplacement] Replacement switch enabled");
            
            // [FIX] 设置全局回调，让 PDFium 能够使用
            extern void CPDFSDK_SetApFormImageCallback(void* pCallback);
            CPDFSDK_SetApFormImageCallback(self.imageCallback);
            LOG_INFO("[ImageReplacement] PDFium callback 已设置");
            
            // 更新按钮标题
            if (self.statusBarController.imageReplacementButton) {
              self.statusBarController.imageReplacementButton.title = @"清除替换";
            }
            
            // 重新渲染页面
            if (self.view) {
              [self.view setNeedsDisplay:YES];
              LOG_INFO("[ImageReplacement] 页面重新渲染中...");
            }
          } else {
            LOG_ERROR_F("[ImageReplacement] 图片加载失败: %s", path);
            
            // 显示错误
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"图片加载失败";
            alert.informativeText = @"无法加载选择的图片，请确保文件格式正确（支持 PNG/JPG）";
            alert.alertStyle = NSAlertStyleWarning;
            [alert addButtonWithTitle:@"确定"];
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
          }
        } else {
          LOG_ERROR("[ImageReplacement] imageCallback 未初始化");
        }
      }
    } else {
      LOG_INFO("[ImageReplacement] 用户取消了图片选择");
    }
  }];
}

- (void)clearImageReplacement {
  if (self.imageCallback) {
    // 设置为不替换模式
    self.imageCallback->SetReplacementMode(CustomImageCallback::ReplacementMode::kNone);
    self.imageCallback->SetReplacementEnabled(false);
    self.imageReplacementEnabled = NO;
    LOG_INFO("[ImageReplacement] Replacement switch disabled");
    
    // [FIX] 清除全局回调（如果没有启用水印）
    extern void CPDFSDK_SetApFormImageCallback(void* pCallback);
    if (!self.watermarkEnabled) {
      CPDFSDK_SetApFormImageCallback(nullptr);
      LOG_INFO("[ImageReplacement] PDFium callback 已清除");
    } else {
      // 如果水印还在用，就保持 callback（因为是同一个对象）
      LOG_INFO("[ImageReplacement] 保留 callback (水印仍在使用)");
    }
    
    // 更新按钮标题
    if (self.statusBarController.imageReplacementButton) {
      self.statusBarController.imageReplacementButton.title = @"选择替换图片";
    }
    
    LOG_INFO("[ImageReplacement] 图片替换已清除");
    
    // 重新渲染页面
    if (self.view) {
      [self.view setNeedsDisplay:YES];
      LOG_INFO("[ImageReplacement] 页面重新渲染中...");
    }
  }
}

@end

#pragma mark - NSSplitViewDelegate

@implementation AppDelegate (SplitViewDelegate)

- (void)splitView:(NSSplitView*)splitView
    resizeSubviewsWithOldSize:(NSSize)oldSize {
  // 获取分隔线的新尺寸
  NSSize newSize = splitView.frame.size;
  CGFloat dividerThickness = splitView.dividerThickness;

  // 判断是主分割视图还是右侧分割视图
  if (splitView == self.split) {
    // 主分割视图：左侧书签面板 + 右侧内容面板
    if (splitView.subviews.count >= 2) {
      NSView* leftView = splitView.subviews[0];   // 左侧面板
      NSView* rightView = splitView.subviews[1];  // 右侧面板

      CGFloat leftWidth = leftView.frame.size.width;  // 保持左侧宽度不变

      // 左侧面板保持原宽度
      [leftView setFrame:NSMakeRect(0, 0, leftWidth, newSize.height)];

      // 右侧面板占据剩余空间
      CGFloat rightWidth = newSize.width - leftWidth - dividerThickness;
      [rightView setFrame:NSMakeRect(leftWidth + dividerThickness, 0,
                                     rightWidth, newSize.height)];

      LOG_TAG_NS("SplitView",
                 "主分割视图调整 - 左侧: %.0f, 右侧: %.0f, 总宽度: %.0f",
                 leftWidth, rightWidth, newSize.width);
    }
  } else {
    // 右侧分割视图：PDF内容 + 检查器面板
    // 通过判断父视图是否为 rightPanel 来识别
    if (splitView.superview == self.rightPanel &&
        splitView.subviews.count >= 2) {
      NSView* pdfView = splitView.subviews[0];        // PDF内容视图
      NSView* inspectorView = splitView.subviews[1];  // 检查器面板

      CGFloat inspectorWidth =
          inspectorView.frame.size.width;  // 保持检查器宽度不变

      // PDF内容视图占据剩余空间（可伸缩）
      CGFloat pdfWidth = newSize.width - inspectorWidth - dividerThickness;
      [pdfView setFrame:NSMakeRect(0, 0, pdfWidth, newSize.height)];

      // 检查器面板保持原宽度
      [inspectorView setFrame:NSMakeRect(pdfWidth + dividerThickness, 0,
                                         inspectorWidth, newSize.height)];

      LOG_TAG_NS("SplitView",
                 "右侧分割视图调整 - PDF: %.0f, 检查器: %.0f, 总宽度: %.0f",
                 pdfWidth, inspectorWidth, newSize.width);
    }
  }
}

- (BOOL)splitView:(NSSplitView*)splitView
    shouldAdjustSizeOfSubview:(NSView*)view {
  if (splitView == self.split) {
    // 主分割视图：左侧面板（书签）不自动调整，右侧面板自动调整
    return view == splitView.subviews[1];  // 只有右侧面板（索引1）可以自动调整
  } else if (splitView.superview == self.rightPanel) {
    // 右侧分割视图：检查器面板不自动调整，PDF内容可以调整
    return view == splitView.subviews[0];  // 只有PDF内容（索引0）可以自动调整
  }
  return YES;  // 其他情况使用默认行为
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMinCoordinate:(CGFloat)proposedMin
               ofSubviewAt:(NSInteger)dividerIndex {
  if (splitView == self.split) {
    // 左侧面板最小宽度
    return kBookmarkCollapsedWidth;
  } else if (splitView.superview == self.rightPanel) {
    // PDF内容最小宽度
    return 300;
  }
  return proposedMin;
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMaxCoordinate:(CGFloat)proposedMax
               ofSubviewAt:(NSInteger)dividerIndex {
  if (splitView == self.split) {
    // 左侧面板最大宽度
    return kBookmarkExpandedWidth + 40;  // 允许稍微超过默认展开宽度
  } else if (splitView.superview == self.rightPanel) {
    // PDF内容最大宽度（留给检查器至少100px）
    return splitView.frame.size.width - 100;
  }
  return proposedMax;
}

@end

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

    // ========== [AP-FORM-IMAGE-REPLACEMENT] 初始化图片替换回调 ==========
    // 使用 CustomImageCallback 替代原来的 WatermarkCallback
    // CustomImageCallback 继承自 WatermarkCallback，支持图片替换和水印
    static CustomImageCallback* g_image_callback = new CustomImageCallback();
    // 默认模式：不替换图片，也不启用水印
    g_image_callback->SetReplacementMode(CustomImageCallback::ReplacementMode::kNone);
    LOG_INFO("[AP-FORM-IMAGE-REPLACEMENT] CustomImageCallback created (replacement disabled by default)");
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
      LOG_TAG_NS("PdfWinViewer",
                 "检测到已有实例运行（PID: %d），激活现有窗口并退出",
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
    // 将图片替换回调实例传递给 AppDelegate
    // CustomImageCallback 继承自 WatermarkCallback，可以同时处理水印和替换
    del.watermarkCallback = g_image_callback;  // 保留原有的水印callback属性
    del.imageCallback = g_image_callback;      // 新增的图片替换callback属性
    del.imageReplacementEnabled = NO;          // 初始状态：未启用替换
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
