//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "LogManager.h"
#include <cwchar>

@implementation _LogWindowController
- (instancetype)init {
  NSRect rc = NSMakeRect(200, 200, 900, 600);
  NSWindow* w = [[NSWindow alloc]
      initWithContentRect:rc
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  if (self = [super initWithWindow:w]) {
    w.delegate = (id<NSWindowDelegate>)self;
    self.rows = [NSMutableArray new];
    NSView* c = w.contentView;
    NSButton* en = [NSButton checkboxWithTitle:@"Enable logging"
                                        target:self
                                        action:@selector(onToggle:)];
    en.frame = NSMakeRect(12, rc.size.height - 36, 140, 24);
    [c addSubview:en];
    self.enableButton = en;
    NSButton* cl = [NSButton buttonWithTitle:@"Clear"
                                      target:self
                                      action:@selector(onClear:)];
    cl.frame = NSMakeRect(160, rc.size.height - 36, 80, 24);
    [c addSubview:cl];
    self.clearButton = cl;
    // 过滤按钮
    NSPopUpButton* filt = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(250, rc.size.height - 36, 160, 24)
            pullsDown:NO];
    [filt addItemsWithTitles:@[ @"All", @"Debug", @"Perf" ]];
    [filt setTarget:self];
    [filt setAction:@selector(onFilter:)];
    [c addSubview:filt];
    _filter = filt;

    NSScrollView* sv =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, rc.size.width - 16,
                                                       rc.size.height - 56)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTableView* tv = [[NSTableView alloc] initWithFrame:sv.bounds];
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.delegate = self;
    tv.dataSource = self;
    auto addCol = ^(NSString* idt, NSString* title, CGFloat w) {
      NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:idt];
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

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
  if (_filter.indexOfSelectedItem == 0) {
    return (NSInteger)self.rows.count;
  }
  NSString* key =
      (_filter.indexOfSelectedItem == 1) ? @"Debug:跟踪" : @"Debug:渲染性能";
  __block NSInteger cnt = 0;
  [self.rows enumerateObjectsUsingBlock:^(NSDictionary* _Nonnull d,
                                          NSUInteger idx, BOOL* _Nonnull stop) {
    if ([d[@"Level"] isEqualToString:key]) {
      ++cnt;
    }
  }];
  return cnt;
}
- (NSView*)tableView:(NSTableView*)tableView
    viewForTableColumn:(NSTableColumn*)tableColumn
                   row:(NSInteger)row {
  NSTableCellView* cell =
      [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
    cell.identifier = tableColumn.identifier;
    NSTextField* tf = [[NSTextField alloc] initWithFrame:cell.bounds];
    tf.bezeled = NO;
    tf.drawsBackground = NO;
    tf.editable = NO;
    tf.selectable = NO;
    tf.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cell.textField = tf;
    [cell addSubview:tf];
  }
  // 简单过滤：重新选择时 table 会刷新，这里按顺序取匹配项
  NSDictionary* d = nil;
  if (_filter.indexOfSelectedItem == 0) {
    d = self.rows[(NSUInteger)row];
  } else {
    NSString* key =
        (_filter.indexOfSelectedItem == 1) ? @"Debug:跟踪" : @"Debug:渲染性能";
    NSInteger idx = -1;
    for (NSDictionary* it in self.rows) {
      if ([it[@"Level"] isEqualToString:key]) {
        ++idx;
        if (idx == row) {
          d = it;
          break;
        }
      }
    }
    if (!d) {
      d = @{};
    }
  }
  cell.textField.stringValue = d[tableColumn.identifier] ?: @"";
  return cell;
}

- (void)appendRow:(NSDictionary*)row {
  [self.rows addObject:row];
  [self.table reloadData];
  NSInteger last = (NSInteger)self.rows.count - 1;
  if (last >= 0) {
    [self.table scrollRowToVisible:last];
  }
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
- (void)windowWillClose:(NSNotification*)notification {
  MacLog_SetEnabled(false);
  _gLogCtrl = nil;
}
@end

// 默认启用日志记录（性能日志总是记录到文件，窗口显示可选）
static bool& _LogEnabledRef() {
  static bool e = true;  // 改为默认启用
  return e;
}

bool MacLog_IsEnabled() {
  return _LogEnabledRef();
}
void MacLog_SetEnabled(bool on) {
  _LogEnabledRef() = on;
}
void MacLog_ShowWindow() {
  if (!_gLogCtrl) {
    _gLogCtrl = [_LogWindowController new];
  }
  [_gLogCtrl showWindow:nil];
  _gLogCtrl.enableButton.state =
      MacLog_IsEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

static inline NSString* WFormat(const wchar_t* fmt, va_list ap) {
  wchar_t buf[1200];
  vswprintf(buf, 1199, fmt, ap);
  buf[1199] = 0;
  return [[NSString alloc] initWithCharacters:(const unichar*)buf
                                       length:wcslen(buf)];
}

static inline NSString* ToNSString(double v, int prec) {
  return [NSString
      stringWithFormat:(prec >= 0 ? [NSString stringWithFormat:@"%%.%df", prec]
                                  : @"%f"),
                       v];
}
static inline NSString* ToNSStringI(int v) {
  return [NSString stringWithFormat:@"%d", v];
}

double _lastMemMB = 0.0;
double _openStartSec = 0.0;
bool _firstRenderAfterOpen = false;
// 文件日志：路径与句柄
static NSString* MacLog_FilePath() {
  NSString* exec = [[NSBundle mainBundle] executablePath];
  NSString* dir = [exec stringByDeletingLastPathComponent];
  return [dir stringByAppendingPathComponent:@"debug.log"];
}
void MacLog_ResetFileOnStartup() {
  NSString* path = MacLog_FilePath();
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void MacLog_AppendLine(NSString* line) {
  if (!line) {
    return;
  }
  NSString* s = [line stringByAppendingString:@"\n"];
  NSData* data = [s dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle* fh =
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
void MacLog_DebugNS(NSString* msg) {
  if (!msg) {
    return;
  }
  MacLog_AppendLine([@"[DBG] " stringByAppendingString:msg]);
}

void Log_WriteF(LogLevel lv, const wchar_t* fmt, ...) {
#if PDFWV_ENABLE_LOGGING
  if (!MacLog_IsEnabled()) {
    return;
  }
  va_list ap;
  va_start(ap, fmt);
  NSString* msg = WFormat(fmt, ap);
  va_end(ap);
  double el = NowSeconds();
  MacLog_AppendLine(
      [NSString stringWithFormat:@"[DBG] [+%7.3fs] %@", el, msg ?: @""]);
  if (_gLogCtrl) {
    NSDictionary* row = @{
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

void Log_WritePerfEx(int page,
                     double zoomPct,
                     double timeMs,
                     double memMB,
                     double deltaMB,
                     const wchar_t* remarks,
                     const char* file,
                     int line,
                     const char* func) {
#if PDFWV_ENABLE_LOGGING
  if (!MacLog_IsEnabled()) {
    return;
  }
  double el = NowSeconds();
  NSString* lvl = @"Debug:渲染性能";
  NSString* zoom = [NSString stringWithFormat:@"%.0f%%", zoomPct];
  NSString* tms = ToNSString(timeMs, 2);
  NSString* mem = ToNSString(memMB, 2);
  NSString* dmem = ToNSString(deltaMB, 2);
  NSString* src = [NSString
      stringWithFormat:@"%s:%d %s", file ? file : "", line, func ? func : ""];
  NSString* rem = [NSString
      stringWithFormat:@"%@%@%s", NSStringFromWChar(remarks),
                       (remarks && remarks[0] ? @" | " : @""), src.UTF8String];
  MacLog_AppendLine([NSString
      stringWithFormat:@"[PERF] [+%7.3fs] p=%d z=%@ t=%@ mem=%@ dmem=%@ | %@",
                       el, page, zoom, tms, mem, dmem, rem]);
  if (_gLogCtrl) {
    NSDictionary* row = @{
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

void Log_WritePerf(int page,
                   double zoomPct,
                   double timeMs,
                   double memMB,
                   double deltaMB) {
  Log_WritePerfEx(page, zoomPct, timeMs, memMB, deltaMB, L"渲染单页统计",
                  __FILE__, __LINE__, __FUNCTION__);
}
