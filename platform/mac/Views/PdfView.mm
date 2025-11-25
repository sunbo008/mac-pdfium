//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "PdfView.h"
#include <chrono>
#include <vector>
#import "../Utils/LogManager.h"
#import "LoadingView.h"
#include "fpdfsdk/cpdfsdk_renderpage.h"
#include "platform/shared/logger.h"
#include "platform/shared/pdf_utils.h"
#include "platform/shared/pdfium_object_info.h"
#include "public/fpdf_edit.h"
#include "public/fpdf_text.h"

// 辅助函数实现
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

@implementation PdfView {
  FPDF_DOCUMENT _doc;
  int _pageIndex;
  double _zoom;
  CGFloat _horizontalInset;
  NSView* _observedClipView;
  // 选择与交互
  bool _selecting;
  NSPoint _selStart;
  NSPoint _selEnd;
  NSPoint _lastContextPt;  // 最近一次右键菜单触发位置（视图坐标）
  BOOL _lastContextHitImage;  // 最近一次右键是否命中图片

  // 异步加载相关
  BOOL _isLoading;                 // 是否正在加载
  BOOL _shouldCancelLoading;       // 是否应该取消加载
  LoadingView* _loadingView;       // 加载视图
  NSString* _loadingPath;          // 正在加载的文件路径
  NSString* _currentPath;          // 当前打开的文件路径
  dispatch_queue_t _loadingQueue;  // 加载队列
}

- (NSString*)currentPath {
  return _currentPath;
}
- (NSPoint)toPagePxFromView:(NSPoint)viewPt {
  // Convert view coordinates to page coordinates (in points)
  // This should match the coordinate system used in rendering
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);

  // Convert view pixels to page points
  // The view shows the page at _zoom scale
  double adjX = viewPt.x - _horizontalInset;
  if (adjX < 0) {
    adjX = 0;
  }
  double px = adjX / _zoom;
  double py = viewPt.y / _zoom;

  // Note: PdfHitImageAt will handle the Y-axis flip from top-left to
  // bottom-left
  return NSMakePoint(px, py);
}

- (NSPoint)toViewFromPagePx:(NSPoint)pagePt {
  // Convert page coordinates back to view coordinates for debugging
  double vx = pagePt.x * _zoom + _horizontalInset;
  double vy = pagePt.y * _zoom;
  return NSMakePoint(vx, vy);
}

- (FPDF_DOCUMENT)document {
  return _doc;
}
- (int)currentPageIndex {
  return _pageIndex;
}
- (double)zoom {
  return _zoom;
}
- (void)setZoom:(double)zoom {
  // 限制缩放范围在 0.1 到 8.0 之间
  _zoom = std::max(0.1, std::min(8.0, zoom));
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
  // 通知 delegate 缩放已改变（如果需要更新状态栏）
  if ([self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
    [self.delegate pdfViewDidChangePage:self];
  }
}
- (void)goToPage:(int)index {
  if (!_doc) {
    return;
  }
  int pc = FPDF_GetPageCount(_doc);
  if (pc > 0) {
    if (index < 0) {
      index = 0;
    }
    if (index >= pc) {
      index = pc - 1;
    }
    int oldIndex = _pageIndex;
    _pageIndex = index;
    [self updateViewSizeToFitPage];
    [self setNeedsDisplay:YES];
    // 如果页面真的发生了变化，通知delegate
    if (oldIndex != _pageIndex &&
        [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
      [self.delegate pdfViewDidChangePage:self];
    }
  }
}

- (instancetype)initWithFrame:(NSRect)frame {
  if (self = [super initWithFrame:frame]) {
    _doc = nullptr;
    _pageIndex = 0;
    _zoom = 1.0;
    _horizontalInset = 0.0;
    _observedClipView = nil;
    _selecting = false;
    _isLoading = NO;
    _shouldCancelLoading = NO;
    _loadingQueue = dispatch_queue_create("com.pdfwinviewer.loading",
                                          DISPATCH_QUEUE_SERIAL);
    // [FIX-COLOR-MISMATCH] 初始化默认背景色为系统窗口背景色
    _backgroundColor = [NSColor windowBackgroundColor];
    [self.window setAcceptsMouseMovedEvents:YES];
  }
  return self;
}

// [FIX-COLOR-MISMATCH] 设置背景颜色并触发重绘，用于外部控制器统一颜色风格
- (void)setBackgroundColor:(NSColor*)backgroundColor {
  _backgroundColor = backgroundColor;
  [self setNeedsDisplay:YES];
}

- (void)dealloc {
  [self stopObservingClipView];
}

- (void)viewWillMoveToSuperview:(NSView*)newSuperview {
  [self stopObservingClipView];
  [super viewWillMoveToSuperview:newSuperview];
}

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];
  [self startObservingClipView];
  [self updateViewSizeToFitPage];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self startObservingClipView];
  [self updateViewSizeToFitPage];
}

- (void)startObservingClipView {
  NSScrollView* scrollView = self.enclosingScrollView;
  if (!scrollView) {
    return;
  }
  NSView* clipView = scrollView.contentView;
  if (_observedClipView == clipView) {
    return;
  }

  [self stopObservingClipView];

  _observedClipView = clipView;
  [_observedClipView setPostsFrameChangedNotifications:YES];
  [_observedClipView setPostsBoundsChangedNotifications:YES];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(clipViewGeometryDidChange:)
             name:NSViewFrameDidChangeNotification
           object:_observedClipView];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(clipViewGeometryDidChange:)
             name:NSViewBoundsDidChangeNotification
           object:_observedClipView];
}

- (void)stopObservingClipView {
  if (!_observedClipView) {
    return;
  }
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:NSViewFrameDidChangeNotification
              object:_observedClipView];
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:NSViewBoundsDidChangeNotification
              object:_observedClipView];
  _observedClipView = nil;
}

- (void)clipViewGeometryDidChange:(NSNotification*)notification {
  (void)notification;
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
}

- (CGFloat)currentHorizontalInsetForDestWidth:(double)destWidth {
  CGFloat width = NSWidth(self.visibleRect);
  if (width <= 0 && self.enclosingScrollView) {
    width = NSWidth(self.enclosingScrollView.contentView.bounds);
  }
  if (width <= 0 && self.superview) {
    width = NSWidth(self.superview.bounds);
  }
  if (width <= destWidth || width <= 0) {
    return 0.0f;
  }
  double scale = self.window ? self.window.backingScaleFactor : 1.0;
  if (scale <= 0.0) {
    scale = 1.0;
  }
  double inset = (width - destWidth) / 2.0;
  inset = llround(inset * scale) / scale;
  return (CGFloat)inset;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)openPDFAtPath:(NSString*)path {
  // 默认行为：根据文件大小自动决定是否显示加载视图
  NSDictionary* attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  unsigned long long fileSize = attrs ? [attrs fileSize] : 0;
  BOOL showLoading = (fileSize >= 5 * 1024 * 1024);  // 5MB 以上显示
  return [self openPDFAtPath:path showLoadingView:showLoading];
}

- (BOOL)openPDFAtPath:(NSString*)path showLoadingView:(BOOL)showLoading {
  if (_isLoading) {
    LOG_WARNING("已有文档正在加载中，忽略新的加载请求");
    return NO;
  }

  LOG_TAG_NS("PdfWinViewer", "openPDFAtPath (async): %@", path);
  LOG_INFO_F("========================================");
  LOG_INFO_F("正在打开 PDF 文件：%s", [path UTF8String]);
  LOG_DEBUG_F("文件完整路径：%s", [path UTF8String]);
  LOG_DEBUG_F("文件名：%s", [[path lastPathComponent] UTF8String]);

  // 关闭之前的文档
  if (_doc) {
    LOG_DEBUG("关闭之前打开的文档");
    FPDF_CloseDocument(_doc);
    _doc = nullptr;
    _pageIndex = 0;
    _zoom = 1.0;
  }

  // 设置加载状态
  _isLoading = YES;
  _shouldCancelLoading = NO;
  _loadingPath = [path copy];

  // 显示加载视图
  if (showLoading) {
    if (!_loadingView) {
      _loadingView = [[LoadingView alloc] initWithFrame:self.bounds];
      _loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      __weak PdfView* weakSelf = self;
      _loadingView.onCancel = ^{
        [weakSelf cancelLoading];
      };
    }
    _loadingView.frame = self.bounds;
    [self addSubview:_loadingView];
    [_loadingView show];
  }

  // 异步加载文档
  NSString* pathCopy = [path copy];
  dispatch_async(_loadingQueue, ^{
    [self loadDocumentInBackground:pathCopy showLoading:showLoading];
  });

  return YES;
}

- (void)loadDocumentInBackground:(NSString*)path showLoading:(BOOL)showLoading {
  auto startTime = std::chrono::steady_clock::now();

  // 初始化PDFium库
  FPDF_LIBRARY_CONFIG cfg{};
  cfg.version = 3;
  FPDF_InitLibraryWithConfig(&cfg);

  LOG_DEBUG("调用 FPDF_LoadDocument（后台线程）");
  auto loadStartTime = std::chrono::steady_clock::now();

  std::string u8 = NSStringToUTF8(path);
  FPDF_DOCUMENT doc = FPDF_LoadDocument(u8.c_str(), nullptr);

  // 检查是否被取消
  if (_shouldCancelLoading) {
    LOG_INFO("文档加载已取消");
    if (doc) {
      FPDF_CloseDocument(doc);
    }
    [self finishLoadingWithDocument:nil
                               path:path
                          startTime:startTime
                      loadStartTime:loadStartTime
                        showLoading:showLoading
                          cancelled:YES];
    return;
  }

  auto loadEndTime = std::chrono::steady_clock::now();
  double loadTimeMs =
      std::chrono::duration<double, std::milli>(loadEndTime - loadStartTime)
          .count();

  if (!doc) {
    LOG_ERROR_F("打开 PDF 文件失败：%s", [path UTF8String]);
    LogFPDFLastError("FPDF_LoadDocument");
    [self finishLoadingWithDocument:nil
                               path:path
                          startTime:startTime
                      loadStartTime:loadStartTime
                        showLoading:showLoading
                          cancelled:NO];
    return;
  }

  int pageCount = FPDF_GetPageCount(doc);
  auto endTime = std::chrono::steady_clock::now();
  double totalTimeMs =
      std::chrono::duration<double, std::milli>(endTime - startTime).count();

  LOG_INFO_F("PDF 文件打开成功，共 %d 页", pageCount);
  LOG_INFO_F("⏱️  文档加载耗时：%.2f ms（FPDF_LoadDocument: %.2f ms）",
             totalTimeMs, loadTimeMs);
  LOG_TAG_NS("PdfWinViewer", "document loaded. pageCount=%d", pageCount);

  // 回到主线程更新UI
  dispatch_async(dispatch_get_main_queue(), ^{
    if (_shouldCancelLoading) {
      LOG_INFO("文档加载完成但已被取消");
      FPDF_CloseDocument(doc);
      [self finishLoadingWithDocument:nil
                                 path:path
                            startTime:startTime
                        loadStartTime:loadStartTime
                          showLoading:showLoading
                            cancelled:YES];
      return;
    }

    _doc = doc;
    _pageIndex = 0;
    _zoom = 1.0;
    _currentPath = [path copy];  // 保存当前文件路径

#if PDFWV_ENABLE_LOGGING
    _openStartSec = NowSeconds();
    _firstRenderAfterOpen = true;
    _lastMemMB = GetProcessMemMB();
#endif

    [self finishLoadingWithDocument:doc
                               path:path
                          startTime:startTime
                      loadStartTime:loadStartTime
                        showLoading:showLoading
                          cancelled:NO];
  });
}

- (void)finishLoadingWithDocument:(FPDF_DOCUMENT)doc
                             path:(NSString*)path
                        startTime:
                            (std::chrono::steady_clock::time_point)startTime
                    loadStartTime:
                        (std::chrono::steady_clock::time_point)loadStartTime
                      showLoading:(BOOL)showLoading
                        cancelled:(BOOL)cancelled {
  // 隐藏加载视图
  if (showLoading && _loadingView) {
    [_loadingView hide];
    [_loadingView removeFromSuperview];
  }

  _isLoading = NO;
  _shouldCancelLoading = NO;
  _loadingPath = nil;

  // 通知delegate
  if ([self.delegate respondsToSelector:@selector(pdfView:
                                            didFinishLoadingDocument:error:)]) {
    NSError* error = nil;
    if (!doc && !cancelled) {
      error = [NSError
          errorWithDomain:@"PdfViewErrorDomain"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"无法加载PDF文档"}];
    } else if (cancelled) {
      error = [NSError
          errorWithDomain:@"PdfViewErrorDomain"
                     code:2
                 userInfo:@{NSLocalizedDescriptionKey : @"用户取消加载"}];
    }
    [self.delegate pdfView:self
        didFinishLoadingDocument:(doc != nullptr)
                           error:error];
  }
}

- (void)cancelLoading {
  if (!_isLoading) {
    return;
  }
  LOG_INFO("用户请求取消加载");
  _shouldCancelLoading = YES;
}

- (NSSize)currentPageSizePt {
  if (!_doc) {
    return NSMakeSize(0, 0);
  }
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  return NSMakeSize((CGFloat)wpt, (CGFloat)hpt);
}

- (void)updateViewSizeToFitPage {
  NSSize s = [self currentPageSizePt];
  if (s.width <= 0 || s.height <= 0) {
    _horizontalInset = 0.0;
    return;
  }
  double destWidth = s.width * _zoom;
  double destHeight = s.height * _zoom;

  CGFloat visibleWidth = NSWidth(self.visibleRect);
  if (visibleWidth <= 0 && self.enclosingScrollView) {
    visibleWidth = NSWidth(self.enclosingScrollView.contentView.bounds);
  }
  if (visibleWidth <= 0 && self.superview) {
    visibleWidth = NSWidth(self.superview.bounds);
  }

  double newWidth = destWidth;
  if (visibleWidth > 0) {
    newWidth = std::max(destWidth, static_cast<double>(visibleWidth));
  }

  [self setFrameSize:NSMakeSize((CGFloat)newWidth, (CGFloat)destHeight)];

  _horizontalInset = [self currentHorizontalInsetForDestWidth:destWidth];
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize {
  [super resizeWithOldSuperviewSize:oldSize];
  [self updateViewSizeToFitPage];
}

- (void)keyDown:(NSEvent*)event {
  NSString* chars = [event charactersIgnoringModifiers];
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;

  // ESC 键取消加载
  if (c == 0x1B) {  // ESC key
    if (_isLoading) {
      [self cancelLoading];
      return;
    }
  }

  if (!_doc) {
    return;
  }

  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if ((mods & NSEventModifierFlagCommand) != 0) {
    // Cmd-based shortcuts
    if (c == '=') {
      _zoom = std::min(8.0, _zoom * 1.1);
      [self updateViewSizeToFitPage];
      [self setNeedsDisplay:YES];
      return;
    }
    if (c == '-') {
      _zoom = std::max(0.1, _zoom / 1.1);
      [self updateViewSizeToFitPage];
      [self setNeedsDisplay:YES];
      return;
    }
    if (c == '0') {
      _zoom = 1.0;
      [self updateViewSizeToFitPage];
      [self setNeedsDisplay:YES];
      return;
    }
    if (c == 'g' || c == 'G') {
      [self promptGotoPage];
      return;
    }
    if (c == 'e' || c == 'E') {
      [self exportCurrentPagePNG];
      return;
    }
    if (c == 'c' || c == 'C') {
      [self copySelectionToPasteboard];
      return;
    }
  }
  int oldIndex = _pageIndex;
  switch (c) {
    case NSHomeFunctionKey:
      _pageIndex = 0;
      break;
    case NSEndFunctionKey: {
      int pc = FPDF_GetPageCount(_doc);
      if (pc > 0) {
        _pageIndex = pc - 1;
      }
      break;
    }
    case NSPageUpFunctionKey:
      _pageIndex = (_pageIndex > 0) ? _pageIndex - 1 : 0;
      break;
    case NSPageDownFunctionKey: {
      int pc = FPDF_GetPageCount(_doc);
      if (pc > 0 && _pageIndex < pc - 1) {
        _pageIndex++;
      }
      break;
    }
    default:
      break;
  }
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
  // 如果页面发生了变化，通知delegate
  if (oldIndex != _pageIndex &&
      [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
    [self.delegate pdfViewDidChangePage:self];
  }
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

#pragma mark - First responder actions (Menu targets)

- (IBAction)copy:(id)sender {
  [self copySelectionToPasteboard];
}
- (IBAction)zoomIn:(id)sender {
  _zoom = std::min(8.0, _zoom * 1.1);
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
}
- (IBAction)zoomOut:(id)sender {
  _zoom = std::max(0.1, _zoom / 1.1);
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
}
- (IBAction)zoomActual:(id)sender {
  _zoom = 1.0;
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
}
- (IBAction)goHome:(id)sender {
  if (_doc) {
    int oldIndex = _pageIndex;
    _pageIndex = 0;
    [self updateViewSizeToFitPage];
    [self setNeedsDisplay:YES];
    if (oldIndex != _pageIndex &&
        [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
      [self.delegate pdfViewDidChangePage:self];
    }
  }
}
- (IBAction)goEnd:(id)sender {
  if (_doc) {
    int pc = FPDF_GetPageCount(_doc);
    if (pc > 0) {
      int oldIndex = _pageIndex;
      _pageIndex = pc - 1;
      [self updateViewSizeToFitPage];
      [self setNeedsDisplay:YES];
      if (oldIndex != _pageIndex &&
          [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
        [self.delegate pdfViewDidChangePage:self];
      }
    }
  }
}
- (IBAction)goPrevPage:(id)sender {
  if (_doc) {
    if (_pageIndex > 0) {
      int oldIndex = _pageIndex;
      _pageIndex--;
      [self updateViewSizeToFitPage];
      [self setNeedsDisplay:YES];
      if (oldIndex != _pageIndex &&
          [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
        [self.delegate pdfViewDidChangePage:self];
      }
    }
  }
}
- (IBAction)goNextPage:(id)sender {
  if (_doc) {
    int pc = FPDF_GetPageCount(_doc);
    if (pc > 0 && _pageIndex < pc - 1) {
      int oldIndex = _pageIndex;
      _pageIndex++;
      [self updateViewSizeToFitPage];
      [self setNeedsDisplay:YES];
      if (oldIndex != _pageIndex &&
          [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
        [self.delegate pdfViewDidChangePage:self];
      }
    }
  }
}
- (IBAction)gotoPage:(id)sender {
  [self promptGotoPage];
}
- (IBAction)exportPNG:(id)sender {
  [self exportCurrentPagePNG];
}

- (void)magnifyWithEvent:(NSEvent*)event {
  // 触控板捏合缩放
  _zoom = std::max(0.1, std::min(8.0, _zoom * (1.0 + event.magnification)));
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  MacLog_DebugNS([NSString
      stringWithFormat:@"[PdfView] drawRect called, dirtyRect: %@, bounds: %@",
                       NSStringFromRect(dirtyRect),
                       NSStringFromRect(self.bounds)]);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[PdfView] _doc = %p, _pageIndex = %d", _doc,
                                 _pageIndex]);

  [super drawRect:dirtyRect];
  // [FIX-COLOR-MISMATCH] 优先使用自定义背景色填充，确保与滚动容器颜色一致
  if (self.backgroundColor) {
    [self.backgroundColor setFill];
    NSRectFill(self.bounds);
  }
  if (!_doc) {
    MacLog_DebugNS(@"[PdfView] drawRect: _doc is NULL, returning");
    return;
  }
  int pageCount = FPDF_GetPageCount(_doc);
  if (pageCount <= 0) {
    return;
  }
  if (_pageIndex < 0) {
    _pageIndex = 0;
  }
  if (_pageIndex >= pageCount) {
    _pageIndex = pageCount - 1;
  }

  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    LogFPDFLastError("FPDF_LoadPage");
    return;
  }
#if PDFWV_ENABLE_LOGGING
  bool _logActive = MacLog_IsEnabled();
  double t0 = _logActive ? NowSeconds() : 0.0;
#endif
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  // 使用 Retina 比例计算像素，确保 1:1 像素映射，避免缩放导致的模糊
  double scale = [[self window] backingScaleFactor] ?: 1.0;
  int pxW = std::max(1, (int)llround(wpt * _zoom * scale));
  int pxH = std::max(1, (int)llround(hpt * _zoom * scale));

  std::vector<unsigned char> buffer((size_t)pxW * pxH * 4, 255);
  FPDF_BITMAP bmp =
      FPDFBitmap_CreateEx(pxW, pxH, FPDFBitmap_BGRA, buffer.data(), pxW * 4);
  if (bmp) {
    FPDFBitmap_FillRect(bmp, 0, 0, pxW, pxH, 0xFFFFFFFF);
    int flags = FPDF_ANNOT | FPDF_LCD_TEXT;
    FPDF_RenderPageBitmap(bmp, page, 0, 0, pxW, pxH, 0, flags);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(
        NULL, buffer.data(), (size_t)buffer.size(), NULL);
    CGBitmapInfo bi =
        (CGBitmapInfo)((uint32_t)kCGBitmapByteOrder32Little |
                       (uint32_t)kCGImageAlphaPremultipliedFirst);  // BGRA
    CGImageRef img = CGImageCreate(pxW, pxH, 8, 32, pxW * 4, cs, bi, dp, NULL,
                                   false, kCGRenderingIntentDefault);
    // 以点（pt）为单位的目标绘制尺寸，并对齐到像素边界
    double destWpt = wpt * _zoom;
    double destHpt = hpt * _zoom;
    destWpt = llround(destWpt * scale) / scale;
    destHpt = llround(destHpt * scale) / scale;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    // 插值关闭，保证位图锐利
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    // 视图是 flipped（y 向下），需对图片做一次上下翻转
    _horizontalInset = [self currentHorizontalInsetForDestWidth:destWpt];
    CGContextTranslateCTM(ctx, _horizontalInset, destHpt);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    // 绘制统一的白色背景（随缩放变化），避免缩放后背景与内容不同步
    CGContextSetFillColorWithColor(ctx, [NSColor whiteColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, destWpt, destHpt));
    CGContextDrawImage(ctx, CGRectMake(0, 0, destWpt, destHpt), img);
    CGContextRestoreGState(ctx);
    NSRect pageRect =
        NSMakeRect(_horizontalInset, 0.0, (CGFloat)destWpt, (CGFloat)destHpt);
    [[NSColor separatorColor] setStroke];
    NSFrameRectWithWidth(pageRect, 1.0);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);

    FPDFBitmap_Destroy(bmp);
  }
  // 绘制选择框
  if (_selecting || !NSEqualPoints(_selStart, _selEnd)) {
    NSRect sel = NSMakeRect(
        std::min(_selStart.x, _selEnd.x), std::min(_selStart.y, _selEnd.y),
        fabs(_selStart.x - _selEnd.x), fabs(_selStart.y - _selEnd.y));
    [[NSColor colorWithCalibratedRed:0 green:0.4 blue:1 alpha:0.2] setFill];
    NSRectFillUsingOperation(sel, NSCompositingOperationSourceOver);
    [[NSColor colorWithCalibratedRed:0 green:0.4 blue:1 alpha:0.8] setStroke];
    NSFrameRectWithWidth(sel, 1.0);
  }
  FPDF_ClosePage(page);
#if PDFWV_ENABLE_LOGGING
  if (_logActive) {
    double t1 = NowSeconds();
    double ms = (t1 - t0) * 1000.0;
    double curMB = GetProcessMemMB();
    double dMB = curMB - _lastMemMB;
    _lastMemMB = curMB;
    if (_firstRenderAfterOpen) {
      double openMs = (t1 - _openStartSec) * 1000.0;
      LOG_INFO_F("🎨 首次渲染完成 - 页面 %d，缩放 %.0f%%，耗时 %.2f "
                 "ms（从打开到首次显示）",
                 _pageIndex + 1, _zoom * 100.0, openMs);
      Log_WritePerfEx(_pageIndex + 1, _zoom * 100.0, openMs, curMB, dMB,
                      L"打开PDF→首次渲染", __FILE__, __LINE__, __FUNCTION__);
      _firstRenderAfterOpen = false;
    } else {
      // 只在耗时较长时记录，避免日志过多
      if (ms > 30.0) {  // 超过 30ms 才记录
        LOG_DEBUG_F("🎨 页面渲染 - 页面 %d，缩放 %.0f%%，耗时 %.2f ms",
                    _pageIndex + 1, _zoom * 100.0, ms);
      }
      Log_WritePerf(_pageIndex + 1, _zoom * 100.0, ms, curMB, dMB);
    }
  }
#endif
}

#pragma mark - Mouse events for selection and link navigation

- (void)mouseDown:(NSEvent*)event {
  if (!_doc) {
    return;
  }
  _selecting = true;
  _selStart = [self convertPoint:event.locationInWindow fromView:nil];
  _selEnd = _selStart;
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent*)event {
  if (!_doc || !_selecting) {
    return;
  }
  _selEnd = [self convertPoint:event.locationInWindow fromView:nil];
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)event {
  if (!_doc) {
    return;
  }
  NSPoint up = [self convertPoint:event.locationInWindow fromView:nil];
  if (_selecting) {
    _selEnd = up;
    _selecting = false;
    [self setNeedsDisplay:YES];
  } else {
    // 非选择：尝试链接跳转
    [self tryNavigateLinkAtPoint:up];

    // 检测点击的PDF对象并通知检查器
    [self detectObjectAtPoint:up];
  }
}

- (void)rightMouseDown:(NSEvent*)event {
  if (!_doc) {
    MacLog_DebugNS(@"[context] blocked: no document");
    return;
  }
  // 记录菜单触发点
  _lastContextPt = [self convertPoint:event.locationInWindow fromView:nil];
  MacLog_DebugNS([NSString stringWithFormat:@"[context] raw viewPt=(%.1f,%.1f)",
                                            _lastContextPt.x,
                                            _lastContextPt.y]);
  // 判断命中图片
  NSPoint pt = _lastContextPt;
  NSPoint pageXY = [self toPagePxFromView:pt];
  double px = pageXY.x, py = pageXY.y;
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[context] pageXY=(%.1f,%.1f) pageIndex=%d",
                                 px, py, _pageIndex]);
  BOOL hitImage = NO;
  FPDF_PAGEOBJECT hitObj = nullptr;
  if (page) {
    // 先检查页面上有多少个图片对象
    int totalObjs = FPDFPage_CountObjects(page);
    int imageObjs = 0;
    for (int i = 0; i < totalObjs; i++) {
      FPDF_PAGEOBJECT obj = FPDFPage_GetObject(page, i);
      if (obj && FPDFPageObj_GetType(obj) == FPDF_PAGEOBJ_IMAGE) {
        imageObjs++;
      }
    }
    MacLog_DebugNS([NSString
        stringWithFormat:
            @"[context] page has %d objects, %d images, pageSize=%.1fx%.1f",
            totalObjs, imageObjs, wpt, hpt]);

    // 先手动检查前几个图片的边界框
    int debugCount = 0;
    for (int i = totalObjs - 1; i >= 0 && debugCount < 3; --i) {
      FPDF_PAGEOBJECT obj = FPDFPage_GetObject(page, i);
      if (obj && FPDFPageObj_GetType(obj) == FPDF_PAGEOBJ_IMAGE) {
        debugCount++;
        FS_QUADPOINTSF qp{};
        if (FPDFPageObj_GetRotatedBounds(obj, &qp)) {
          float minx = std::min(std::min(qp.x1, qp.x2), std::min(qp.x3, qp.x4));
          float maxx = std::max(std::max(qp.x1, qp.x2), std::max(qp.x3, qp.x4));
          float miny = std::min(std::min(qp.y1, qp.y2), std::min(qp.y3, qp.y4));
          float maxy = std::max(std::max(qp.y1, qp.y2), std::max(qp.y3, qp.y4));

          // 转换为视图坐标系显示（PDF坐标系原点在左下角，视图坐标系原点在左上角）
          NSPoint topLeft =
              [self toViewFromPagePx:NSMakePoint(minx, hpt - maxy)];
          NSPoint bottomRight =
              [self toViewFromPagePx:NSMakePoint(maxx, hpt - miny)];

          MacLog_DebugNS([NSString
              stringWithFormat:@"[context] coordinate check: hpt=%.1f, "
                               @"PDF_Y_range=%.1f-%.1f, VIEW_Y_range=%.1f-%.1f",
                               hpt, miny, maxy, topLeft.y, bottomRight.y]);

          MacLog_DebugNS([NSString
              stringWithFormat:
                  @"[context] image %d PDF bounds: (%.1f,%.1f)-(%.1f,%.1f)",
                  debugCount, minx, miny, maxx, maxy]);
          MacLog_DebugNS([NSString
              stringWithFormat:
                  @"[context] image %d VIEW bounds: (%.1f,%.1f)-(%.1f,%.1f)",
                  debugCount, topLeft.x, topLeft.y, bottomRight.x,
                  bottomRight.y]);
        }
      }
    }

    PdfHitImageResult r = PdfHitImageAt(page, px, py, hpt, 2.0f);
    hitObj = r.imageObj;
    hitImage = (hitObj != nullptr);

    if (hitImage) {
      unsigned int iw = 0, ih = 0;
      FPDFImageObj_GetImagePixelSize(hitObj, &iw, &ih);
      MacLog_DebugNS(
          [NSString stringWithFormat:@"[context] hit image pixel=%ux%u, "
                                     @"bounds=(%.1f,%.1f)-(%.1f,%.1f)",
                                     iw, ih, r.minx, r.miny, r.maxx, r.maxy]);
    } else {
      MacLog_DebugNS([NSString
          stringWithFormat:@"[context] no image hit at PDF coords (%.1f,%.1f)",
                           px, py]);
    }
    FPDF_ClosePage(page);
  }
  _lastContextHitImage = hitImage;
  NSString* ctxLine =
      [NSString stringWithFormat:@"[context] doc=%@ page=%d view=(%.1f,%.1f) "
                                 @"pageXY=(%.1f,%.1f) hitImage=%@",
                                 _doc ? @"YES" : @"NO", _pageIndex, pt.x, pt.y,
                                 px, py, hitImage ? @"YES" : @"NO"];
  LOG_TAG_NS("PdfWinViewer", "%@", ctxLine);
  MacLog_DebugNS(ctxLine);
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
  menu.autoenablesItems = NO;  // 禁用自动启用，手动控制菜单项状态
  [menu addItemWithTitle:@"复制选中文本"
                  action:@selector(copySelectionToPasteboard)
           keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* expPage = [menu addItemWithTitle:@"导出当前页 PNG"
                                        action:@selector(exportCurrentPagePNG)
                                 keyEquivalent:@""];
  expPage.target = self;
  expPage.enabled = (_doc != nullptr);
  NSMenuItem* saveImg = [menu addItemWithTitle:@"保存图片…"
                                        action:@selector(saveImageAtPoint:)
                                 keyEquivalent:@""];
  saveImg.target = self;
  saveImg.enabled = hitImage;
  MacLog_DebugNS([NSString stringWithFormat:@"[context] menu item enabled: %@",
                                            hitImage ? @"YES" : @"NO"]);
  [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)scrollWheel:(NSEvent*)event {
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if ((mods & NSEventModifierFlagCommand) != 0) {
    double delta = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas) {
      delta *= 0.1;
    }
    if (delta > 0) {
      _zoom = std::min(8.0, _zoom * 1.05);
    } else if (delta < 0) {
      _zoom = std::max(0.1, _zoom / 1.05);
    }
    [self updateViewSizeToFitPage];
    [self setNeedsDisplay:YES];
  } else {
    if (self.enclosingScrollView) {
      [self.enclosingScrollView scrollWheel:event];
    } else {
      [super scrollWheel:event];
    }
  }
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
  if (menuItem.action == @selector(copySelectionToPasteboard)) {
    return !NSEqualPoints(_selStart, _selEnd);
  }
  if (menuItem.action == @selector(copy:)) {
    return _doc && !NSEqualPoints(_selStart, _selEnd);
  }
  if (menuItem.action == @selector(exportPNG:)) {
    return _doc != nullptr;
  }
  return YES;
}

- (void)copySelectionToPasteboard {
  if (!_doc) {
    return;
  }
  NSString* text = [self extractSelectedText];
  if (text.length == 0) {
    return;
  }
  NSPasteboard* pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setString:text forType:NSPasteboardTypeString];
}

- (NSString*)extractSelectedText {
  if (!_doc || NSEqualPoints(_selStart, _selEnd)) {
    return @"";
  }
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    return @"";
  }
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  // 视图坐标 -> 页面像素坐标（与渲染一致）
  int dpi = 72 * (int)ceil([self.window backingScaleFactor] ?: 2.0);
  auto toPagePx = ^(NSPoint p) {
    double x = (p.x - _horizontalInset) * (dpi / 72.0) / _zoom;
    if (x < 0.0) {
      x = 0.0;
    }
    double yTopDown = p.y * (dpi / 72.0) / _zoom;
    double y = std::max(0.0, hpt - yTopDown);
    return NSMakePoint(x, y);
  };
  NSPoint a = toPagePx(_selStart), b = toPagePx(_selEnd);
  double left = std::min(a.x, b.x), right = std::max(a.x, b.x);
  double bottom = std::min(a.y, b.y), top = std::max(a.y, b.y);
  FPDF_TEXTPAGE tp = FPDFText_LoadPage(page);
  if (!tp) {
    FPDF_ClosePage(page);
    return @"";
  }
  int n = FPDFText_GetBoundedText(tp, left, top, right, bottom, nullptr, 0);
  if (n <= 0) {
    FPDFText_ClosePage(tp);
    FPDF_ClosePage(page);
    return @"";
  }
  std::vector<unsigned short> wbuf((size_t)n + 1, 0);
  FPDFText_GetBoundedText(tp, left, top, right, bottom,
                          (unsigned short*)wbuf.data(), n);
  FPDFText_ClosePage(tp);
  FPDF_ClosePage(page);
  NSString* s = [[NSString alloc] initWithCharacters:(unichar*)wbuf.data()
                                              length:(NSUInteger)n];
  return s ?: @"";
}

- (void)tryNavigateLinkAtPoint:(NSPoint)viewPt {
  if (!_doc) {
    return;
  }
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    return;
  }
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  int dpi = 72 * (int)ceil([self.window backingScaleFactor] ?: 2.0);
  double px = (viewPt.x - _horizontalInset) * (dpi / 72.0) / _zoom;
  if (px < 0.0) {
    px = 0.0;
  }
  double py = std::max(0.0, hpt - viewPt.y * (dpi / 72.0) / _zoom);
  FPDF_LINK link = FPDFLink_GetLinkAtPoint(page, px, py);
  if (link) {
    FPDF_DEST dest = FPDFLink_GetDest(_doc, link);
    if (!dest) {
      FPDF_ACTION act = FPDFLink_GetAction(link);
      if (act) {
        dest = FPDFAction_GetDest(_doc, act);
      }
    }
    if (dest) {
      int pageIndex = FPDFDest_GetDestPageIndex(_doc, dest);
      if (pageIndex >= 0) {
        _pageIndex = pageIndex;
        [self updateViewSizeToFitPage];
        [self setNeedsDisplay:YES];
      }
    }
  }
  FPDF_ClosePage(page);
}

- (void)promptGotoPage {
  if (!_doc) {
    return;
  }
  NSInteger pc = FPDF_GetPageCount(_doc);
  NSAlert* alert = [NSAlert new];
  alert.messageText = @"跳转到页";
  NSTextField* tf =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
  [tf setStringValue:[NSString stringWithFormat:@"%d", _pageIndex + 1]];
  alert.accessoryView = tf;
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSInteger v = tf.integerValue;

    // 边界检查：确保页码在有效范围内
    if (v < 1) {
      v = 1;  // 小于最小值时使用最小值
      LOG_TAG_NS("PageNavigation", "输入页码小于1，调整为最小值: %ld", (long)v);
    } else if (v > pc) {
      v = pc;  // 大于最大值时使用最大值
      LOG_TAG_NS("PageNavigation", "输入页码超过最大值%ld，调整为最大值: %ld",
                 (long)pc, (long)v);
    }

    int oldIndex = _pageIndex;
    _pageIndex = (int)v - 1;  // 转换为0基索引
    LOG_TAG_NS("PageNavigation", "设置页码为: %ld (索引: %d)", (long)v,
               _pageIndex);
    [self updateViewSizeToFitPage];
    [self setNeedsDisplay:YES];

    if (oldIndex != _pageIndex &&
        [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
      [self.delegate pdfViewDidChangePage:self];
    }
  }
}

- (BOOL)exportCurrentPagePNG {
  LOG_TAG_NS("PdfWinViewer", "[exportPage] doc=%@ page=%d",
             _doc ? @"YES" : @"NO", _pageIndex);
  if (!_doc) {
    return NO;
  }
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    return NO;
  }
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  int dpiX = 72 * (int)ceil([self.window backingScaleFactor] ?: 2.0);
  int dpiY = dpiX;
  double z = _zoom;
  int pxW = std::max(1, (int)llround(wpt / 72.0 * dpiX * z));
  int pxH = std::max(1, (int)llround(hpt / 72.0 * dpiY * z));
  std::vector<unsigned char> buffer((size_t)pxW * pxH * 4, 255);
  FPDF_BITMAP bmp =
      FPDFBitmap_CreateEx(pxW, pxH, FPDFBitmap_BGRA, buffer.data(), pxW * 4);
  if (!bmp) {
    FPDF_ClosePage(page);
    return NO;
  }
  FPDFBitmap_FillRect(bmp, 0, 0, pxW, pxH, 0xFFFFFFFF);
  FPDF_RenderPageBitmap(bmp, page, 0, 0, pxW, pxH, 0,
                        FPDF_ANNOT | FPDF_LCD_TEXT);

  NSSavePanel* sp = [NSSavePanel savePanel];
  [sp setNameFieldStringValue:[NSString stringWithFormat:@"page_%d.png",
                                                         _pageIndex + 1]];
  if ([sp runModal] != NSModalResponseOK) {
    FPDFBitmap_Destroy(bmp);
    FPDF_ClosePage(page);
    return NO;
  }
  NSURL* url = sp.URL;

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef dp = CGDataProviderCreateWithData(
      NULL, buffer.data(), (size_t)buffer.size(), NULL);
  CGBitmapInfo bi = kCGBitmapByteOrder32Little |
                    (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
  CGImageRef img = CGImageCreate(pxW, pxH, 8, 32, pxW * 4, cs, bi, dp, NULL,
                                 false, kCGRenderingIntentDefault);
  CFStringRef pngUti = (__bridge CFStringRef)UTTypePNG.identifier;
  CGImageDestinationRef dst =
      CGImageDestinationCreateWithURL((__bridge CFURLRef)url, pngUti, 1, NULL);
  if (dst && img) {
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
  }
  if (dst) {
    CFRelease(dst);
  }
  if (img) {
    CGImageRelease(img);
  }
  if (dp) {
    CGDataProviderRelease(dp);
  }
  if (cs) {
    CGColorSpaceRelease(cs);
  }
  FPDFBitmap_Destroy(bmp);
  FPDF_ClosePage(page);
  return YES;
}

- (IBAction)saveImageAtPoint:(id)sender {
  if (!_doc) {
    return;
  }
  if (!_lastContextHitImage) {
    MacLog_DebugNS(@"[saveImage] blocked: last context not on image");
    return;
  }
  NSPoint pt = _lastContextPt;  // 使用右键弹出时记录的位置
  NSPoint pageXY = [self toPagePxFromView:pt];
  double px = pageXY.x, py = pageXY.y;
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  LOG_TAG_NS("PdfWinViewer",
             "[saveImage] use pt=(%.1f,%.1f) => pageXY=(%.1f,%.1f) "
            @"pageWH=(%.1f,%.1f)",
             pt.x, pt.y, px, py, wpt, hpt);
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    return;
  }
  // 使用共享的 pdf_utils 模块查找命中图片
  PdfHitImageResult hitResult = PdfHitImageAt(page, px, py, hpt, 2.0f);
  FPDF_PAGEOBJECT hit = hitResult.imageObj;
  MacLog_DebugNS([NSString
      stringWithFormat:
          @"[saveImage] hit test: obj=%p, bounds=(%.1f,%.1f)-(%.1f,%.1f)", hit,
          hitResult.minx, hitResult.miny, hitResult.maxx, hitResult.maxy]);
  if (!hit) {
    LOG_TAG_NS("PdfWinViewer", "[saveImage] no image hit");
    MacLog_DebugNS(@"[saveImage] no image found at coordinates");
    FPDF_ClosePage(page);
    return;
  }
  // 优先原始像素，如失败回退渲染位图（抽到 shared 模块）
  bool needDestroy = false;
  FPDF_BITMAP useBmp = PdfAcquireBitmapForImage(_doc, page, hit, needDestroy);
  MacLog_DebugNS([NSString
      stringWithFormat:@"[saveImage] bitmap acquired: %p, needDestroy: %@",
                       useBmp, needDestroy ? @"YES" : @"NO"]);

  void* buf = nullptr;
  int w = 0, h = 0, stride = 0;
  if (useBmp) {
    buf = FPDFBitmap_GetBuffer(useBmp);
    w = FPDFBitmap_GetWidth(useBmp);
    h = FPDFBitmap_GetHeight(useBmp);
    stride = FPDFBitmap_GetStride(useBmp);
    MacLog_DebugNS([NSString
        stringWithFormat:@"[saveImage] bitmap info: %dx%d, stride=%d, buf=%p",
                         w, h, stride, buf]);
  }
  if (!buf || w <= 0 || h <= 0) {
    LOG_TAG_NS("PdfWinViewer", "[saveImage] no bitmap available");
    MacLog_DebugNS(@"[saveImage] bitmap acquisition failed");
    if (needDestroy && useBmp) {
      FPDFBitmap_Destroy(useBmp);
    }
    FPDF_ClosePage(page);
    return;
  }
  // 保存为 PNG（mac 端采用 ImageIO）
  NSSavePanel* sp = [NSSavePanel savePanel];
  [sp setNameFieldStringValue:@"image.png"];
  NSInteger resp = [sp runModal];
  LOG_TAG_NS("PdfWinViewer", "[saveImage] save panel resp=%ld", (long)resp);
  if (resp != NSModalResponseOK) {
    if (needDestroy) { /* release rendered */
    }
    FPDF_ClosePage(page);
    return;
  }
  NSURL* url = sp.URL;

  // 获取 PDFium 位图格式
  int pdfFormat = FPDFBitmap_GetFormat(useBmp);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[saveImage] PDFium format: %d", pdfFormat]);

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef dp = nullptr;

  // 根据 PDFium 格式设置正确的位图信息
  CGBitmapInfo bi;
  int bitsPerComponent = 8;
  int bitsPerPixel = 32;
  int finalStride = stride;

  // BGR 24位格式的转换缓冲区（需要在作用域外保持）
  static std::vector<unsigned char> rgbBuffer;

  if (pdfFormat == FPDFBitmap_BGRA) {
    // BGRA 格式
    bi = (CGBitmapInfo)((uint32_t)kCGBitmapByteOrder32Little |
                        (uint32_t)kCGImageAlphaPremultipliedFirst);
    dp = CGDataProviderCreateWithData(NULL, buf, (size_t)(stride * h), NULL);
  } else if (pdfFormat == FPDFBitmap_BGRx) {
    // BGRx 格式（无 alpha）
    bi = (CGBitmapInfo)((uint32_t)kCGBitmapByteOrder32Little |
                        (uint32_t)kCGImageAlphaNoneSkipFirst);
    dp = CGDataProviderCreateWithData(NULL, buf, (size_t)(stride * h), NULL);
  } else if (pdfFormat == FPDFBitmap_BGR) {
    // BGR 24位格式需要特殊处理，转换为 RGB 格式
    MacLog_DebugNS(@"[saveImage] converting BGR to RGB format");

    // 创建 RGB 缓冲区
    rgbBuffer.resize(w * h * 3);
    const unsigned char* bgrData = (const unsigned char*)buf;

    // BGR -> RGB 转换
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int bgrIdx = y * stride + x * 3;
        int rgbIdx = y * w * 3 + x * 3;
        rgbBuffer[rgbIdx + 0] = bgrData[bgrIdx + 2];  // R = B
        rgbBuffer[rgbIdx + 1] = bgrData[bgrIdx + 1];  // G = G
        rgbBuffer[rgbIdx + 2] = bgrData[bgrIdx + 0];  // B = R
      }
    }

    // 更新参数使用 RGB 数据
    dp = CGDataProviderCreateWithData(NULL, rgbBuffer.data(), rgbBuffer.size(),
                                      NULL);
    bitsPerPixel = 24;
    bi = (CGBitmapInfo)kCGBitmapByteOrderDefault;
    finalStride = w * 3;  // RGB stride

    MacLog_DebugNS([NSString
        stringWithFormat:@"[saveImage] BGR converted to RGB, new stride=%d",
                         finalStride]);
  } else {
    // 默认使用 BGRA
    bi = (CGBitmapInfo)((uint32_t)kCGBitmapByteOrder32Little |
                        (uint32_t)kCGImageAlphaPremultipliedFirst);
    dp = CGDataProviderCreateWithData(NULL, buf, (size_t)(stride * h), NULL);
  }

  MacLog_DebugNS([NSString
      stringWithFormat:@"[saveImage] using bitsPerPixel=%d, bitmapInfo=0x%x",
                       bitsPerPixel, (unsigned)bi]);

  CGImageRef img =
      CGImageCreate(w, h, bitsPerComponent, bitsPerPixel, finalStride, cs, bi,
                    dp, NULL, false, kCGRenderingIntentDefault);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[saveImage] CGImage created: %p", img]);
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1,
      NULL);
  MacLog_DebugNS([NSString
      stringWithFormat:@"[saveImage] destination created: %p, image: %p", dst,
                       img]);

  bool saveSuccess = false;
  if (dst && img) {
    CGImageDestinationAddImage(dst, img, NULL);
    saveSuccess = CGImageDestinationFinalize(dst);
    MacLog_DebugNS(
        [NSString stringWithFormat:@"[saveImage] finalize result: %@",
                                   saveSuccess ? @"SUCCESS" : @"FAILED"]);
  } else {
    MacLog_DebugNS(@"[saveImage] missing destination or image");
  }

  if (dst) {
    CFRelease(dst);
  }
  if (img) {
    CGImageRelease(img);
  }
  if (dp) {
    CGDataProviderRelease(dp);
  }
  if (cs) {
    CGColorSpaceRelease(cs);
  }

  // 释放 PDFium 位图
  if (needDestroy && useBmp) {
    FPDFBitmap_Destroy(useBmp);
    MacLog_DebugNS(@"[saveImage] bitmap destroyed");
  }

  FPDF_ClosePage(page);

  LOG_TAG_NS("PdfWinViewer", "[saveImage] save completed: %@, path: %@",
             saveSuccess ? @"SUCCESS" : @"FAILED", url.path);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[saveImage] final result: %@",
                                 saveSuccess ? @"SUCCESS" : @"FAILED"]);
}

// 检测点击位置的PDF对象
- (void)detectObjectAtPoint:(NSPoint)viewPoint {
  if (!_doc) {
    return;
  }

  NSPoint pageXY = [self toPagePxFromView:viewPoint];
  double px = pageXY.x, py = pageXY.y;

  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    return;
  }

  // 遍历页面上的所有对象
  int totalObjs = FPDFPage_CountObjects(page);
  LOG_TAG_NS("PdfView", "检测点击位置 (%.1f, %.1f)，页面共有 %d 个对象", px, py,
             totalObjs);

  for (int i = 0; i < totalObjs; i++) {
    FPDF_PAGEOBJECT obj = FPDFPage_GetObject(page, i);
    if (!obj) {
      continue;
    }

    // 获取对象边界
    float left, bottom, right, top;
    if (FPDFPageObj_GetBounds(obj, &left, &bottom, &right, &top)) {
      // 检查点击是否在对象边界内
      if (px >= left && px <= right && py >= bottom && py <= top) {
        int objType = FPDFPageObj_GetType(obj);
        LOG_TAG_NS("PdfView",
                   "点击命中对象 %d，类型: %d，边界: (%.1f,%.1f,%.1f,%.1f)", i,
                   objType, left, bottom, right, top);

        // 通知AppDelegate跳转到检查器中的对应对象
        if (self.delegate && [self.delegate respondsToSelector:@selector
                                            (pdfViewDidClickObject:atIndex:)]) {
          // 将FPDF_PAGEOBJECT包装为NSValue传递
          NSValue* objValue = [NSValue valueWithPointer:obj];
          [self.delegate performSelector:@selector(pdfViewDidClickObject:
                                                                 atIndex:)
                              withObject:objValue
                              withObject:@(i)];
        }
        break;  // 只处理第一个命中的对象
      }
    }
  }

  FPDF_ClosePage(page);
}

// 文本查找功能
- (BOOL)findText:(NSString*)searchText fromIndex:(NSNumber*)startIndex {
  if (!_doc || !searchText || searchText.length == 0) {
    LOG_TAG_NS("PdfView", "查找失败：无效的文档或搜索文本");
    return NO;
  }

  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    LOG_TAG_NS("PdfView", "查找失败：无法加载页面 %d", _pageIndex);
    return NO;
  }

  // 加载文本页面
  FPDF_TEXTPAGE textPage = FPDFText_LoadPage(page);
  if (!textPage) {
    LOG_TAG_NS("PdfView", "查找失败：无法加载文本页面");
    FPDF_ClosePage(page);
    return NO;
  }

  // 将NSString转换为FPDF_WIDESTRING
  NSData* utf16Data =
      [searchText dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
  FPDF_WIDESTRING wideString = (FPDF_WIDESTRING)utf16Data.bytes;

  int startIdx = startIndex ? [startIndex intValue] : 0;
  LOG_TAG_NS("PdfView", "开始查找文本: '%@'，起始索引: %d", searchText,
             startIdx);

  // 开始搜索
  FPDF_SCHHANDLE searchHandle =
      FPDFText_FindStart(textPage, wideString, 0, startIdx);
  if (!searchHandle) {
    LOG_TAG_NS("PdfView", "查找失败：无法创建搜索句柄");
    FPDFText_ClosePage(textPage);
    FPDF_ClosePage(page);
    return NO;
  }

  // 查找下一个匹配
  BOOL found = FPDFText_FindNext(searchHandle);
  if (found) {
    int resultIndex = FPDFText_GetSchResultIndex(searchHandle);
    int resultCount = FPDFText_GetSchCount(searchHandle);
    LOG_TAG_NS("PdfView", "找到匹配文本，位置: %d，长度: %d", resultIndex,
               resultCount);

    // 获取匹配文本的边界框以便高亮显示
    double left, top, right, bottom;
    if (FPDFText_GetCharBox(textPage, resultIndex, &left, &bottom, &right,
                            &top)) {
      LOG_TAG_NS("PdfView", "匹配文本边界: (%.1f, %.1f, %.1f, %.1f)", left,
                 bottom, right, top);

      // 将PDF坐标转换为视图坐标并滚动到可见区域
      NSPoint viewPoint = [self toViewFromPagePx:NSMakePoint(left, top)];
      NSRect visibleRect =
          NSMakeRect(viewPoint.x - 50, viewPoint.y - 50, 100, 100);
      [self scrollRectToVisible:visibleRect];

      // 标记需要重绘以显示高亮
      [self setNeedsDisplay:YES];
    }
  } else {
    LOG_TAG_NS("PdfView", "未找到匹配的文本");
  }

  // 清理资源
  FPDFText_FindClose(searchHandle);
  FPDFText_ClosePage(textPage);
  FPDF_ClosePage(page);

  return found;
}

@end
