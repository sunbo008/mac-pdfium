#import "StatusBarController.h"
#import "../Views/PdfView.h"
#import "platform/mac/Utils/LogManager.h"
#include "public/fpdf_doc.h"

// 前向声明AppDelegate，避免循环依赖
@interface AppDelegate : NSObject
@property(nonatomic, strong) PdfView* view;
@end

@implementation StatusBarController

- (void)createStatusBar {
  LOG_TAG_NS("StatusBar", "开始创建状态栏");
  // 创建状态栏容器
  self.statusBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 30)];
  self.statusBar.wantsLayer = YES;
  // 使用macOS原生的窗口背景色
  self.statusBar.layer.backgroundColor =
      [[NSColor windowBackgroundColor] CGColor];
  // 添加顶部分隔线
  self.statusBar.layer.borderWidth = 0.5;
  self.statusBar.layer.borderColor = [[NSColor separatorColor] CGColor];
  LOG_TAG_NS("StatusBar", "状态栏容器创建完成，frame: %@",
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

  // 缩小按钮（-）
  self.zoomOutButton = [NSButton buttonWithTitle:@"-"
                                          target:self
                                          action:@selector(onZoomOut:)];
  self.zoomOutButton.frame = NSMakeRect(330, 4, 30, 22);
  self.zoomOutButton.font = [NSFont systemFontOfSize:14];
  self.zoomOutButton.bezelStyle = NSBezelStyleRounded;
  self.zoomOutButton.alignment = NSTextAlignmentCenter;
  // 设置按钮内容居中对齐
  if (@available(macOS 11.0, *)) {
    self.zoomOutButton.contentTintColor = nil;
  }
  // 调整按钮的图像位置，确保文本居中
  self.zoomOutButton.imagePosition = NSNoImage;
  // 使用 attributed string 确保文本完全居中
  NSMutableParagraphStyle *styleOut = [[NSMutableParagraphStyle alloc] init];
  styleOut.alignment = NSTextAlignmentCenter;
  NSDictionary *attributesOut = @{
    NSFontAttributeName: [NSFont systemFontOfSize:14],
    NSParagraphStyleAttributeName: styleOut
  };
  self.zoomOutButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"-" attributes:attributesOut];
  [self.statusBar addSubview:self.zoomOutButton];

  // 缩放输入框
  self.zoomInput = [[NSTextField alloc] initWithFrame:NSMakeRect(365, 6, 60, 18)];
  self.zoomInput.stringValue = @"100%";
  self.zoomInput.font = [NSFont systemFontOfSize:12];
  self.zoomInput.alignment = NSTextAlignmentCenter;
  self.zoomInput.target = self;
  self.zoomInput.action = @selector(onZoomInputChanged:);
  [self.statusBar addSubview:self.zoomInput];

  // 放大按钮（+）
  self.zoomInButton = [NSButton buttonWithTitle:@"+"
                                         target:self
                                         action:@selector(onZoomIn:)];
  self.zoomInButton.frame = NSMakeRect(430, 4, 30, 22);
  self.zoomInButton.font = [NSFont systemFontOfSize:14];
  self.zoomInButton.bezelStyle = NSBezelStyleRounded;
  self.zoomInButton.alignment = NSTextAlignmentCenter;
  // 设置按钮内容居中对齐
  if (@available(macOS 11.0, *)) {
    self.zoomInButton.contentTintColor = nil;
  }
  // 调整按钮的图像位置，确保文本居中
  self.zoomInButton.imagePosition = NSNoImage;
  // 使用 attributed string 确保文本完全居中
  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.alignment = NSTextAlignmentCenter;
  NSDictionary *attributes = @{
    NSFontAttributeName: [NSFont systemFontOfSize:14],
    NSParagraphStyleAttributeName: style
  };
  self.zoomInButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"+" attributes:attributes];
  [self.statusBar addSubview:self.zoomInButton];

  // 水印切换按钮（放在最右边）
  self.watermarkToggleButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(520, 5, 80, 20)];
  self.watermarkToggleButton.bezelStyle = NSBezelStyleRounded;
  self.watermarkToggleButton.title = @"启用水印";
  self.watermarkToggleButton.font = [NSFont systemFontOfSize:11];
  self.watermarkToggleButton.target = self;
  self.watermarkToggleButton.action = @selector(onWatermarkToggle:);
  self.watermarkToggleButton.autoresizingMask = NSViewMinXMargin;  // 靠右边距固定
  [self.statusBar addSubview:self.watermarkToggleButton];

  LOG_TAG_NS("StatusBar", "状态栏创建完成，所有子视图已添加");
}

- (void)updateStatusBar {
  LOG_TAG_NS("StatusBar", "updateStatusBar被调用");

  @try {
    LOG_TAG_NS("StatusBar", "检查self.appDelegate.view...");
    if (!self.appDelegate.view) {
      LOG_TAG_NS("StatusBar", "self.appDelegate.view为nil");
      return;
    }
    LOG_TAG_NS("StatusBar", "self.appDelegate.view: %@", self.appDelegate.view);

    LOG_TAG_NS("StatusBar", "检查document...");
    FPDF_DOCUMENT doc = [self.appDelegate.view document];
    LOG_TAG_NS("StatusBar", "document: %p", doc);

    LOG_TAG_NS("StatusBar", "检查状态栏组件...");
    LOG_TAG_NS("StatusBar", "statusBar: %@", self.statusBar);
    LOG_TAG_NS("StatusBar", "pageInput: %@", self.pageInput);
    LOG_TAG_NS("StatusBar", "totalPagesLabel: %@", self.totalPagesLabel);
    LOG_TAG_NS("StatusBar", "prevPageButton: %@", self.prevPageButton);
    LOG_TAG_NS("StatusBar", "nextPageButton: %@", self.nextPageButton);

    // 检查状态栏组件是否已初始化
    if (!self.statusBar || !self.pageInput || !self.totalPagesLabel ||
        !self.prevPageButton || !self.nextPageButton) {
      LOG_TAG_NS("StatusBar", "状态栏组件未初始化，跳过更新");
      return;
    }

    if (!doc) {
      LOG_TAG_NS("StatusBar", "没有文档，设置默认值");
      self.pageInput.stringValue = @"1";
      self.totalPagesLabel.stringValue = @"/ 0";
      self.prevPageButton.enabled = NO;
      self.nextPageButton.enabled = NO;
      return;
    }

    LOG_TAG_NS("StatusBar", "获取页面信息...");
    int currentPage = [self.appDelegate.view currentPageIndex] + 1;  // 显示从1开始的页码
    int totalPages = FPDF_GetPageCount(doc);

    LOG_TAG_NS("StatusBar", "当前页: %d, 总页数: %d", currentPage, totalPages);

    LOG_TAG_NS("StatusBar", "更新UI组件...");
    self.pageInput.stringValue = [NSString stringWithFormat:@"%d", currentPage];
    self.totalPagesLabel.stringValue =
        [NSString stringWithFormat:@"/ %d", totalPages];

    self.prevPageButton.enabled = (currentPage > 1);
    self.nextPageButton.enabled = (currentPage < totalPages);

    // 更新缩放显示
    double currentZoom = [self.appDelegate.view zoom];
    int zoomPercent = (int)round(currentZoom * 100);
    self.zoomInput.stringValue = [NSString stringWithFormat:@"%d%%", zoomPercent];

    LOG_TAG_NS("StatusBar", "状态栏更新完成: %@ %@, 缩放: %d%%", 
          self.pageInput.stringValue,
          self.totalPagesLabel.stringValue,
          zoomPercent);
  } @catch (NSException* exception) {
    LOG_TAG_NS("StatusBar", "异常: %@", exception);
  }
}

- (void)onPrevPage:(id)sender {
  if (!self.appDelegate.view || ![self.appDelegate.view document]) {
    return;
  }
  int currentPage = [self.appDelegate.view currentPageIndex];
  if (currentPage > 0) {
    [self.appDelegate.view goToPage:currentPage - 1];
    [self updateStatusBar];
  }
}

- (void)onNextPage:(id)sender {
  if (!self.appDelegate.view || ![self.appDelegate.view document]) {
    return;
  }
  int totalPages = FPDF_GetPageCount([self.appDelegate.view document]);
  int currentPage = [self.appDelegate.view currentPageIndex];
  if (currentPage < totalPages - 1) {
    [self.appDelegate.view goToPage:currentPage + 1];
    [self updateStatusBar];
  }
}

- (void)onPageInputChanged:(id)sender {
  if (!self.appDelegate.view || ![self.appDelegate.view document]) {
    return;
  }

  NSString* input = self.pageInput.stringValue;
  int pageNum = [input intValue];
  int totalPages = FPDF_GetPageCount([self.appDelegate.view document]);

  // 边界检查：确保页码在有效范围内
  int validPageNum = pageNum;
  if (pageNum < 1) {
    validPageNum = 1;  // 小于最小值时使用最小值
    LOG_TAG_NS("PageNavigation", "状态栏输入页码%d小于1，调整为最小值: %d", pageNum,
          validPageNum);
  } else if (pageNum > totalPages) {
    validPageNum = totalPages;  // 大于最大值时使用最大值
    LOG_TAG_NS("PageNavigation", "状态栏输入页码%d超过最大值%d，调整为最大值: %d",
          pageNum, totalPages, validPageNum);
  }

  // 应用有效的页码
  [self.appDelegate.view goToPage:validPageNum - 1];  // 转换为0开始的索引
  LOG_TAG_NS("PageNavigation", "状态栏页码设置为: %d (索引: %d)", validPageNum,
        validPageNum - 1);
  [self updateStatusBar];
}

#pragma mark - 缩放控制方法

- (void)onZoomOut:(id)sender {
  if (!self.appDelegate.view) {
    return;
  }
  double currentZoom = [self.appDelegate.view zoom];
  double newZoom = currentZoom / 1.1;  // 缩小约 10%
  [self.appDelegate.view setZoom:newZoom];
  [self updateStatusBar];
  LOG_TAG_NS("StatusBar", "缩小: %.0f%% -> %.0f%%", currentZoom * 100, newZoom * 100);
}

- (void)onZoomIn:(id)sender {
  if (!self.appDelegate.view) {
    return;
  }
  double currentZoom = [self.appDelegate.view zoom];
  double newZoom = currentZoom * 1.1;  // 放大约 10%
  [self.appDelegate.view setZoom:newZoom];
  [self updateStatusBar];
  LOG_TAG_NS("StatusBar", "放大: %.0f%% -> %.0f%%", currentZoom * 100, newZoom * 100);
}

- (void)onZoomInputChanged:(id)sender {
  if (!self.appDelegate.view) {
    return;
  }
  
  NSString* input = self.zoomInput.stringValue;
  // 移除可能存在的 % 符号
  NSString* cleanInput = [input stringByReplacingOccurrencesOfString:@"%" withString:@""];
  double zoomPercent = [cleanInput doubleValue];
  
  // 将百分比转换为缩放比例（100% = 1.0）
  double zoom = zoomPercent / 100.0;
  
  // 边界检查：确保缩放在有效范围内 (10% 到 800%)
  if (zoom < 0.1) {
    zoom = 0.1;
    LOG_TAG_NS("StatusBar", "缩放输入 %.0f%% 小于最小值，调整为 10%%", zoomPercent);
  } else if (zoom > 8.0) {
    zoom = 8.0;
    LOG_TAG_NS("StatusBar", "缩放输入 %.0f%% 超过最大值，调整为 800%%", zoomPercent);
  }
  
  [self.appDelegate.view setZoom:zoom];
  LOG_TAG_NS("StatusBar", "状态栏缩放设置为: %.0f%%", zoom * 100);
  [self updateStatusBar];
}

- (void)onWatermarkToggle:(id)sender {
  // 调用 AppDelegate 的水印切换方法
  if ([self.appDelegate respondsToSelector:@selector(toggleWatermark:)]) {
    [self.appDelegate performSelector:@selector(toggleWatermark:) withObject:sender];
  }
}

@end

