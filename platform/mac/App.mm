//
// macOS 原生前端（路线 B）：最小可用 PDF 渲染窗口
// - 启动后弹出选择 PDF，渲染到窗口
// - 支持 Home/End 翻页、PgUp/PgDn、Cmd +/- 缩放
//
#include "../shared/pdf_utils.h"
#include "../shared/pdfium_object_info.h"
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "public/fpdf_doc.h"
#include "public/fpdf_edit.h"
#include "public/fpdf_text.h"
#include "public/fpdfview.h"
#include <mach/mach.h>
#include <string>
#include <vector>

// ================= 界面布局常量 =================
static const CGFloat kBookmarkCollapsedWidth = 20.0;
static const CGFloat kBookmarkExpandedWidth = 260.0;
static const CGFloat kInspectorWidth = 300.0;
static const CGFloat kControlBarHeight = 30.0;
static const CGFloat kScrollBarWidth = 15.0; // 垂直滚动条宽度

// ================= 日志子系统（与 Windows 对齐） =================
#if !defined(PDFWV_ENABLE_LOGGING)
#define PDFWV_ENABLE_LOGGING 1
#endif

enum class LogLevel { Critical, Error, Warning, Debug, Trace };

static inline double NowSeconds() {
  static double sStart = 0.0;
  double t = CFAbsoluteTimeGetCurrent();
  if (sStart == 0.0)
    sStart = t;
  return t - sStart;
}

static inline double GetProcessMemMB() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t kr =
      task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
  if (kr == KERN_SUCCESS) {
    return (double)info.phys_footprint / (1024.0 * 1024.0);
  }
  mach_task_basic_info_data_t b{};
  mach_msg_type_number_t cb = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&b, &cb) ==
      KERN_SUCCESS) {
    return (double)b.resident_size / (1024.0 * 1024.0);
  }
  return 0.0;
}

// 将 wchar_t* 安全转换为 NSString（兼容 macOS 上 4 字节 wchar_t）
static inline NSString *NSStringFromWChar(const wchar_t *ws) {
  if (!ws)
    return @"";
  size_t len = wcslen(ws);
  if (len == 0)
    return @"";
  CFStringRef cfs = nullptr;
  if (sizeof(wchar_t) == 4) {
    cfs = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)ws,
                                  (CFIndex)(len * 4), kCFStringEncodingUTF32LE,
                                  false);
  } else {
    cfs = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)ws,
                                  (CFIndex)(len * 2), kCFStringEncodingUTF16LE,
                                  false);
  }
  return CFBridgingRelease(cfs);
}

// 提前定义全局日志窗口指针，供窗口委托关闭时访问
@class _LogWindowController;
static _LogWindowController *_gLogCtrl = nil;

@interface _LogWindowController
    : NSWindowController <NSTableViewDataSource, NSTableViewDelegate,
                          NSWindowDelegate>
@property(nonatomic, strong) NSButton *enableButton;
@property(nonatomic, strong) NSButton *clearButton;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSPopUpButton *filter;
// NSWindowDelegate
- (void)windowWillClose:(NSNotification *)notification;
@end

// 前向声明内部日志开关函数，避免在方法体里临时 extern 声明
static bool MacLog_IsEnabled();
static void MacLog_SetEnabled(bool on);

@implementation _LogWindowController
- (instancetype)init {
  NSRect rc = NSMakeRect(200, 200, 900, 600);
  NSWindow *w = [[NSWindow alloc]
      initWithContentRect:rc
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  if (self = [super initWithWindow:w]) {
    w.delegate = (id<NSWindowDelegate>)self;
    self.rows = [NSMutableArray new];
    NSView *c = w.contentView;
    NSButton *en = [NSButton checkboxWithTitle:@"Enable logging"
                                        target:self
                                        action:@selector(onToggle:)];
    en.frame = NSMakeRect(12, rc.size.height - 36, 140, 24);
    [c addSubview:en];
    self.enableButton = en;
    NSButton *cl = [NSButton buttonWithTitle:@"Clear"
                                      target:self
                                      action:@selector(onClear:)];
    cl.frame = NSMakeRect(160, rc.size.height - 36, 80, 24);
    [c addSubview:cl];
    self.clearButton = cl;
    // 过滤按钮
    NSPopUpButton *filt = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(250, rc.size.height - 36, 160, 24)
            pullsDown:NO];
    [filt addItemsWithTitles:@[ @"All", @"Debug", @"Perf" ]];
    [filt setTarget:self];
    [filt setAction:@selector(onFilter:)];
    [c addSubview:filt];
    _filter = filt;

    NSScrollView *sv =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, rc.size.width - 16,
                                                       rc.size.height - 56)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTableView *tv = [[NSTableView alloc] initWithFrame:sv.bounds];
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.delegate = self;
    tv.dataSource = self;
    auto addCol = ^(NSString *idt, NSString *title, CGFloat w) {
      NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:idt];
      col.title = title;
      col.width = w;
      [tv addTableColumn:col];
    };
    addCol(@"Elapsed", @"Elapsed", 110);
    addCol(@"Level", @"LVL:描述", 120);
    addCol(@"Page", @"page", 56);
    addCol(@"Zoom", @"zoom", 64);
    addCol(@"Time", @"time(ms)", 80);
    addCol(@"Mem", @"mem(MB)", 80);
    addCol(@"DMem", @"Δmem(MB)", 90);
    addCol(@"Remarks", @"Remarks", 420);
    sv.documentView = tv;
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = YES;
    [c addSubview:sv];
    self.table = tv;
  }
  return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  if (_filter.indexOfSelectedItem == 0)
    return (NSInteger)self.rows.count;
  NSString *key =
      (_filter.indexOfSelectedItem == 1) ? @"Debug:跟踪" : @"Debug:渲染性能";
  __block NSInteger cnt = 0;
  [self.rows enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull d,
                                          NSUInteger idx, BOOL *_Nonnull stop) {
    if ([d[@"Level"] isEqualToString:key])
      ++cnt;
  }];
  return cnt;
}
- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
  NSTableCellView *cell =
      [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
    cell.identifier = tableColumn.identifier;
    NSTextField *tf = [[NSTextField alloc] initWithFrame:cell.bounds];
    tf.bezeled = NO;
    tf.drawsBackground = NO;
    tf.editable = NO;
    tf.selectable = NO;
    tf.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cell.textField = tf;
    [cell addSubview:tf];
  }
  // 简单过滤：重新选择时 table 会刷新，这里按顺序取匹配项
  NSDictionary *d = nil;
  if (_filter.indexOfSelectedItem == 0) {
    d = self.rows[(NSUInteger)row];
  } else {
    NSString *key =
        (_filter.indexOfSelectedItem == 1) ? @"Debug:跟踪" : @"Debug:渲染性能";
    NSInteger idx = -1;
    for (NSDictionary *it in self.rows) {
      if ([it[@"Level"] isEqualToString:key]) {
        ++idx;
        if (idx == row) {
          d = it;
          break;
        }
      }
    }
    if (!d)
      d = @{};
  }
  cell.textField.stringValue = d[tableColumn.identifier] ?: @"";
  return cell;
}

- (void)appendRow:(NSDictionary *)row {
  [self.rows addObject:row];
  [self.table reloadData];
  NSInteger last = (NSInteger)self.rows.count - 1;
  if (last >= 0)
    [self.table scrollRowToVisible:last];
}

- (void)onToggle:(id)sender {
  MacLog_SetEnabled(self.enableButton.state == NSControlStateValueOn);
}
- (void)onClear:(id)sender {
  [self.rows removeAllObjects];
  [self.table reloadData];
}
- (void)onFilter:(id)sender {
  [self.table reloadData];
}
// 关闭窗口即停止日志并释放控制器
- (void)windowWillClose:(NSNotification *)notification {
  MacLog_SetEnabled(false);
  _gLogCtrl = nil;
}
@end

// 默认启用日志记录（性能日志总是记录到文件，窗口显示可选）
static bool &_LogEnabledRef() {
  static bool e = true;  // 改为默认启用
  return e;
}

static bool MacLog_IsEnabled() { return _LogEnabledRef(); }
static void MacLog_SetEnabled(bool on) { _LogEnabledRef() = on; }
static inline void MacLog_ShowWindow() {
  if (!_gLogCtrl) {
    _gLogCtrl = [_LogWindowController new];
  }
  [_gLogCtrl showWindow:nil];
  _gLogCtrl.enableButton.state =
      MacLog_IsEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

static inline NSString *WFormat(const wchar_t *fmt, va_list ap) {
  wchar_t buf[1200];
  vswprintf(buf, 1199, fmt, ap);
  buf[1199] = 0;
  return [[NSString alloc] initWithCharacters:(const unichar *)buf
                                       length:wcslen(buf)];
}

static inline NSString *ToNSString(double v, int prec) {
  return [NSString
      stringWithFormat:(prec >= 0 ? [NSString stringWithFormat:@"%%.%df", prec]
                                  : @"%f"),
                       v];
}
static inline NSString *ToNSStringI(int v) {
  return [NSString stringWithFormat:@"%d", v];
}

static double _lastMemMB = 0.0;
static double _openStartSec = 0.0;
static bool _firstRenderAfterOpen = false;
// 文件日志：路径与句柄
static NSString *MacLog_FilePath() {
  NSString *exec = [[NSBundle mainBundle] executablePath];
  NSString *dir = [exec stringByDeletingLastPathComponent];
  return [dir stringByAppendingPathComponent:@"debug.log"];
}
static void MacLog_ResetFileOnStartup() {
  NSString *path = MacLog_FilePath();
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void MacLog_AppendLine(NSString *line) {
  if (!line)
    return;
  NSString *s = [line stringByAppendingString:@"\n"];
  NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle *fh =
      [NSFileHandle fileHandleForWritingAtPath:MacLog_FilePath()];
  if (!fh) {
    [[NSFileManager defaultManager] createFileAtPath:MacLog_FilePath()
                                            contents:nil
                                          attributes:nil];
    fh = [NSFileHandle fileHandleForWritingAtPath:MacLog_FilePath()];
  }
  [fh seekToEndOfFile];
  [fh writeData:data];
  [fh closeFile];
}
static void MacLog_DebugNS(NSString *msg) {
  if (!msg)
    return;
  MacLog_AppendLine([@"[DBG] " stringByAppendingString:msg]);
}

static void Log_WriteF(LogLevel lv, const wchar_t *fmt, ...) {
#if PDFWV_ENABLE_LOGGING
  if (!MacLog_IsEnabled())
    return;
  va_list ap;
  va_start(ap, fmt);
  NSString *msg = WFormat(fmt, ap);
  va_end(ap);
  double el = NowSeconds();
  MacLog_AppendLine(
      [NSString stringWithFormat:@"[DBG] [+%7.3fs] %@", el, msg ?: @""]);
  if (_gLogCtrl) {
    NSDictionary *row = @{
      @"Elapsed" : [NSString stringWithFormat:@"%7.3f s", el],
      @"Level" : @"Debug:跟踪",
      @"Page" : @"",
      @"Zoom" : @"",
      @"Time" : @"",
      @"Mem" : @"",
      @"DMem" : @"",
      @"Remarks" : msg ?: @""
    };
    [_gLogCtrl appendRow:row];
  }
#else
  (void)lv;
  (void)fmt;
#endif
}

static void Log_WritePerfEx(int page, double zoomPct, double timeMs,
                            double memMB, double deltaMB,
                            const wchar_t *remarks, const char *file, int line,
                            const char *func) {
#if PDFWV_ENABLE_LOGGING
  if (!MacLog_IsEnabled())
    return;
  double el = NowSeconds();
  NSString *lvl = @"Debug:渲染性能";
  NSString *zoom = [NSString stringWithFormat:@"%.0f%%", zoomPct];
  NSString *tms = ToNSString(timeMs, 2);
  NSString *mem = ToNSString(memMB, 2);
  NSString *dmem = ToNSString(deltaMB, 2);
  NSString *src = [NSString
      stringWithFormat:@"%s:%d %s", file ? file : "", line, func ? func : ""];
  NSString *rem = [NSString
      stringWithFormat:@"%@%@%s", NSStringFromWChar(remarks),
                       (remarks && remarks[0] ? @" | " : @""), src.UTF8String];
  MacLog_AppendLine([NSString
      stringWithFormat:@"[PERF] [+%7.3fs] p=%d z=%@ t=%@ mem=%@ dmem=%@ | %@",
                       el, page, zoom, tms, mem, dmem, rem]);
  if (_gLogCtrl) {
    NSDictionary *row = @{
      @"Elapsed" : [NSString stringWithFormat:@"%7.3f s", el],
      @"Level" : lvl,
      @"Page" : ToNSStringI(page),
      @"Zoom" : zoom,
      @"Time" : tms,
      @"Mem" : mem,
      @"DMem" : dmem,
      @"Remarks" : rem
    };
    [_gLogCtrl appendRow:row];
  }
#else
  (void)page;
  (void)zoomPct;
  (void)timeMs;
  (void)memMB;
  (void)deltaMB;
  (void)remarks;
  (void)file;
  (void)line;
  (void)func;
#endif
}

static void Log_WritePerf(int page, double zoomPct, double timeMs, double memMB,
                          double deltaMB) {
  Log_WritePerfEx(page, zoomPct, timeMs, memMB, deltaMB, L"渲染单页统计",
                  __FILE__, __LINE__, __FUNCTION__);
}

#if PDFWV_ENABLE_LOGGING
#define LOGF(lv, fmt, ...)                                                     \
  do {                                                                         \
    if (MacLog_IsEnabled())                                                    \
      Log_WriteF((lv), L##fmt, ##__VA_ARGS__);                                 \
  } while (0)
#define LOGM(lv, msg)                                                          \
  do {                                                                         \
    if (MacLog_IsEnabled())                                                    \
      Log_WriteF((lv), L"%s", L##msg);                                         \
  } while (0)
#else
#define LOGF(...)                                                              \
  do {                                                                         \
  } while (0)
#define LOGM(...)                                                              \
  do {                                                                         \
  } while (0)
#endif

static inline void Log_ShowWindow() { MacLog_ShowWindow(); }

// ================= PDFium 错误辅助 =================
static inline void LogFPDFLastError(const char *where) {
  unsigned long code = FPDF_GetLastError();
  const char *msg = "Unknown";
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

static inline std::string NSStringToUTF8(NSObject *obj) {
  if (!obj)
    return {};
  NSString *s = (NSString *)obj;
  return std::string([s UTF8String] ?: "");
}

// PdfView的委托协议
@protocol PdfViewDelegate <NSObject>
@optional
- (void)pdfViewDidChangePage:(id)sender;
- (void)pdfViewDidClickObject:(NSValue *)objectValue atIndex:(NSNumber *)index;
@end

@interface PdfView : NSView
@property(nonatomic, assign) id<PdfViewDelegate> delegate;
- (BOOL)openPDFAtPath:(NSString *)path;
- (FPDF_DOCUMENT)document;
- (void)goToPage:(int)index;
- (int)currentPageIndex;         // 获取当前页索引（0开始）
- (NSSize)currentPageSizePt;     // 当前页 PDF 尺寸（pt）
- (void)updateViewSizeToFitPage; // 根据页尺寸与缩放调整自身 frame
                                 // 大小（供滚动容器使用）
- (BOOL)findText:(NSString *)searchText
       fromIndex:(NSNumber *)startIndex; // 文本查找功能
@end

@implementation PdfView {
  FPDF_DOCUMENT _doc;
  int _pageIndex;
  double _zoom;
  // 选择与交互
  bool _selecting;
  NSPoint _selStart;
  NSPoint _selEnd;
  NSPoint _lastContextPt;    // 最近一次右键菜单触发位置（视图坐标）
  BOOL _lastContextHitImage; // 最近一次右键是否命中图片
}
- (NSPoint)toPagePxFromView:(NSPoint)viewPt {
  // Convert view coordinates to page coordinates (in points)
  // This should match the coordinate system used in rendering
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);

  // Convert view pixels to page points
  // The view shows the page at _zoom scale
  double px = viewPt.x / _zoom;
  double py = viewPt.y / _zoom;

  // Note: PdfHitImageAt will handle the Y-axis flip from top-left to
  // bottom-left
  return NSMakePoint(px, py);
}

- (NSPoint)toViewFromPagePx:(NSPoint)pagePt {
  // Convert page coordinates back to view coordinates for debugging
  double vx = pagePt.x * _zoom;
  double vy = pagePt.y * _zoom;
  return NSMakePoint(vx, vy);
}

- (FPDF_DOCUMENT)document {
  return _doc;
}
- (int)currentPageIndex {
  return _pageIndex;
}
- (void)goToPage:(int)index {
  if (!_doc)
    return;
  int pc = FPDF_GetPageCount(_doc);
  if (pc > 0) {
    if (index < 0)
      index = 0;
    if (index >= pc)
      index = pc - 1;
    int oldIndex = _pageIndex;
    _pageIndex = index;
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
    _selecting = false;
    [self.window setAcceptsMouseMovedEvents:YES];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)openPDFAtPath:(NSString *)path {
  NSLog(@"[PdfWinViewer] openPDFAtPath: %@", path);
  if (_doc) {
    FPDF_CloseDocument(_doc);
    _doc = nullptr;
    _pageIndex = 0;
    _zoom = 1.0;
  }
  std::string u8 = NSStringToUTF8(path);
  FPDF_LIBRARY_CONFIG cfg{};
  cfg.version = 3;
  FPDF_InitLibraryWithConfig(&cfg);
  _doc = FPDF_LoadDocument(u8.c_str(), nullptr);
  if (!_doc) {
    LogFPDFLastError("FPDF_LoadDocument");
    return NO;
  }
  int pc = FPDF_GetPageCount(_doc);
  NSLog(@"[PdfWinViewer] document loaded. pageCount=%d", pc);
// 首次渲染计时起点（只要编译时启用日志就记录，运行时再判断是否输出）
#if PDFWV_ENABLE_LOGGING
  _openStartSec = NowSeconds();
  _firstRenderAfterOpen = true;
  _lastMemMB = GetProcessMemMB();
#endif
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
  return YES;
}

- (NSSize)currentPageSizePt {
  if (!_doc)
    return NSMakeSize(0, 0);
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  return NSMakeSize((CGFloat)wpt, (CGFloat)hpt);
}

- (void)updateViewSizeToFitPage {
  NSSize s = [self currentPageSizePt];
  if (s.width <= 0 || s.height <= 0)
    return;
  [self setFrameSize:NSMakeSize((CGFloat)(s.width * _zoom),
                                (CGFloat)(s.height * _zoom))];
}

- (void)keyDown:(NSEvent *)event {
  if (!_doc)
    return;
  NSString *chars = [event charactersIgnoringModifiers];
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;
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
    if (pc > 0)
      _pageIndex = pc - 1;
    break;
  }
  case NSPageUpFunctionKey:
    _pageIndex = (_pageIndex > 0) ? _pageIndex - 1 : 0;
    break;
  case NSPageDownFunctionKey: {
    int pc = FPDF_GetPageCount(_doc);
    if (pc > 0 && _pageIndex < pc - 1)
      _pageIndex++;
    break;
  }
  default:
    break;
  }
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

- (void)magnifyWithEvent:(NSEvent *)event {
  // 触控板捏合缩放
  _zoom = std::max(0.1, std::min(8.0, _zoom * (1.0 + event.magnification)));
  [self updateViewSizeToFitPage];
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  [[NSColor whiteColor] setFill];
  NSRectFill(self.bounds);
  if (!_doc)
    return;
  int pageCount = FPDF_GetPageCount(_doc);
  if (pageCount <= 0)
    return;
  if (_pageIndex < 0)
    _pageIndex = 0;
  if (_pageIndex >= pageCount)
    _pageIndex = pageCount - 1;

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

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(
        NULL, buffer.data(), (size_t)buffer.size(), NULL);
    CGBitmapInfo bi =
        (CGBitmapInfo)((uint32_t)kCGBitmapByteOrder32Little |
                       (uint32_t)kCGImageAlphaPremultipliedFirst); // BGRA
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
    CGContextTranslateCTM(ctx, 0, destHpt);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    // 绘制统一的白色背景（随缩放变化），避免缩放后背景与内容不同步
    CGContextSetFillColorWithColor(ctx, [NSColor whiteColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, destWpt, destHpt));
    CGContextDrawImage(ctx, CGRectMake(0, 0, destWpt, destHpt), img);
    CGContextRestoreGState(ctx);
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
      Log_WritePerfEx(_pageIndex + 1, _zoom * 100.0, openMs, curMB, dMB,
                      L"打开PDF→首次渲染", __FILE__, __LINE__, __FUNCTION__);
      _firstRenderAfterOpen = false;
    } else {
      Log_WritePerf(_pageIndex + 1, _zoom * 100.0, ms, curMB, dMB);
    }
  }
#endif
}

#pragma mark - Mouse events for selection and link navigation

- (void)mouseDown:(NSEvent *)event {
  if (!_doc)
    return;
  _selecting = true;
  _selStart = [self convertPoint:event.locationInWindow fromView:nil];
  _selEnd = _selStart;
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_doc || !_selecting)
    return;
  _selEnd = [self convertPoint:event.locationInWindow fromView:nil];
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
  if (!_doc)
    return;
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

- (void)rightMouseDown:(NSEvent *)event {
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
      if (obj && FPDFPageObj_GetType(obj) == FPDF_PAGEOBJ_IMAGE)
        imageObjs++;
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
  NSString *ctxLine =
      [NSString stringWithFormat:@"[context] doc=%@ page=%d view=(%.1f,%.1f) "
                                 @"pageXY=(%.1f,%.1f) hitImage=%@",
                                 _doc ? @"YES" : @"NO", _pageIndex, pt.x, pt.y,
                                 px, py, hitImage ? @"YES" : @"NO"];
  NSLog(@"[PdfWinViewer] %@", ctxLine);
  MacLog_DebugNS(ctxLine);
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
  menu.autoenablesItems = NO; // 禁用自动启用，手动控制菜单项状态
  [menu addItemWithTitle:@"复制选中文本"
                  action:@selector(copySelectionToPasteboard)
           keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *expPage = [menu addItemWithTitle:@"导出当前页 PNG"
                                        action:@selector(exportCurrentPagePNG)
                                 keyEquivalent:@""];
  expPage.target = self;
  expPage.enabled = (_doc != nullptr);
  NSMenuItem *saveImg = [menu addItemWithTitle:@"保存图片…"
                                        action:@selector(saveImageAtPoint:)
                                 keyEquivalent:@""];
  saveImg.target = self;
  saveImg.enabled = hitImage;
  MacLog_DebugNS([NSString stringWithFormat:@"[context] menu item enabled: %@",
                                            hitImage ? @"YES" : @"NO"]);
  [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)scrollWheel:(NSEvent *)event {
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if ((mods & NSEventModifierFlagCommand) != 0) {
    double delta = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas)
      delta *= 0.1;
    if (delta > 0)
      _zoom = std::min(8.0, _zoom * 1.05);
    else if (delta < 0)
      _zoom = std::max(0.1, _zoom / 1.05);
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

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
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
  if (!_doc)
    return;
  NSString *text = [self extractSelectedText];
  if (text.length == 0)
    return;
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setString:text forType:NSPasteboardTypeString];
}

- (NSString *)extractSelectedText {
  if (!_doc || NSEqualPoints(_selStart, _selEnd))
    return @"";
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page)
    return @"";
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  // 视图坐标 -> 页面像素坐标（与渲染一致）
  int dpi = 72 * (int)ceil([self.window backingScaleFactor] ?: 2.0);
  auto toPagePx = ^(NSPoint p) {
    double x = p.x * (dpi / 72.0) / _zoom;
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
                          (unsigned short *)wbuf.data(), n);
  FPDFText_ClosePage(tp);
  FPDF_ClosePage(page);
  NSString *s = [[NSString alloc] initWithCharacters:(unichar *)wbuf.data()
                                              length:(NSUInteger)n];
  return s ?: @"";
}

- (void)tryNavigateLinkAtPoint:(NSPoint)viewPt {
  if (!_doc)
    return;
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page)
    return;
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  int dpi = 72 * (int)ceil([self.window backingScaleFactor] ?: 2.0);
  double px = viewPt.x * (dpi / 72.0) / _zoom;
  double py = std::max(0.0, hpt - viewPt.y * (dpi / 72.0) / _zoom);
  FPDF_LINK link = FPDFLink_GetLinkAtPoint(page, px, py);
  if (link) {
    FPDF_DEST dest = FPDFLink_GetDest(_doc, link);
    if (!dest) {
      FPDF_ACTION act = FPDFLink_GetAction(link);
      if (act)
        dest = FPDFAction_GetDest(_doc, act);
    }
    if (dest) {
      int pageIndex = FPDFDest_GetDestPageIndex(_doc, dest);
      if (pageIndex >= 0) {
        _pageIndex = pageIndex;
        [self setNeedsDisplay:YES];
      }
    }
  }
  FPDF_ClosePage(page);
}

- (void)promptGotoPage {
  if (!_doc)
    return;
  NSInteger pc = FPDF_GetPageCount(_doc);
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"跳转到页";
  NSTextField *tf =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
  [tf setStringValue:[NSString stringWithFormat:@"%d", _pageIndex + 1]];
  alert.accessoryView = tf;
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSInteger v = tf.integerValue;

    // 边界检查：确保页码在有效范围内
    if (v < 1) {
      v = 1; // 小于最小值时使用最小值
      NSLog(@"[PageNavigation] 输入页码小于1，调整为最小值: %ld", (long)v);
    } else if (v > pc) {
      v = pc; // 大于最大值时使用最大值
      NSLog(@"[PageNavigation] 输入页码超过最大值%ld，调整为最大值: %ld",
            (long)pc, (long)v);
    }

    int oldIndex = _pageIndex;
    _pageIndex = (int)v - 1; // 转换为0基索引
    NSLog(@"[PageNavigation] 设置页码为: %ld (索引: %d)", (long)v, _pageIndex);
    [self setNeedsDisplay:YES];

    if (oldIndex != _pageIndex &&
        [self.delegate respondsToSelector:@selector(pdfViewDidChangePage:)]) {
      [self.delegate pdfViewDidChangePage:self];
    }
  }
}

- (BOOL)exportCurrentPagePNG {
  NSLog(@"[PdfWinViewer][exportPage] doc=%@ page=%d", _doc ? @"YES" : @"NO",
        _pageIndex);
  if (!_doc)
    return NO;
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page)
    return NO;
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

  NSSavePanel *sp = [NSSavePanel savePanel];
  [sp setNameFieldStringValue:[NSString stringWithFormat:@"page_%d.png",
                                                         _pageIndex + 1]];
  if ([sp runModal] != NSModalResponseOK) {
    FPDFBitmap_Destroy(bmp);
    FPDF_ClosePage(page);
    return NO;
  }
  NSURL *url = sp.URL;

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
  if (dst)
    CFRelease(dst);
  if (img)
    CGImageRelease(img);
  if (dp)
    CGDataProviderRelease(dp);
  if (cs)
    CGColorSpaceRelease(cs);
  FPDFBitmap_Destroy(bmp);
  FPDF_ClosePage(page);
  return YES;
}

- (IBAction)saveImageAtPoint:(id)sender {
  if (!_doc)
    return;
  if (!_lastContextHitImage) {
    MacLog_DebugNS(@"[saveImage] blocked: last context not on image");
    return;
  }
  NSPoint pt = _lastContextPt; // 使用右键弹出时记录的位置
  NSPoint pageXY = [self toPagePxFromView:pt];
  double px = pageXY.x, py = pageXY.y;
  double wpt = 0, hpt = 0;
  FPDF_GetPageSizeByIndex(_doc, _pageIndex, &wpt, &hpt);
  NSLog(@"[PdfWinViewer][saveImage] use pt=(%.1f,%.1f) => pageXY=(%.1f,%.1f) "
        @"pageWH=(%.1f,%.1f)",
        pt.x, pt.y, px, py, wpt, hpt);
  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page)
    return;
  // 使用共享的 pdf_utils 模块查找命中图片
  PdfHitImageResult hitResult = PdfHitImageAt(page, px, py, hpt, 2.0f);
  FPDF_PAGEOBJECT hit = hitResult.imageObj;
  MacLog_DebugNS([NSString
      stringWithFormat:
          @"[saveImage] hit test: obj=%p, bounds=(%.1f,%.1f)-(%.1f,%.1f)", hit,
          hitResult.minx, hitResult.miny, hitResult.maxx, hitResult.maxy]);
  if (!hit) {
    NSLog(@"[PdfWinViewer][saveImage] no image hit");
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

  void *buf = nullptr;
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
    NSLog(@"[PdfWinViewer][saveImage] no bitmap available");
    MacLog_DebugNS(@"[saveImage] bitmap acquisition failed");
    if (needDestroy && useBmp)
      FPDFBitmap_Destroy(useBmp);
    FPDF_ClosePage(page);
    return;
  }
  // 保存为 PNG（mac 端采用 ImageIO）
  NSSavePanel *sp = [NSSavePanel savePanel];
  [sp setNameFieldStringValue:@"image.png"];
  NSInteger resp = [sp runModal];
  NSLog(@"[PdfWinViewer][saveImage] save panel resp=%ld", (long)resp);
  if (resp != NSModalResponseOK) {
    if (needDestroy) { /* release rendered */
    }
    FPDF_ClosePage(page);
    return;
  }
  NSURL *url = sp.URL;

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
    const unsigned char *bgrData = (const unsigned char *)buf;

    // BGR -> RGB 转换
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int bgrIdx = y * stride + x * 3;
        int rgbIdx = y * w * 3 + x * 3;
        rgbBuffer[rgbIdx + 0] = bgrData[bgrIdx + 2]; // R = B
        rgbBuffer[rgbIdx + 1] = bgrData[bgrIdx + 1]; // G = G
        rgbBuffer[rgbIdx + 2] = bgrData[bgrIdx + 0]; // B = R
      }
    }

    // 更新参数使用 RGB 数据
    dp = CGDataProviderCreateWithData(NULL, rgbBuffer.data(), rgbBuffer.size(),
                                      NULL);
    bitsPerPixel = 24;
    bi = (CGBitmapInfo)kCGBitmapByteOrderDefault;
    finalStride = w * 3; // RGB stride

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

  if (dst)
    CFRelease(dst);
  if (img)
    CGImageRelease(img);
  if (dp)
    CGDataProviderRelease(dp);
  if (cs)
    CGColorSpaceRelease(cs);

  // 释放 PDFium 位图
  if (needDestroy && useBmp) {
    FPDFBitmap_Destroy(useBmp);
    MacLog_DebugNS(@"[saveImage] bitmap destroyed");
  }

  FPDF_ClosePage(page);

  NSLog(@"[PdfWinViewer][saveImage] save completed: %@, path: %@",
        saveSuccess ? @"SUCCESS" : @"FAILED", url.path);
  MacLog_DebugNS(
      [NSString stringWithFormat:@"[saveImage] final result: %@",
                                 saveSuccess ? @"SUCCESS" : @"FAILED"]);
}

// 检测点击位置的PDF对象
- (void)detectObjectAtPoint:(NSPoint)viewPoint {
  if (!_doc)
    return;

  NSPoint pageXY = [self toPagePxFromView:viewPoint];
  double px = pageXY.x, py = pageXY.y;

  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page)
    return;

  // 遍历页面上的所有对象
  int totalObjs = FPDFPage_CountObjects(page);
  NSLog(@"[PdfView] 检测点击位置 (%.1f, %.1f)，页面共有 %d 个对象", px, py,
        totalObjs);

  for (int i = 0; i < totalObjs; i++) {
    FPDF_PAGEOBJECT obj = FPDFPage_GetObject(page, i);
    if (!obj)
      continue;

    // 获取对象边界
    float left, bottom, right, top;
    if (FPDFPageObj_GetBounds(obj, &left, &bottom, &right, &top)) {
      // 检查点击是否在对象边界内
      if (px >= left && px <= right && py >= bottom && py <= top) {
        int objType = FPDFPageObj_GetType(obj);
        NSLog(
            @"[PdfView] 点击命中对象 %d，类型: %d，边界: (%.1f,%.1f,%.1f,%.1f)",
            i, objType, left, bottom, right, top);

        // 通知AppDelegate跳转到检查器中的对应对象
        if (self.delegate && [self.delegate respondsToSelector:@selector
                                            (pdfViewDidClickObject:atIndex:)]) {
          // 将FPDF_PAGEOBJECT包装为NSValue传递
          NSValue *objValue = [NSValue valueWithPointer:obj];
          [self.delegate performSelector:@selector(pdfViewDidClickObject:
                                                                 atIndex:)
                              withObject:objValue
                              withObject:@(i)];
        }
        break; // 只处理第一个命中的对象
      }
    }
  }

  FPDF_ClosePage(page);
}

// 文本查找功能
- (BOOL)findText:(NSString *)searchText fromIndex:(NSNumber *)startIndex {
  if (!_doc || !searchText || searchText.length == 0) {
    NSLog(@"[PdfView] 查找失败：无效的文档或搜索文本");
    return NO;
  }

  FPDF_PAGE page = FPDF_LoadPage(_doc, _pageIndex);
  if (!page) {
    NSLog(@"[PdfView] 查找失败：无法加载页面 %d", _pageIndex);
    return NO;
  }

  // 加载文本页面
  FPDF_TEXTPAGE textPage = FPDFText_LoadPage(page);
  if (!textPage) {
    NSLog(@"[PdfView] 查找失败：无法加载文本页面");
    FPDF_ClosePage(page);
    return NO;
  }

  // 将NSString转换为FPDF_WIDESTRING
  NSData *utf16Data =
      [searchText dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
  FPDF_WIDESTRING wideString = (FPDF_WIDESTRING)utf16Data.bytes;

  int startIdx = startIndex ? [startIndex intValue] : 0;
  NSLog(@"[PdfView] 开始查找文本: '%@'，起始索引: %d", searchText, startIdx);

  // 开始搜索
  FPDF_SCHHANDLE searchHandle =
      FPDFText_FindStart(textPage, wideString, 0, startIdx);
  if (!searchHandle) {
    NSLog(@"[PdfView] 查找失败：无法创建搜索句柄");
    FPDFText_ClosePage(textPage);
    FPDF_ClosePage(page);
    return NO;
  }

  // 查找下一个匹配
  BOOL found = FPDFText_FindNext(searchHandle);
  if (found) {
    int resultIndex = FPDFText_GetSchResultIndex(searchHandle);
    int resultCount = FPDFText_GetSchCount(searchHandle);
    NSLog(@"[PdfView] 找到匹配文本，位置: %d，长度: %d", resultIndex,
          resultCount);

    // 获取匹配文本的边界框以便高亮显示
    double left, top, right, bottom;
    if (FPDFText_GetCharBox(textPage, resultIndex, &left, &bottom, &right,
                            &top)) {
      NSLog(@"[PdfView] 匹配文本边界: (%.1f, %.1f, %.1f, %.1f)", left, bottom,
            right, top);

      // 将PDF坐标转换为视图坐标并滚动到可见区域
      NSPoint viewPoint = [self toViewFromPagePx:NSMakePoint(left, top)];
      NSRect visibleRect =
          NSMakeRect(viewPoint.x - 50, viewPoint.y - 50, 100, 100);
      [self scrollRectToVisible:visibleRect];

      // 标记需要重绘以显示高亮
      [self setNeedsDisplay:YES];
    }
  } else {
    NSLog(@"[PdfView] 未找到匹配的文本");
  }

  // 清理资源
  FPDFText_FindClose(searchHandle);
  FPDFText_ClosePage(textPage);
  FPDF_ClosePage(page);

  return found;
}

@end

// 书签节点模型
@interface TocNode : NSObject
@property(nonatomic, strong) NSString *title;
@property(nonatomic, assign) int pageIndex; // -1 表示无跳转
@property(nonatomic, strong) NSMutableArray<TocNode *> *children;
@end

@implementation TocNode
@end

static NSString *BookmarkTitle(FPDF_DOCUMENT doc, FPDF_BOOKMARK bm) {
  int len = FPDFBookmark_GetTitle(bm, nullptr, 0);
  if (len <= 0)
    return @"";
  std::vector<unsigned short> w((size_t)len + 1, 0);
  FPDFBookmark_GetTitle(bm, (unsigned short *)w.data(), len);
  return [[NSString alloc] initWithCharacters:(unichar *)w.data()
                                       length:(NSUInteger)len];
}

static int BookmarkPage(FPDF_DOCUMENT doc, FPDF_BOOKMARK bm) {
  FPDF_DEST dest = FPDFBookmark_GetDest(doc, bm);
  if (!dest) {
    FPDF_ACTION act = FPDFBookmark_GetAction(bm);
    if (act)
      dest = FPDFAction_GetDest(doc, act);
  }
  if (!dest)
    return -1;
  return FPDFDest_GetDestPageIndex(doc, dest);
}

static void BuildBookmarkChildren(FPDF_DOCUMENT doc, FPDF_BOOKMARK parentBm,
                                  TocNode *parentNode) {
  FPDF_BOOKMARK child = FPDFBookmark_GetFirstChild(doc, parentBm);
  while (child) {
    TocNode *node = [TocNode new];
    node.title = BookmarkTitle(doc, child);
    node.pageIndex = BookmarkPage(doc, child);
    node.children = [NSMutableArray new];
    [parentNode.children addObject:node];
    // 递归
    BuildBookmarkChildren(doc, child, node);
    child = FPDFBookmark_GetNextSibling(doc, child);
  }
}

static TocNode *BuildBookmarksTree(FPDF_DOCUMENT doc) {
  TocNode *root = [TocNode new];
  root.title = @"ROOT";
  root.pageIndex = -1;
  root.children = [NSMutableArray new];
  BuildBookmarkChildren(doc, nullptr, root);
  return root;
}

@interface AppDelegate
    : NSObject <NSApplicationDelegate, NSOutlineViewDataSource,
                NSOutlineViewDelegate, PdfViewDelegate, NSSplitViewDelegate,
                NSTextViewDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSSplitView *split;
@property(nonatomic, strong) NSOutlineView *outline;
@property(nonatomic, strong) NSScrollView *outlineScroll;
@property(nonatomic, strong) PdfView *view;
@property(nonatomic, strong) TocNode *tocRoot;
@property(nonatomic, strong) NSMutableArray<NSString *> *recentPaths;
@property(nonatomic, strong) NSMenu *recentMenu;
@property(nonatomic, strong) NSMenuItem *recentMenuItem;
@property(nonatomic, strong)
    NSMutableDictionary *settingsDict; // 与 Windows 对齐的 settings.json 容器

// 底部状态栏相关属性
@property(nonatomic, strong) NSView *statusBar;
@property(nonatomic, strong) NSTextField *pageLabel;
@property(nonatomic, strong) NSTextField *pageInput;
@property(nonatomic, strong) NSTextField *totalPagesLabel;
@property(nonatomic, strong) NSButton *prevPageButton;
@property(nonatomic, strong) NSButton *nextPageButton;
@property(nonatomic, strong)
    NSView *mainContentView; // 主内容区域（不包括状态栏）

// 书签控制栏相关属性
@property(nonatomic, strong) NSView *bookmarkControlBar;
@property(nonatomic, strong) NSButton *bookmarkToggleButton;
@property(nonatomic, strong) NSView *leftPanel; // 左侧面板（包含控制栏和书签）
@property(nonatomic, assign) BOOL bookmarkVisible; // 书签是否可见
@property(nonatomic, strong)
    NSView *expandedTopControlBar; // 展开状态的顶部控制栏

// 右侧检查器面板相关属性
@property(nonatomic, strong)
    NSView *rightPanel; // 右侧面板（包含PDF内容和检查器）
@property(nonatomic, strong) NSView *pdfContentView; // PDF内容视图容器
@property(nonatomic, strong) NSView *inspectorPanel; // 检查器面板
@property(nonatomic, strong)
    NSButton *inspectorToggleButton;                // 检查器展开/收起按钮
@property(nonatomic, assign) BOOL inspectorVisible; // 检查器是否可见
@property(nonatomic, strong) NSTextView *inspectorTextView; // 检查器文本视图
@property(nonatomic, strong)
    NSScrollView *inspectorScrollView; // 检查器滚动视图
@property(nonatomic, strong)
    NSMutableDictionary *objectPositions; // 对象号 -> 文本位置映射

// 页面查找功能
@property(nonatomic, strong) NSPanel *findPanel;           // 查找面板
@property(nonatomic, strong) NSTextField *findTextField;   // 查找输入框
@property(nonatomic, strong) NSString *lastSearchTerm;     // 上次查找的内容
@property(nonatomic, assign) NSInteger currentSearchIndex; // 当前查找结果索引
@end

// 为在主实现中调用分类方法提供前置声明（命名分类，避免"primary
// class"重复实现告警）
@interface AppDelegate (ForwardDecls)
- (void)loadSettingsJSON;
- (void)extractRecentFromSettings;
- (void)rebuildRecentMenu;
- (void)persistRecentIntoSettings;
- (void)openPathAndAdjust:(NSString *)path;
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
- (TocNode *)findBookmarkForPage:(int)pageIndex inNode:(TocNode *)node;
- (void)expandParentsOfItem:(TocNode *)item;
- (BOOL)findParentPathForItem:(TocNode *)targetItem
                       inNode:(TocNode *)currentNode
                   parentPath:(NSMutableArray *)path;
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
- (void)displayObjectTreeNode:(PDFIUM_EX_OBJECT_TREE_NODE *)node
             attributedString:(NSMutableAttributedString *)attributedInfo
                  normalAttrs:(NSDictionary *)normalAttrs
                  objNumAttrs:(NSDictionary *)objNumAttrs;
- (void)updateInspectorContent;
- (void)handleShowWindowNotification:(NSNotification *)notification;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
// 启动清空文件日志
#if PDFWV_ENABLE_LOGGING
  MacLog_ResetFileOnStartup();
#endif
  NSRect rect = NSMakeRect(200, 200, 1200, 800);
  self.window = [[NSWindow alloc]
      initWithContentRect:rect
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  
  // 确保窗口可见
  [self.window setBackgroundColor:[NSColor windowBackgroundColor]];
  [self.window setIsVisible:YES];
  [self.window setAlphaValue:1.0];
  NSLog(@"[Window] 窗口创建完成，frame: %@, visible: %@", 
        NSStringFromRect(self.window.frame), 
        self.window.isVisible ? @"YES" : @"NO");

  // 创建主容器视图，包含主内容区域和底部状态栏
  NSView *containerView =
      [[NSView alloc] initWithFrame:self.window.contentView.bounds];
  containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // 创建主内容区域（占据除状态栏外的所有空间）
  self.mainContentView = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 30, rect.size.width, rect.size.height - 30)];
  self.mainContentView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [containerView addSubview:self.mainContentView];

  // 创建状态栏（高度30px，放在底部）
  [self createStatusBar];
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
  self.split.delegate = self;   // 设置委托以监听宽度变化
  [self.split setVertical:YES]; // 左右分栏：左侧书签，右侧内容

  // 创建左侧面板（包含顶部控制栏和书签区域）
  CGFloat initialWidth = kBookmarkExpandedWidth; // 默认展开状态
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

  // 创建书签控制栏
  [self createBookmarkControlBar];

  // 由于默认展开，直接创建展开状态的控件并隐藏收起状态的控制栏
  [self createExpandedBookmarkControls];

  // 隐藏收起状态的控制栏（因为默认展开）
  self.bookmarkControlBar.hidden = YES;

  // Outline（书签区域，位于控制栏下方，初始时隐藏）
  // 为滚动条预留空间，outline的宽度应该小于滚动视图的宽度
  CGFloat outlineWidth =
      kBookmarkExpandedWidth - kScrollBarWidth; // 为滚动条预留空间
  NSRect outlineFrame =
      NSMakeRect(0, 0, outlineWidth,
                 self.leftPanel.bounds.size.height - kControlBarHeight);
  NSLog(@"[ScrollDebug] outline宽度: %.1f (预留滚动条空间: %.1f)", outlineWidth,
        kScrollBarWidth);

  self.outline = [[NSOutlineView alloc] initWithFrame:outlineFrame];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"toc"];
  col.title = @"书签";
  col.width = outlineWidth - 20; // 为滚动条和边距预留空间
  col.minWidth = 100;
  col.maxWidth = outlineWidth - 10;
  NSLog(@"[ScrollDebug] 表格列宽度: %.1f", col.width);
  [self.outline addTableColumn:col];
  self.outline.outlineTableColumn = col;
  self.outline.delegate = self;
  self.outline.dataSource = self;
  self.outline.headerView = nil;
  self.outline.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.outline.rowSizeStyle = NSTableViewRowSizeStyleDefault;
  self.outline.allowsEmptySelection = YES;   // 允许空选择
  self.outline.allowsMultipleSelection = NO; // 禁用多选

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
  self.outlineScroll.hasHorizontalScroller = NO; // 禁用水平滚动条，避免占用空间
  self.outlineScroll.autohidesScrollers =
      NO; // 始终显示滚动条，提供更好的用户反馈

  NSLog(@"[ScrollDebug] 基本滚动条配置完成 - hasVertical: YES, hasHorizontal: "
        @"NO, autohides: NO");

  // 为了调试，暂时使用传统滚动条样式，更容易看到
  self.outlineScroll.scrollerStyle =
      NSScrollerStyleLegacy; // 传统滚动条，更明显可见
  NSLog(@"[ScrollDebug] 使用传统滚动条样式: NSScrollerStyleLegacy (调试模式)");

  // 滚动行为优化
  self.outlineScroll.verticalScrollElasticity =
      NSScrollElasticityAllowed; // 允许弹性滚动
  self.outlineScroll.horizontalScrollElasticity =
      NSScrollElasticityNone;                 // 禁用水平弹性滚动
  self.outlineScroll.borderType = NSNoBorder; // 无边框，更简洁
  self.outlineScroll.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;

  NSLog(@"[ScrollDebug] 滚动行为配置完成");

  // 检查初始滚动条状态
  NSScroller *initialVScroller = self.outlineScroll.verticalScroller;
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

  self.outlineScroll.hidden = NO; // 默认显示
  NSLog(@"[ScrollDebug] 滚动视图设置为显示状态");

  [self.leftPanel addSubview:self.outlineScroll];
  NSLog(@"[ScrollDebug] 滚动视图已添加到左侧面板");

  // 检查视图层次结构
  NSLog(@"[ScrollDebug] leftPanel frame: %@",
        NSStringFromRect(self.leftPanel.frame));
  NSLog(@"[ScrollDebug] leftPanel subviews count: %lu",
        (unsigned long)self.leftPanel.subviews.count);
  for (NSUInteger i = 0; i < self.leftPanel.subviews.count; i++) {
    NSView *subview = self.leftPanel.subviews[i];
    NSLog(@"[ScrollDebug] leftPanel subview[%lu]: %@ frame: %@",
          (unsigned long)i, NSStringFromClass([subview class]),
          NSStringFromRect(subview.frame));
  }

  NSLog(@"[ScrollDebug] ========== 书签滚动视图初始化完成 ==========");

  // 创建检查器面板
  [self createInspectorPanel];

  // 在右侧面板内创建PDF内容视图和检查器的分割视图
  NSSplitView *rightSplit =
      [[NSSplitView alloc] initWithFrame:self.rightPanel.bounds];
  rightSplit.dividerStyle = NSSplitViewDividerStyleThin;
  rightSplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  rightSplit.delegate = self; // 设置委托以控制最小宽度
  [rightSplit setVertical:YES]; // 左右分栏：左侧PDF内容，右侧检查器

  // 创建PDF内容视图容器
  CGFloat pdfContentWidth =
      self.rightPanel.bounds.size.width -
      (self.inspectorVisible ? kInspectorWidth : 0);
  self.pdfContentView = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, pdfContentWidth,
                               self.rightPanel.bounds.size.height)];
  self.pdfContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // 创建PDF视图
  self.view = [[PdfView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  self.view.delegate = self;
  NSScrollView *scroll =
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
  // 注意：由于 rightSplit 是局部变量，我们通过判断 splitView 是否在 rightPanel 的子视图中来识别

  // 设置初始分割位置（检查器默认收起，完全隐藏）
  [rightSplit setPosition:self.rightPanel.bounds.size.width
         ofDividerAtIndex:0];
  
  // 初始状态下隐藏检查器面板（即使有宽度也不显示）
  self.inspectorPanel.hidden = YES;

  [self.rightPanel addSubview:rightSplit];
  
  // 添加悬浮的检查器展开/收起按钮到右侧面板（在滚动条上方，独立悬浮）
  CGFloat buttonWidth = kBookmarkCollapsedWidth;
  CGFloat buttonHeight = kControlBarHeight;
  CGFloat buttonY = (self.rightPanel.bounds.size.height - buttonHeight) / 2;
  self.inspectorToggleButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(self.rightPanel.bounds.size.width -
                                   buttonWidth,
                               buttonY, buttonWidth, buttonHeight)];
  self.inspectorToggleButton.title = @"◀";
  self.inspectorToggleButton.font = [NSFont systemFontOfSize:14];
  self.inspectorToggleButton.bordered = NO; // 无边框，悬浮效果
  self.inspectorToggleButton.bezelStyle = NSBezelStyleRecessed;
  // 设置按钮样式为悬浮效果
  self.inspectorToggleButton.wantsLayer = YES;
  self.inspectorToggleButton.layer.backgroundColor = [[NSColor controlBackgroundColor] CGColor];
  self.inspectorToggleButton.layer.cornerRadius = 4.0;
  self.inspectorToggleButton.layer.shadowOpacity = 0.3;
  self.inspectorToggleButton.layer.shadowRadius = 2.0;
  self.inspectorToggleButton.layer.shadowOffset = NSMakeSize(0, -1);
  self.inspectorToggleButton.target = self;
  self.inspectorToggleButton.action = @selector(toggleInspectorVisibility:);
  self.inspectorToggleButton.autoresizingMask =
      NSViewMinXMargin | NSViewMaxYMargin | NSViewMinYMargin;
  [self.rightPanel addSubview:self.inspectorToggleButton]; // 添加到 rightPanel，确保在最上层，悬浮在滚动条上方

  [self.split addSubview:self.leftPanel];
  [self.split addSubview:self.rightPanel];
  [self.split setPosition:initialWidth ofDividerAtIndex:0]; // 默认显示展开宽度
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
  NSMenu *mainMenu = [NSMenu new];
  // App 菜单
  NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"App"
                                                   action:nil
                                            keyEquivalent:@""];
  NSMenu *appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"关于 PdfWinViewer" action:nil keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"退出"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  [appItem setSubmenu:appMenu];
  [mainMenu addItem:appItem];

  // 文件菜单
  NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"文件"
                                                    action:nil
                                             keyEquivalent:@""];
  NSMenu *fileMenu = [NSMenu new];
  NSMenuItem *openItem = [fileMenu addItemWithTitle:@"打开…"
                                             action:@selector(openDocument:)
                                      keyEquivalent:@"o"];
  openItem.target = self;
  NSMenuItem *exportItem = [fileMenu addItemWithTitle:@"导出当前页为 PNG"
                                               action:@selector(exportPNG:)
                                        keyEquivalent:@"e"];
  exportItem.target = self;
  exportItem.tag = 9901; // 用于后续查找
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
    NSMenuItem *mi = [fileMenu itemAtIndex:i];
    NSLog(@"[PdfWinViewer] File menu item[%ld]: title='%@' hasSubmenu=%@ "
          @"action=%@",
          (long)i, mi.title, (mi.submenu ? @"YES" : @"NO"),
          NSStringFromSelector(mi.action));
  }
  [fileItem setSubmenu:fileMenu];
  [mainMenu addItem:fileItem];

  // 编辑菜单
  NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑"
                                                    action:nil
                                             keyEquivalent:@""];
  NSMenu *editMenu = [NSMenu new];
  [editMenu addItemWithTitle:@"复制"
                      action:@selector(copy:)
               keyEquivalent:@"c"];
  [editItem setSubmenu:editMenu];
  [mainMenu addItem:editItem];

  // 视图/导航菜单
  NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"视图"
                                                    action:nil
                                             keyEquivalent:@""];
  NSMenu *viewMenu = [NSMenu new];
  NSMenuItem *zoomInItem = [viewMenu addItemWithTitle:@"放大"
                                               action:@selector(zoomIn:)
                                        keyEquivalent:@"="];
  zoomInItem.target = self.view;
  NSMenuItem *zoomOutItem = [viewMenu addItemWithTitle:@"缩小"
                                                action:@selector(zoomOut:)
                                         keyEquivalent:@"-"];
  zoomOutItem.target = self.view;
  NSMenuItem *zoomActualItem = [viewMenu addItemWithTitle:@"实际大小"
                                                   action:@selector(zoomActual:)
                                            keyEquivalent:@"0"];
  zoomActualItem.target = self.view;
  [viewMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *homeItem = [viewMenu addItemWithTitle:@"第一页"
                                             action:@selector(goHome:)
                                      keyEquivalent:@""];
  homeItem.target = self.view;
  NSMenuItem *endItem = [viewMenu addItemWithTitle:@"最后一页"
                                            action:@selector(goEnd:)
                                     keyEquivalent:@""];
  endItem.target = self.view;
  NSMenuItem *prevItem = [viewMenu addItemWithTitle:@"上一页"
                                             action:@selector(goPrevPage:)
                                      keyEquivalent:@"["];
  prevItem.target = self.view;
  NSMenuItem *nextItem = [viewMenu addItemWithTitle:@"下一页"
                                             action:@selector(goNextPage:)
                                      keyEquivalent:@"]"];
  nextItem.target = self.view;
  NSMenuItem *gotoItem = [viewMenu addItemWithTitle:@"跳转页…"
                                             action:@selector(gotoPage:)
                                      keyEquivalent:@"g"];
  gotoItem.target = self.view;
  [viewMenu addItem:[NSMenuItem separatorItem]];
  // 日志窗口入口
  NSMenuItem *logItem = [viewMenu addItemWithTitle:@"日志"
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

  // 初始化并重建"最近浏览"菜单
  NSLog(@"[PdfWinViewer] App start: will load settings.json and rebuild recent "
        @"menu");
  [self loadSettingsJSON];
  NSLog(@"[PdfWinViewer] Loaded settings: keys=%@", self.settingsDict.allKeys);
  [self extractRecentFromSettings];
  NSLog(@"[PdfWinViewer] extracted recent_paths count=%lu from settings",
        (unsigned long)self.recentPaths.count);
  [self rebuildRecentMenu];
  // 初始时禁用"导出"
  NSMenuItem *exp = [fileMenu itemWithTag:9901];
  if (exp)
    [exp setEnabled:NO];

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
                                        handler:^NSEvent *_Nullable(
                                            NSEvent *_Nonnull event) {
                                          return
                                              [self handleGlobalKeyDown:event];
                                        }];
  NSLog(@"[GlobalKey] 全局键盘事件监听已设置");
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
    (NSApplication *)sender {
  FPDF_DestroyLibrary();
  return NSTerminateNow;
}

#pragma mark - Global Keyboard Event Handling

- (NSEvent *)handleGlobalKeyDown:(NSEvent *)event {
  NSString *chars = [event charactersIgnoringModifiers];
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

  // 处理cmd+f查找功能
  if (c == 'f' && (mods & NSEventModifierFlagCommand)) {
    NSLog(@"[GlobalKey] 拦截到Cmd+F，显示查找面板");
    [self showFindPanel];
    return nil; // 消费事件
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
      return nil; // 消费事件，不再传递
    }
  }

  return event; // 其他键盘事件正常传递
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
    NSButton *findButton = [[NSButton alloc] initWithFrame:findButtonFrame];
    findButton.title = @"查找";
    findButton.target = self;
    findButton.action = @selector(performFind:);
    findButton.keyEquivalent = @"\r"; // Enter键

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
  NSString *searchTerm = self.findTextField.stringValue;
  if (!searchTerm || searchTerm.length == 0)
    return;

  // 检查检查器是否可见和可用
  if (!self.inspectorVisible || !self.inspectorTextView) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"查找提示";
    alert.informativeText = @"请先打开检查器窗口（右侧面板）";
    [alert addButtonWithTitle:@"确定"];
    [alert runModal];
    return;
  }

  NSString *inspectorText = self.inspectorTextView.string;
  if (!inspectorText || inspectorText.length == 0) {
    NSAlert *alert = [[NSAlert alloc] init];
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
- (void)showNotFoundAlert:(NSString *)searchTerm {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"查找结果";
  alert.informativeText =
      [NSString stringWithFormat:@"在检查器窗口中未找到文本: %@", searchTerm];
  [alert addButtonWithTitle:@"确定"];
  [alert runModal];
  NSLog(@"[Find] 在检查器中未找到文本: %@", searchTerm);
}

// 为对象引用着色的辅助方法
- (NSMutableAttributedString *)colorizeObjectReferences:(NSString *)text
                                            normalAttrs:
                                                (NSDictionary *)normalAttrs {
  NSMutableAttributedString *result =
      [[NSMutableAttributedString alloc] initWithString:text
                                             attributes:normalAttrs];

  // 创建绿色属性
  NSDictionary *greenAttrs = @{
    NSForegroundColorAttributeName : [NSColor systemGreenColor],
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12
                                                      weight:NSFontWeightBold]
  };

  // 查找所有对象引用（格式：数字 0 R）
  NSError *error = nil;
  NSRegularExpression *regex = [NSRegularExpression
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
                       usingBlock:^(NSTextCheckingResult *match,
                                    NSMatchingFlags flags, BOOL *stop) {
                         NSRange matchRange = [match range];
                         [result setAttributes:greenAttrs range:matchRange];
                       }];

  return result;
}

// PDF视图对象点击处理
- (void)pdfViewDidClickObject:(NSValue *)objectValue atIndex:(NSNumber *)index {
  NSLog(@"[Inspector] PDF视图点击了对象，索引: %@", index);

  // 从NSValue中提取FPDF_PAGEOBJECT
  FPDF_PAGEOBJECT object = (FPDF_PAGEOBJECT)[objectValue pointerValue];

  // 这里我们需要将FPDF_PAGEOBJECT映射到实际的PDF对象号
  // 由于这比较复杂，我们先简单地刷新检查器内容，然后尝试跳转到相关对象
  [self updateInspectorContent];

  // TODO: 实现更精确的对象映射和跳转
  NSLog(@"[Inspector] 已刷新检查器内容以响应PDF对象点击");
}

@end

#pragma mark - TOC (Outline)

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
    NSView *contentView = self.outlineScroll.contentView;
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
      NSScroller *vScroller = self.outlineScroll.verticalScroller;
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

    NSScroller *vScroller = self.outlineScroll.verticalScroller;
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
    NSScroller *vScroller = self.outlineScroll.verticalScroller;
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

  NSScroller *vScroller = self.outlineScroll.verticalScroller;
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

  NSScroller *vScroller = self.outlineScroll.verticalScroller;
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
    NSView *subview = self.leftPanel.subviews[i];
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
      self.leftPanel.bounds.size.width; // 使用实际面板宽度而不是常量
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
  for (NSView *subview in self.expandedTopControlBar.subviews) {
    if (subview.frame.size.height == 1) { // 分隔线
      NSRect separatorFrame = subview.frame;
      separatorFrame.size.width = expandedWidth;
      subview.frame = separatorFrame;
      NSLog(@"[ScrollDebug] 分隔线宽度已更新: %.1f", expandedWidth);
    } else if ([subview isKindOfClass:[NSButton class]]) {
      NSButton *button = (NSButton *)subview;
      if ([button.title isEqualToString:@"◀"]) { // 收起按钮
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

- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
  NSSplitView *splitView = (NSSplitView *)notification.object;
  
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

- (CGFloat)splitView:(NSSplitView *)splitView
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

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMaxCoordinate:(CGFloat)proposedMax
               ofSubviewAt:(NSInteger)dividerIndex {
  if (splitView == self.split) {
    if (dividerIndex == 0) {
      // 左侧面板最大宽度
      return kBookmarkExpandedWidth + 50; // 允许稍微超过标准宽度
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

- (BOOL)splitView:(NSSplitView *)splitView shouldAdjustSizeOfSubview:(NSView *)subview {
  // 如果是右侧检查器的 splitView，且检查器处于隐藏状态，不允许自动调整
  if (splitView.superview == self.rightPanel && subview == self.inspectorPanel && !self.inspectorVisible) {
    return NO;
  }
  // 对于其他情况，允许自动调整
  return YES;
}

// DataSource
- (NSInteger)outlineView:(NSOutlineView *)outlineView
    numberOfChildrenOfItem:(id)item {
  TocNode *n = item ?: self.tocRoot;
  return n ? (NSInteger)n.children.count : 0;
}
- (id)outlineView:(NSOutlineView *)outlineView
            child:(NSInteger)index
           ofItem:(id)item {
  TocNode *n = item ?: self.tocRoot;
  return (index >= 0 && index < (NSInteger)n.children.count)
             ? n.children[(NSUInteger)index]
             : nil;
}
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
  TocNode *n = (TocNode *)item;
  return n.children.count > 0;
}
- (NSView *)outlineView:(NSOutlineView *)outlineView
     viewForTableColumn:(NSTableColumn *)tableColumn
                   item:(id)item {
  NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"tocCell"
                                                        owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
    cell.identifier = @"tocCell";
    NSTextField *text = [[NSTextField alloc] initWithFrame:cell.bounds];
    text.bezeled = NO;
    text.drawsBackground = NO;
    text.editable = NO;
    text.selectable = NO;
    text.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cell.textField = text;
    [cell addSubview:text];
  }
  TocNode *n = (TocNode *)item;
  cell.textField.stringValue = n.title ?: @"";
  return cell;
}

// Delegate: 双击跳页
- (void)outlineView:(NSOutlineView *)outlineView
    didClickTableColumn:(NSTableColumn *)tableColumn {
}
- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
  NSInteger row = self.outline.selectedRow;
  if (row < 0)
    return;
  id item = [self.outline itemAtRow:row];
  TocNode *n = (TocNode *)item;
  if (n.pageIndex >= 0) {
    [self.view goToPage:n.pageIndex];
  }
}

// NSTextView点击处理
- (BOOL)textView:(NSTextView *)textView
    clickedOnLink:(id)link
          atIndex:(NSUInteger)charIndex {
  return NO; // 我们不使用链接，而是自定义处理
}

// 检查器文本视图点击处理
- (void)inspectorTextViewClicked:(NSClickGestureRecognizer *)recognizer {
  if (!self.inspectorTextView || !self.objectPositions)
    return;

  NSPoint clickPoint = [recognizer locationInView:self.inspectorTextView];

  // 获取点击位置的字符索引
  NSUInteger charIndex =
      [self.inspectorTextView characterIndexForInsertionAtPoint:clickPoint];
  NSString *text = self.inspectorTextView.string;

  NSLog(@"[Inspector] 点击位置: (%.1f, %.1f), 字符索引: %lu", clickPoint.x,
        clickPoint.y, charIndex);

  // 查找点击位置附近的对象引用（格式：数字 0 R）
  NSError *error = nil;
  NSRegularExpression *regex =
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
                       usingBlock:^(NSTextCheckingResult *match,
                                    NSMatchingFlags flags, BOOL *stop) {
                         NSRange matchRange = [match range];
                         NSLog(@"[Inspector] 找到匹配: %@, 范围: %@",
                               [text substringWithRange:matchRange],
                               NSStringFromRange(matchRange));

                         if (charIndex >= matchRange.location &&
                             charIndex <=
                                 matchRange.location + matchRange.length) {
                           NSString *objNumStr =
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
    NSString *objKey = [NSString stringWithFormat:@"%u", targetObjNum];
    NSNumber *position = [self.objectPositions objectForKey:objKey];
    NSLog(@"[Inspector] 查找对象 %u 的位置，映射表中有 %lu 个对象",
          targetObjNum, self.objectPositions.count);

    if (position) {
      NSUInteger targetPos = [position unsignedIntegerValue];
      NSRange targetRange = NSMakeRange(targetPos, 0);
      [self.inspectorTextView scrollRangeToVisible:targetRange];
      [self.inspectorTextView
          setSelectedRange:NSMakeRange(targetPos, 20)]; // 高亮显示更多字符
      NSLog(@"[Inspector] 成功跳转到对象 %u，位置：%lu", targetObjNum,
            targetPos);
    } else {
      NSLog(@"[Inspector] 未找到对象 %u 的位置信息", targetObjNum);
      // 打印所有可用的对象号
      NSArray *allKeys = [self.objectPositions.allKeys
          sortedArrayUsingSelector:@selector(compare:)];
      NSLog(@"[Inspector] 可用对象号: %@", allKeys);
    }
  } else {
    NSLog(@"[Inspector] 点击位置未找到对象引用");
  }
}

@end

#pragma mark - File menu actions

@implementation AppDelegate (FileActions)

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  if (menuItem.action == @selector(exportPNG:)) {
    BOOL enable = ([self.view document] != nullptr);
    NSLog(@"[PdfWinViewer][menu] validate exportPNG enable=%@",
          enable ? @"YES" : @"NO");
    return enable;
  }
  return YES;
}

- (IBAction)openDocument:(id)sender {
  NSLog(@"[PdfWinViewer] openDocument clicked");
  [NSApp activateIgnoringOtherApps:YES];
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  if (@available(macOS 12.0, *)) {
    panel.allowedContentTypes = @[ UTTypePDF ];
  } else {
    // 避免直接引用已废弃 API 引发告警，使用 KVC 设置
    [panel setValue:@[ @"pdf" ] forKey:@"allowedFileTypes"];
  }
  NSModalResponse resp = [panel runModal];
  NSLog(@"[PdfWinViewer] openPanel resp=%ld", (long)resp);
  if (resp == NSModalResponseOK) {
    NSString *path = panel.URL.path;
    NSLog(@"[PdfWinViewer] opening: %@", path);
    [self openPathAndAdjust:path];
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

#pragma mark - Recent menu

@implementation AppDelegate (Recent)

// 与 Windows 保持一致：统一使用 settings.json，包含 recent_files 数组
- (NSString *)settingsJSONPath {
  NSString *execPath = [[NSBundle mainBundle] executablePath];
  NSString *execDir = [execPath stringByDeletingLastPathComponent];
  NSString *path = [execDir stringByAppendingPathComponent:@"settings.json"];
  NSLog(@"[PdfWinViewer] settings.json path=%@", path);
  return path;
}

- (void)loadSettingsJSON {
  self.settingsDict = [NSMutableDictionary new];
  NSString *path = [self settingsJSONPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSLog(@"[PdfWinViewer] settings.json not found");
    return;
  }
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    NSLog(@"[PdfWinViewer] settings.json read failed");
    return;
  }
  NSError *err = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err || ![json isKindOfClass:[NSDictionary class]]) {
    NSLog(@"[PdfWinViewer] settings.json parse failed: %@", err);
    return;
  }
  self.settingsDict = [((NSDictionary *)json) mutableCopy];
  NSLog(@"[PdfWinViewer] settings loaded with %lu keys",
        (unsigned long)self.settingsDict.count);
}

- (void)saveSettingsJSON {
  if (!self.settingsDict)
    self.settingsDict = [NSMutableDictionary new];
  NSError *err = nil;
  NSData *data =
      [NSJSONSerialization dataWithJSONObject:self.settingsDict
                                      options:NSJSONWritingPrettyPrinted
                                        error:&err];
  if (err || !data) {
    NSLog(@"[PdfWinViewer] Failed to serialize settings.json: %@", err);
    return;
  }
  NSString *path = [self settingsJSONPath];
  BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&err];
  if (!ok || err)
    NSLog(@"[PdfWinViewer] Failed to write settings.json: %@", err);
  else
    NSLog(@"[PdfWinViewer] settings.json saved OK");
}

- (void)extractRecentFromSettings {
  self.recentPaths = [NSMutableArray new];
  id arr = self.settingsDict[@"recent_files"];
  if (![arr isKindOfClass:[NSArray class]]) {
    NSLog(@"[PdfWinViewer] settings has no recent_files (or wrong type)");
    return;
  }
  for (id item in (NSArray *)arr) {
    if ([item isKindOfClass:[NSString class]] &&
        [((NSString *)item) length] > 0) {
      if (![self.recentPaths containsObject:item])
        [self.recentPaths addObject:item];
      if (self.recentPaths.count >= 10)
        break;
    }
  }
  NSLog(@"[PdfWinViewer] recent_files loaded: %@", self.recentPaths);
}

- (void)persistRecentIntoSettings {
  if (!self.settingsDict)
    self.settingsDict = [NSMutableDictionary new];
  self.settingsDict[@"recent_files"] = [self.recentPaths copy];
  [self saveSettingsJSON];
}

- (void)openPathAndAdjust:(NSString *)path {
  if (path.length == 0)
    return;
  NSLog(@"[PdfWinViewer] openPathAndAdjust: %@", path);
  if ([self.view openPDFAtPath:path]) {
    NSLog(@"[StatusBar] PDF文件打开成功，准备更新状态栏");
    [self rebuildToc];
    [self.window makeFirstResponder:self.view];
    // 更新状态栏显示（确保状态栏已初始化）
    if (self.statusBar) {
      [self updateStatusBar];
    } else {
      NSLog(@"[StatusBar] 状态栏尚未初始化，跳过更新");
    }

    // 高亮当前书签
    [self highlightCurrentBookmark];
    // 根据文档页尺寸调整窗口适配（保持在屏幕可视范围内）
    NSSize s = [self.view currentPageSizePt];
    CGFloat newW = MIN(MAX(800, s.width + 300), 1600); // 预留左栏与边距
    CGFloat newH = MIN(MAX(600, s.height + 120), 1200);
    NSRect f = self.window.frame;
    f.size = NSMakeSize(newW, newH);
    [self.window setFrame:f display:YES animate:YES];
    // 更新窗口标题
    self.window.title = [NSString
        stringWithFormat:@"PdfWinViewer - %@", path.lastPathComponent];
    // 写入最近
    [self addRecentPath:path];
    NSLog(@"[PdfWinViewer] after addRecentPath, recent count=%lu",
          (unsigned long)self.recentPaths.count);
    // 启用"导出当前页为 PNG"
    NSMenu *fileMenu = [[[NSApp mainMenu] itemWithTitle:@"文件"] submenu];
    NSMenuItem *exp = [fileMenu itemWithTag:9901];
    if (exp)
      [exp setEnabled:YES];
  } else {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"无法打开 PDF";
    alert.informativeText = path ?: @"";
    [alert runModal];
  }
}

- (void)rebuildRecentMenu {
  if (!self.recentMenu)
    return;
  [self.recentMenu removeAllItems];
  NSUInteger count = self.recentPaths.count;
  NSLog(@"[PdfWinViewer] rebuildRecentMenu count=%lu", (unsigned long)count);
  if (count == 0) {
    NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"无最近项目"
                                                  action:nil
                                           keyEquivalent:@""];
    none.enabled = NO;
    [self.recentMenu addItem:none];
    self.recentMenuItem.enabled = NO;
    return;
  }
  self.recentMenuItem.enabled = YES;
  NSUInteger idx = 0;
  for (NSString *path in self.recentPaths) {
    NSLog(@"[PdfWinViewer] recent item %lu: %@", (unsigned long)idx, path);
    NSString *title =
        path.lastPathComponent.length ? path.lastPathComponent : path;
    // 带序号
    NSString *label =
        [NSString stringWithFormat:@"%lu. %@", (unsigned long)(idx + 1), title];
    NSMenuItem *it = [self.recentMenu addItemWithTitle:label
                                                action:@selector(openRecent:)
                                         keyEquivalent:@""];
    it.target = self;
    it.representedObject = path;
    idx++;
  }
  [self.recentMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *clear = [self.recentMenu addItemWithTitle:@"清空最近浏览"
                                                 action:@selector(clearRecent:)
                                          keyEquivalent:@""];
  clear.target = self;
}

- (void)addRecentPath:(NSString *)path {
  if (path.length == 0)
    return;
  if (!self.recentPaths)
    self.recentPaths = [NSMutableArray new];
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
  if (![sender isKindOfClass:[NSMenuItem class]])
    return;
  NSString *path = ((NSMenuItem *)sender).representedObject;
  NSLog(@"[PdfWinViewer] openRecent: %@", path);
  if (path.length == 0)
    return;
  BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
  if (!exists) {
    NSAlert *alert = [NSAlert new];
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

#pragma mark - 状态栏相关方法

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
  NSView *separator = [[NSView alloc] initWithFrame:NSMakeRect(0, 29, 800, 1)];
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

#pragma mark - 书签控制栏相关方法

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
      NSViewHeightSizable; // 只允许高度自适应，宽度固定

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
      @"▶"; // 右箭头表示可以展开（收起状态下显示）
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
  if (self.bookmarkVisible == visible)
    return; // 状态未改变

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
      self.bookmarkControlBar.hidden = YES; // 隐藏收起状态的控制栏
    } else {
      // 如果要收起，显示收起状态的控制栏
      self.bookmarkControlBar.hidden = NO;
    }

    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext *context) {
          context.duration = 0.25; // 动画持续时间
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
      self.bookmarkControlBar.hidden = YES; // 隐藏收起状态的控制栏
      // 立即更新控制栏布局
      [self updateExpandedControlBarLayout];
      NSLog(@"[BookmarkControl] 立即展开，隐藏收起状态控制栏");
    } else {
      [self removeExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = NO; // 显示收起状态的控制栏
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

- (TocNode *)findBookmarkForPage:(int)pageIndex inNode:(TocNode *)node {
  if (!node)
    return nil;

  NSLog(@"[BookmarkSearch] 搜索页面 %d，检查节点: %@ (页面: %d)", pageIndex,
        node.title, node.pageIndex);

  // 检查当前节点是否精确匹配
  if (node.pageIndex == pageIndex) {
    NSLog(@"[BookmarkSearch] 找到精确匹配: %@", node.title);
    return node;
  }

  // 查找最接近的书签（页面索引小于等于当前页面的最大值）
  TocNode *bestMatch = nil;
  if (node.pageIndex >= 0 && node.pageIndex <= pageIndex) {
    bestMatch = node;
    NSLog(@"[BookmarkSearch] 当前最佳匹配: %@ (页面: %d)", bestMatch.title,
          bestMatch.pageIndex);
  }

  // 递归搜索子节点
  for (TocNode *child in node.children) {
    TocNode *childMatch = [self findBookmarkForPage:pageIndex inNode:child];
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
  TocNode *targetBookmark = [self findBookmarkForPage:currentPage
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
          runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.3; // 平滑滚动动画
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

- (void)expandParentsOfItem:(TocNode *)item {
  if (!item || !self.tocRoot)
    return;

  // 查找item的父节点路径
  NSMutableArray *parentPath = [NSMutableArray array];
  [self findParentPathForItem:item inNode:self.tocRoot parentPath:parentPath];

  // 展开所有父节点
  for (TocNode *parent in parentPath) {
    if (parent != self.tocRoot) { // 不展开根节点
      [self.outline expandItem:parent];
      NSLog(@"[BookmarkHighlight] 展开父节点: %@", parent.title);
    }
  }
}

- (BOOL)findParentPathForItem:(TocNode *)targetItem
                       inNode:(TocNode *)currentNode
                   parentPath:(NSMutableArray *)path {
  if (!currentNode)
    return NO;

  // 将当前节点加入路径
  [path addObject:currentNode];

  // 检查是否找到目标项
  if (currentNode == targetItem) {
    return YES;
  }

  // 在子节点中搜索
  for (TocNode *child in currentNode.children) {
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
  self.bookmarkControlBar.alphaValue = 0.0;      // 完全透明
  [self.bookmarkControlBar removeFromSuperview]; // 临时从视图层次中移除

  // 创建顶部控制栏（包含标题、+/-按钮）
  CGFloat expandedWidth = self.leftPanel.bounds.size.width; // 使用实际面板宽度
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
  NSView *separator =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, expandedWidth, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable; // 分隔线随宽度自动调整
  [self.expandedTopControlBar addSubview:separator];

  // 添加标题标签
  NSTextField *titleLabel =
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
  NSButton *expandAllButton =
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
  NSButton *collapseAllButton =
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
  NSButton *collapseButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(buttonX, yCenter, buttonWidth, buttonHeight)];
  collapseButton.title = @"◀"; // 左箭头表示可以收起
  collapseButton.font = [NSFont systemFontOfSize:10];
  collapseButton.bordered = NO;
  collapseButton.target = self;
  collapseButton.action = @selector(toggleBookmarkVisibility:);
  collapseButton.autoresizingMask = NSViewMinXMargin; // 右对齐，随面板宽度调整
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

    [self forceTraditionalScrollBar]; // 强制使用传统滚动条
    [self updateBookmarkScrollView];
    [self ensureBookmarkScrollBarVisible];
    [self checkScrollBarOverlap]; // 检查滚动条是否被遮挡
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
  self.bookmarkControlBar.alphaValue = 1.0; // 恢复不透明

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
    int currentPage = [self.view currentPageIndex] + 1; // 显示从1开始的页码
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
  } @catch (NSException *exception) {
    NSLog(@"[StatusBar] 异常: %@", exception);
  }
}

- (void)onPrevPage:(id)sender {
  if (!self.view || ![self.view document])
    return;
  int currentPage = [self.view currentPageIndex];
  if (currentPage > 0) {
    [self.view goToPage:currentPage - 1];
    [self updateStatusBar];
  }
}

- (void)onNextPage:(id)sender {
  if (!self.view || ![self.view document])
    return;
  int totalPages = FPDF_GetPageCount([self.view document]);
  int currentPage = [self.view currentPageIndex];
  if (currentPage < totalPages - 1) {
    [self.view goToPage:currentPage + 1];
    [self updateStatusBar];
  }
}

- (void)onPageInputChanged:(id)sender {
  if (!self.view || ![self.view document])
    return;

  NSString *input = self.pageInput.stringValue;
  int pageNum = [input intValue];
  int totalPages = FPDF_GetPageCount([self.view document]);

  // 边界检查：确保页码在有效范围内
  int validPageNum = pageNum;
  if (pageNum < 1) {
    validPageNum = 1; // 小于最小值时使用最小值
    NSLog(@"[PageNavigation] 状态栏输入页码%d小于1，调整为最小值: %d", pageNum,
          validPageNum);
  } else if (pageNum > totalPages) {
    validPageNum = totalPages; // 大于最大值时使用最大值
    NSLog(@"[PageNavigation] 状态栏输入页码%d超过最大值%d，调整为最大值: %d",
          pageNum, totalPages, validPageNum);
  }

  // 应用有效的页码
  [self.view goToPage:validPageNum - 1]; // 转换为0开始的索引
  NSLog(@"[PageNavigation] 状态栏页码设置为: %d (索引: %d)", validPageNum,
        validPageNum - 1);
  [self updateStatusBar];
}

#pragma mark - PdfViewDelegate

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

#pragma mark - 检查器面板相关方法

- (void)createInspectorPanel {
  NSLog(@"[Inspector] 开始创建检查器面板");

  // 创建检查器面板容器
  self.inspectorPanel = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, kInspectorWidth,
                               self.rightPanel.bounds.size.height)];
  self.inspectorPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.inspectorPanel.wantsLayer = YES;
  self.inspectorPanel.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];

  // 添加标题栏
  NSView *titleBar = [[NSView alloc]
      initWithFrame:NSMakeRect(0,
                               self.inspectorPanel.bounds.size.height -
                                   kControlBarHeight,
                               kInspectorWidth, kControlBarHeight)];
  titleBar.wantsLayer = YES;
  titleBar.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
  titleBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

  // 添加标题
  NSTextField *titleLabel =
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
  NSButton *collapseButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(kInspectorWidth - 30, 5, 20, 20)];
  collapseButton.title = @"◀";
  collapseButton.font = [NSFont systemFontOfSize:10];
  collapseButton.bordered = NO;
  collapseButton.target = self;
  collapseButton.action = @selector(toggleInspectorVisibility:);
  collapseButton.autoresizingMask = NSViewMinXMargin;
  [titleBar addSubview:collapseButton];

  // 添加底部分隔线
  NSView *separator =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kInspectorWidth, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable;
  [titleBar addSubview:separator];

  [self.inspectorPanel addSubview:titleBar];

  // 创建文本视图用于显示页面信息
  NSRect textFrame =
      NSMakeRect(0, 0, kInspectorWidth,
                 self.inspectorPanel.bounds.size.height - kControlBarHeight);
  self.inspectorTextView = [[NSTextView alloc] initWithFrame:textFrame];
  self.inspectorTextView.editable = NO;
  self.inspectorTextView.selectable = YES;

  // 初始化对象位置映射
  self.objectPositions = [[NSMutableDictionary alloc] init];
  self.inspectorTextView.delegate = self; // 设置代理以处理点击事件
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
  self.inspectorTextView.horizontallyResizable = NO; // 禁用水平调整
  self.inspectorTextView.verticallyResizable = YES;  // 启用垂直调整

  // 添加鼠标点击事件监听
  NSClickGestureRecognizer *clickGesture = [[NSClickGestureRecognizer alloc]
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
  if (self.inspectorVisible == visible)
    return; // 状态未改变

  self.inspectorVisible = visible;
  NSLog(@"[Inspector] 设置检查器可见性: %@", visible ? @"显示" : @"隐藏");

  // 更新按钮文本
  // 检查器隐藏时显示◀（表示点击打开右侧窗口），检查器显示时显示▶（表示点击关闭右侧窗口）
  self.inspectorToggleButton.title = visible ? @"▶" : @"◀";

  // 获取右侧分割视图
  NSSplitView *rightSplit = (NSSplitView *)self.rightPanel.subviews.firstObject;
  if (![rightSplit isKindOfClass:[NSSplitView class]])
    return;

  // 使用 NSSplitView 的折叠功能来完全收起/展开面板
  // inspectorPanel 是第二个子视图（index 1）
  BOOL inspectorAttached = [rightSplit.subviews containsObject:self.inspectorPanel];

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

    NSLog(@"[Inspector] 检查器面板展开，frame: %@", NSStringFromRect(self.inspectorPanel.frame));

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

    NSLog(@"[Inspector] 检查器收起完成，pdfContentView frame: %@, inspectorPanel frame: %@, 按钮 frame: %@",
          NSStringFromRect(self.pdfContentView.frame),
          NSStringFromRect(self.inspectorPanel.frame),
          NSStringFromRect(self.inspectorToggleButton.frame));
  }
}

- (void)updateInspectorLayout {
  if (!self.inspectorVisible || !self.inspectorTextView)
    return;

  // 更新文本容器大小以适应窗口变化
  NSRect currentFrame = self.inspectorScrollView.frame;
  CGFloat newWidth = currentFrame.size.width - 20; // 减去滚动条和边距

  self.inspectorTextView.textContainer.containerSize =
      NSMakeSize(newWidth, CGFLOAT_MAX);
  [self.inspectorTextView setNeedsDisplay:YES];

  NSLog(@"[Inspector] 文本容器宽度已更新为: %.1f", newWidth);
}

// 递归显示对象树节点
- (void)displayObjectTreeNode:(PDFIUM_EX_OBJECT_TREE_NODE *)node
             attributedString:(NSMutableAttributedString *)attributedInfo
                  normalAttrs:(NSDictionary *)normalAttrs
                  objNumAttrs:(NSDictionary *)objNumAttrs {
  if (!node || !attributedInfo || !normalAttrs || !objNumAttrs)
    return;

  // 安全检查：防止递归过深
  if (node->depth > 10) {
    NSString *warningStr = [NSString
        stringWithFormat:@"[警告] 对象 %u 递归深度过深，已停止展开\n\n",
                         node->obj_num];
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:warningStr
                                                   attributes:normalAttrs]];
    return;
  }

  // 记录对象在文本中的位置（用于点击跳转）
  NSUInteger objStartPosition = attributedInfo.length;
  NSString *objKey = [NSString stringWithFormat:@"%u", node->obj_num];
  [self.objectPositions setObject:@(objStartPosition) forKey:objKey];

  // 显示对象号（天空蓝色）
  NSString *objNumStr =
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
    NSString *contentStr = [NSString stringWithUTF8String:node->raw_content];
    if (contentStr && contentStr.length > 0) {
      // 创建带颜色的内容字符串，将对象引用标记为绿色
      NSMutableAttributedString *coloredContent =
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
  if (node->children && node->child_count > 0 &&
      node->child_count < 200) { // 增加子节点数量限制
    for (int i = 0; i < node->child_count; i++) {
      if (node->children[i]) {
        [self displayObjectTreeNode:node->children[i]
                   attributedString:attributedInfo
                        normalAttrs:normalAttrs
                        objNumAttrs:objNumAttrs];
      }
    }
  }
}

- (void)updateInspectorContent {
  if (!self.inspectorVisible || !self.inspectorTextView || !self.view)
    return;

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

  // 获取页面对象数量
  int objectCount = FPDFPage_CountObjects(page);

  // 构建带颜色的属性文本
  NSMutableAttributedString *attributedInfo =
      [[NSMutableAttributedString alloc] init];

  // 基础文本属性
  NSDictionary *normalAttrs = @{
    NSForegroundColorAttributeName : [NSColor textColor],
    NSFontAttributeName :
        [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
  };

  // 天空蓝色对象号属性
  NSDictionary *objNumAttrs = @{
    NSForegroundColorAttributeName : [NSColor systemBlueColor],
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12
                                                      weight:NSFontWeightBold]
  };

  // 添加基础信息
  NSString *basicInfo = [NSString
      stringWithFormat:@"PDF 文档信息\n================\n\n当前页面: %d / "
                       @"%d\n页面尺寸: %.2f x %.2f pt\n页面对象数: "
                       @"%d\n\nPDF对象引用树\n================\n",
                       currentPage + 1, totalPages, pageWidth, pageHeight,
                       objectCount];
  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:basicInfo
                                                 attributes:normalAttrs]];

  // 清空对象位置映射
  [self.objectPositions removeAllObjects];

  // 构建PDF对象引用树
  // Note: Object tree functionality is not fully implemented yet
  PDFIUM_EX_OBJECT_TREE_NODE *object_tree =
      PdfiumEx_BuildObjectTree(doc, page, 1000000); // 最大深度5层，支持完整分析

  if (object_tree) {
    // 递归显示树结构
    [self displayObjectTreeNode:object_tree
               attributedString:attributedInfo
                    normalAttrs:normalAttrs
                    objNumAttrs:objNumAttrs];

    PdfiumEx_ReleaseObjectTree(object_tree);
  } else {
    // 如果对象树不可用，显示提示信息
    NSString *treeInfo = @"\n注意: PDF对象引用树功能暂未实现\n";
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
- (void)handleShowWindowNotification:(NSNotification *)notification {
  NSLog(@"[PdfWinViewer] 收到显示窗口通知，激活应用并显示窗口");
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp activateIgnoringOtherApps:YES];
    if (self.window) {
      [self.window makeKeyAndOrderFront:nil];
      [self.window orderFrontRegardless];
    }
  });
}

// 当最后一个窗口关闭时退出应用
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // 检查是否已有实例运行
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    NSArray<NSRunningApplication *> *runningApps = 
        [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
    
    // 获取当前进程 ID
    pid_t currentPID = [NSProcessInfo processInfo].processIdentifier;
    
    // 检查是否有其他实例运行（排除当前进程）
    NSRunningApplication *existingApp = nil;
    for (NSRunningApplication *app in runningApps) {
      if (app.processIdentifier != currentPID) {
        existingApp = app;
        break;
      }
    }
    
    // 如果已有其他实例运行，激活它并退出
    if (existingApp) {
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
    
    NSApplication *app = [NSApplication sharedApplication];
    
    // 设置为前台应用（非后台应用）
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    
    AppDelegate *del = [AppDelegate new];
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
