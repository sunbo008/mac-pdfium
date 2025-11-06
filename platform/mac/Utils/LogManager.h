//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <cwchar>

// ================= 日志子系统（与 Windows 对齐） =================
#if !defined(PDFWV_ENABLE_LOGGING)
#define PDFWV_ENABLE_LOGGING 1
#endif

enum class LogLevel { Critical, Error, Warning, Debug, Trace };

static inline double NowSeconds() {
  static double sStart = 0.0;
  double t = CFAbsoluteTimeGetCurrent();
  if (sStart == 0.0) {
    sStart = t;
  }
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
static inline NSString* NSStringFromWChar(const wchar_t* ws) {
  if (!ws) {
    return @"";
  }
  size_t len = wcslen(ws);
  if (len == 0) {
    return @"";
  }
  CFStringRef cfs = nullptr;
  if (sizeof(wchar_t) == 4) {
    cfs = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8*)ws,
                                  (CFIndex)(len * 4), kCFStringEncodingUTF32LE,
                                  false);
  } else {
    cfs = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8*)ws,
                                  (CFIndex)(len * 2), kCFStringEncodingUTF16LE,
                                  false);
  }
  return CFBridgingRelease(cfs);
}

// 提前定义全局日志窗口指针，供窗口委托关闭时访问
@class _LogWindowController;
static _LogWindowController* _gLogCtrl = nil;

@interface _LogWindowController : NSWindowController <NSTableViewDataSource,
                                                      NSTableViewDelegate,
                                                      NSWindowDelegate>
@property(nonatomic, strong) NSButton* enableButton;
@property(nonatomic, strong) NSButton* clearButton;
@property(nonatomic, strong) NSTableView* table;
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* rows;
@property(nonatomic, strong) NSPopUpButton* filter;
// NSWindowDelegate
- (void)windowWillClose:(NSNotification*)notification;
@end

// 前向声明内部日志开关函数，避免在方法体里临时 extern 声明
bool MacLog_IsEnabled();
void MacLog_SetEnabled(bool on);

// 公共日志函数
void MacLog_ShowWindow();
void Log_WriteF(LogLevel lv, const wchar_t* fmt, ...);
void Log_WritePerfEx(int page,
                     double zoomPct,
                     double timeMs,
                     double memMB,
                     double deltaMB,
                     const wchar_t* remarks,
                     const char* file,
                     int line,
                     const char* func);
void Log_WritePerf(int page,
                   double zoomPct,
                   double timeMs,
                   double memMB,
                   double deltaMB);

// 日志宏
#if PDFWV_ENABLE_LOGGING
#define LOGF(lv, fmt, ...)                     \
  do {                                         \
    if (MacLog_IsEnabled())                    \
      Log_WriteF((lv), L##fmt, ##__VA_ARGS__); \
  } while (0)
#define LOGM(lv, msg)                  \
  do {                                 \
    if (MacLog_IsEnabled())            \
      Log_WriteF((lv), L"%s", L##msg); \
  } while (0)
#else
#define LOGF(...) \
  do {            \
  } while (0)
#define LOGM(...) \
  do {            \
  } while (0)
#endif

inline void Log_ShowWindow() {
  MacLog_ShowWindow();
}

// 文件日志相关函数
void MacLog_ResetFileOnStartup();
void MacLog_DebugNS(NSString* msg);

// LOG_TAG_NS 宏定义 - 用于带标签的调试日志
#if PDFWV_ENABLE_LOGGING
#define LOG_TAG_NS(tag, fmt, ...) \
  do { \
    if (MacLog_IsEnabled()) { \
      NSString* _taggedMsg = [NSString stringWithFormat:@"[%s] " fmt, tag, ##__VA_ARGS__]; \
      MacLog_DebugNS(_taggedMsg); \
    } \
  } while (0)
#else
#define LOG_TAG_NS(...) do { } while (0)
#endif

// 全局变量声明
extern double _lastMemMB;
extern double _openStartSec;
extern bool _firstRenderAfterOpen;
