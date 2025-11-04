# 全局日志模块

> 为 PdfWinViewer macOS 应用设计的全局日志系统，将日志保存到应用目录下

## 文件说明

- `platform/shared/logger.h` / `logger.cpp` - 核心实现
- `platform/shared/logger_example.cpp` - 使用示例
- `platform/shared/logger_test.cpp` - 测试程序
- `platform/shared/logger_standalone_build.sh` - 独立构建脚本
- `platform/mac/LoggerHelper.h` / `LoggerHelper.mm` - Objective-C++ 包装类

---

## 目录

- [快速开始](#快速开始)
- [核心功能](#核心功能)
- [API 参考](#api-参考)
- [使用示例](#使用示例)
- [集成指南](#集成指南)
- [配置说明](#配置说明)
- [最佳实践](#最佳实践)
- [常见问题](#常见问题)

---

## 快速开始

### 1. 初始化日志系统

在应用启动时（`main` 函数中）初始化：

```objc
#include "platform/shared/logger.h"

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // 获取应用路径
    NSString* execPath = [[NSBundle mainBundle] executablePath];
    std::string app_path = [execPath UTF8String];
    
    // 初始化日志系统
    pdfium_viewer::Logger::GetInstance().Initialize(app_path);
    
    LOG_INFO("应用程序已启动");
    
    // 应用其他代码...
  }
}
```

### 2. 记录日志

```cpp
// 基本日志
LOG_INFO("应用程序已启动");
LOG_DEBUG("调试信息");
LOG_ERROR("错误信息");

// 格式化日志
int page = 5;
LOG_INFO_F("打开页面 %d", page);

// 中文日志（宽字符）
LOG_INFO_W(L"加载文件：%s", L"测试文档.pdf");

// 性能日志
LOG_PERF(page, zoom, time_ms, mem_mb, delta_mb, "页面渲染");
```

### 3. 查看日志

日志文件位置：
```
PdfWinViewer.app/Contents/MacOS/debug.log
```

---

## 核心功能

### 日志级别

| 级别 | 宏 | 说明 |
|------|---|------|
| TRACE | `LOG_TRACE` | 详细跟踪信息 |
| DEBUG | `LOG_DEBUG` | 调试信息 |
| INFO | `LOG_INFO` | 一般信息（推荐） |
| WARNING | `LOG_WARNING` | 警告信息 |
| ERROR | `LOG_ERROR` | 错误信息 |
| CRITICAL | `LOG_CRITICAL` | 严重错误 |

### 主要特性

- ✅ **多级别日志** - 6 个日志级别，可配置过滤
- ✅ **线程安全** - 使用 `std::mutex` 保证多线程安全
- ✅ **自动轮转** - 单文件 10MB，自动保留最近 5 个文件
- ✅ **性能日志** - 专门的性能监控接口
- ✅ **时间戳** - 毫秒级精度，包含绝对时间和相对时间
- ✅ **源码定位** - 自动记录文件名、行号、函数名
- ✅ **宽字符支持** - 完美支持中文
- ✅ **零依赖** - 仅依赖 C++ 标准库

### 日志格式

```
[级别] [时间戳] [相对时间] [文件:行号] [函数] 消息
```

示例：
```
[INFO ] [2024-11-03 10:30:45.123] [+0.123s] [App.mm:45] [main] 应用程序已启动
[DEBUG] [2024-11-03 10:30:45.456] [+0.456s] [App.mm:123] [openDocument:] 正在打开文件
[PERF] [+1.234s] Page=5 Zoom=150% Time=123.45ms Mem=256.78MB DeltaMem=12.34MB | 页面渲染完成
```

---

## API 参考

### 初始化和配置

```cpp
// 获取单例实例
Logger& logger = Logger::GetInstance();

// 初始化日志系统
logger.Initialize(
    const std::string& app_path,        // 应用程序路径
    size_t max_file_size = 10485760,    // 最大文件大小（默认 10MB）
    int max_file_count = 5               // 保留文件数量（默认 5）
);

// 设置日志级别
logger.SetLevel(LogLevel::DEBUG);

// 启用/禁用日志
logger.SetEnabled(true);

// 启用/禁用控制台输出
logger.SetConsoleOutput(true);

// 获取日志文件路径
std::string path = logger.GetLogFilePath();

// 清空日志文件
logger.ClearLog();

// 刷新缓冲区
logger.Flush();
```

### 日志记录宏

#### 基本日志
```cpp
LOG_TRACE(message)
LOG_DEBUG(message)
LOG_INFO(message)
LOG_WARNING(message)
LOG_ERROR(message)
LOG_CRITICAL(message)
```

#### 格式化日志
```cpp
LOG_TRACE_F(format, ...)
LOG_DEBUG_F(format, ...)
LOG_INFO_F(format, ...)
LOG_WARNING_F(format, ...)
LOG_ERROR_F(format, ...)
LOG_CRITICAL_F(format, ...)
```

#### 宽字符日志
```cpp
LOG_TRACE_W(wformat, ...)
LOG_DEBUG_W(wformat, ...)
LOG_INFO_W(wformat, ...)
LOG_WARNING_W(wformat, ...)
LOG_ERROR_W(wformat, ...)
LOG_CRITICAL_W(wformat, ...)
```

#### 性能日志
```cpp
LOG_PERF(page, zoom, time_ms, mem_mb, delta_mb, remarks)
```

### Objective-C 包装类（可选）

```objc
#import "platform/mac/LoggerHelper.h"

// 初始化
[LoggerHelper initialize];

// 设置日志级别（0-5）
[LoggerHelper setLogLevel:2];  // INFO

// 记录日志
[LoggerHelper logInfo:@"应用启动"];
[LoggerHelper logError:@"发生错误"];

// 性能日志
[LoggerHelper logPerf:page zoom:zoom timeMS:time memMB:mem deltaMem:delta remarks:@"渲染"];

// 查看日志文件
[LoggerHelper revealLogFileInFinder];

// 清空日志
[LoggerHelper clearLog];
```

---

## 使用示例

### 示例 1：应用启动和关闭

```objc
@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  LOG_INFO("========================================");
  LOG_INFO("Application did finish launching");
  LOG_INFO_F("Version: %s", "1.0.0");
  LOG_INFO("========================================");
  
  [self setupUI];
  [self loadSettings];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  LOG_INFO("Application will terminate");
  [self saveSettings];
  pdfium_viewer::Logger::GetInstance().Flush();
  LOG_INFO("Application terminated gracefully");
}

@end
```

### 示例 2：打开 PDF 文件

```objc
- (void)openPDFFile:(NSString *)path {
    LOG_INFO_F("用户请求打开文件：%s", [path UTF8String]);
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        LOG_ERROR_F("文件不存在：%s", [path UTF8String]);
        [self showErrorAlert:@"文件不存在"];
        return;
    }
    
    @try {
        // 打开文件逻辑...
        LOG_INFO("PDF 文件打开成功");
    }
    @catch (NSException *exception) {
        LOG_ERROR_F("打开文件失败：%s - %s",
                    [exception.name UTF8String],
                    [exception.reason UTF8String]);
        [self showErrorAlert:@"打开文件失败"];
    }
}
```

### 示例 3：页面渲染和性能监控

```objc
- (void)renderPage:(int)pageNum {
    auto start = std::chrono::steady_clock::now();
    double mem_before = GetProcessMemMB();
    
    LOG_DEBUG_F("开始渲染第 %d 页", pageNum);
    
    // 渲染代码...
    
    auto end = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double, std::milli>(end - start).count();
    double mem_after = GetProcessMemMB();
    double delta = mem_after - mem_before;
    
    LOG_PERF(pageNum, self.zoom, elapsed, mem_after, delta, "页面渲染");
    
    if (elapsed > 1000.0) {
        LOG_WARNING_F("页面渲染耗时过长：%.2f ms", elapsed);
    }
}
```

### 示例 4：错误处理

```objc
- (BOOL)exportPageToPNG:(int)page path:(NSString *)path {
    LOG_INFO_F("导出页面 %d 到 PNG: %s", page, [path UTF8String]);
    
    @try {
        // 导出逻辑...
        LOG_INFO("PNG 导出成功");
        return YES;
    }
    @catch (NSException *ex) {
        LOG_ERROR_F("PNG 导出失败: %s", [ex.reason UTF8String]);
        return NO;
    }
}
```

---

## 集成指南

### 步骤 1：在 App.mm 中初始化

```objc
#include "platform/shared/logger.h"

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // 初始化日志系统
    NSString* execPath = [[NSBundle mainBundle] executablePath];
    std::string app_path = [execPath UTF8String];
    
    pdfium_viewer::Logger::GetInstance().Initialize(app_path);
    pdfium_viewer::Logger::GetInstance().SetLevel(pdfium_viewer::LogLevel::DEBUG);
    
    #ifdef DEBUG
    pdfium_viewer::Logger::GetInstance().SetConsoleOutput(true);
    #endif
    
    LOG_INFO("PdfWinViewer Application Starting");
    
    // 原有代码...
    NSApplication *app = [NSApplication sharedApplication];
    AppDelegate *del = [AppDelegate new];
    app.delegate = del;
    [app run];
  }
  return 0;
}
```

### 步骤 2：在代码中使用

在任何需要记录日志的地方：

```cpp
#include "platform/shared/logger.h"

void MyFunction() {
  LOG_INFO("Function called");
  LOG_DEBUG_F("Processing %d items", count);
}
```

### 步骤 3：添加日志菜单（可选）

```objc
- (void)buildMenu {
  // 添加调试菜单
  NSMenuItem *debugMenu = [[NSMenuItem alloc] initWithTitle:@"调试" action:nil keyEquivalent:@""];
  NSMenu *debugSubmenu = [[NSMenu alloc] initWithTitle:@"调试"];
  
  // 显示日志文件
  NSMenuItem *showLogItem = [[NSMenuItem alloc] initWithTitle:@"显示日志文件"
                                                      action:@selector(showLogFile:)
                                               keyEquivalent:@"L"];
  [showLogItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
  [debugSubmenu addItem:showLogItem];
  
  debugMenu.submenu = debugSubmenu;
  [mainMenu addItem:debugMenu];
}

- (void)showLogFile:(id)sender {
  std::string log_path = pdfium_viewer::Logger::GetInstance().GetLogFilePath();
  NSString *path = [NSString stringWithUTF8String:log_path.c_str()];
  [[NSWorkspace sharedWorkspace] selectFile:path
                   inFileViewerRootedAtPath:[path stringByDeletingLastPathComponent]];
}
```

### 构建配置

已在 BUILD.gn 中配置：

**platform/shared/BUILD.gn**:
```gn
source_set("logger") {
  sources = ["logger.cpp", "logger.h"]
  configs += ["//:pdfium_strict_config"]
}
```

**platform/mac/BUILD.gn**:
```gn
deps = [
  "//:pdfium",
  "//platform/shared:logger",  # 已添加
]
```

---

## 配置说明

### 开发环境配置

```cpp
Logger::GetInstance().Initialize(app_path);
Logger::GetInstance().SetLevel(LogLevel::DEBUG);
Logger::GetInstance().SetConsoleOutput(true);  // 在控制台显示
```

### 生产环境配置

```cpp
Logger::GetInstance().Initialize(app_path);
Logger::GetInstance().SetLevel(LogLevel::INFO);   // 只记录重要信息
Logger::GetInstance().SetConsoleOutput(false);    // 不在控制台显示
```

### 日志文件管理

日志文件会自动轮转：
- 单个文件最大 10MB（可配置）
- 自动保留最近 5 个文件（可配置）
- 旧文件自动重命名为 `debug.log.1`, `debug.log.2` 等

```
PdfWinViewer.app/Contents/MacOS/
├── debug.log       # 当前日志
├── debug.log.1     # 历史日志 1
├── debug.log.2     # 历史日志 2
├── debug.log.3     # 历史日志 3
└── debug.log.4     # 历史日志 4
```

---

## 最佳实践

### ✅ 推荐做法

1. **应用启动时立即初始化**
   ```cpp
   Logger::GetInstance().Initialize(app_path);
   ```

2. **使用合适的日志级别**
   - 一般信息用 `LOG_INFO`
   - 调试信息用 `LOG_DEBUG`
   - 警告用 `LOG_WARNING`
   - 错误用 `LOG_ERROR`

3. **记录关键操作**
   ```cpp
   LOG_INFO("用户打开文档");
   LOG_INFO_F("文档包含 %d 页", pageCount);
   ```

4. **详细记录错误**
   ```cpp
   LOG_ERROR_F("打开文件失败：%s，错误码：%d", filename, errorCode);
   ```

5. **使用性能日志监控瓶颈**
   ```cpp
   LOG_PERF(page, zoom, time_ms, mem_mb, delta_mb, "关键操作");
   ```

### ❌ 避免做法

1. **不要记录敏感信息**
   ```cpp
   // ❌ 不好
   LOG_INFO_F("用户密码：%s", password);
   
   // ✅ 好
   LOG_INFO("用户登录成功");
   ```

2. **不要在循环中频繁记录**
   ```cpp
   // ❌ 不好
   for (int i = 0; i < 10000; i++) {
       LOG_DEBUG_F("处理项 %d", i);
   }
   
   // ✅ 好
   LOG_DEBUG_F("开始处理 %d 项", count);
   // ... 处理 ...
   LOG_DEBUG("处理完成");
   ```

3. **生产环境不使用 DEBUG/TRACE**
   ```cpp
   #ifdef DEBUG
   Logger::GetInstance().SetLevel(LogLevel::DEBUG);
   #else
   Logger::GetInstance().SetLevel(LogLevel::INFO);
   #endif
   ```

---

## 日志输出说明

### 打开文档的日志

打开文档时会输出以下信息：

```
[INFO ] 正在打开 PDF 文件：/path/to/document.pdf
[DEBUG] 文件完整路径：/path/to/document.pdf
[DEBUG] 文件名：document.pdf
[DEBUG] 调用 FPDF_LoadDocument
[INFO ] PDF 文件打开成功，共 25 页
[INFO ] ⏱️  文档加载耗时：15.23 ms（FPDF_LoadDocument: 12.45 ms）
```

**耗时说明**：
- **文档加载耗时**：从开始到完全加载的总时间
- **FPDF_LoadDocument**：PDFium 库加载文档的时间

### 渲染日志

#### 首次渲染
打开文档后的首次渲染会输出：

```
[INFO ] 🎨 首次渲染完成 - 页面 1，缩放 100%，耗时 70.18 ms（从打开到首次显示）
[PERF] [+0.070s] Page=1 Zoom=100% Time=70.18ms Mem=26.88MB DeltaMem=1.83MB | 打开PDF→首次渲染
```

这个时间包括从打开文档到页面显示在屏幕上的全部时间。

#### 后续渲染
每次页面需要重新绘制时（如滚动、缩放、窗口刷新），会触发渲染：

```
[DEBUG] 🎨 页面渲染 - 页面 1，缩放 100%，耗时 48.69 ms
[PERF] [+0.264s] Page=1 Zoom=100% Time=48.69ms Mem=91.67MB DeltaMem=64.80MB | 渲染单页统计
```

**为什么会多次渲染？**

macOS 的视图系统会在以下情况触发 `drawRect:` 重绘：
1. 窗口首次显示
2. 窗口大小改变
3. 窗口从其他窗口后移到前面
4. 部分内容被遮挡后重新显示
5. 手动调用 `setNeedsDisplay:`

这是正常的系统行为。为了避免日志过多，现在只记录耗时超过 30ms 的渲染操作。

### 性能日志格式

```
[PERF] [+相对时间] Page=页码 Zoom=缩放% Time=耗时ms Mem=内存MB DeltaMem=内存增量MB | 说明
```

示例：
```
[PERF] [+0.264s] Page=1 Zoom=100% Time=48.69ms Mem=91.67MB DeltaMem=64.80MB | 渲染单页统计
```

说明：
- **相对时间**：从应用启动开始的时间
- **Page**：当前页码
- **Zoom**：缩放比例
- **Time**：本次操作耗时
- **Mem**：当前内存使用
- **DeltaMem**：相对上次的内存变化

## 常见问题

### Q: 日志文件在哪里？

**A**: 在应用程序可执行文件所在目录：
```
PdfWinViewer.app/Contents/MacOS/debug.log
```

### Q: 如何查看日志？

**A**: 三种方法：
1. 在 Finder 中找到文件，用文本编辑器打开
2. 终端中使用：`tail -f debug.log` 实时查看
3. 在应用中添加"显示日志"菜单项

### Q: 日志文件太大怎么办？

**A**: 日志系统会自动轮转：
- 单个文件超过 10MB 自动创建新文件
- 默认保留最近 5 个文件
- 可手动清空：`Logger::GetInstance().ClearLog()`

### Q: 如何禁用日志？

**A**: 两种方法：
```cpp
// 方法 1：完全禁用
Logger::GetInstance().SetEnabled(false);

// 方法 2：提高日志级别（只记录重要信息）
Logger::GetInstance().SetLevel(LogLevel::ERROR);
```

### Q: 日志会影响性能吗？

**A**: 影响很小：
- 被过滤的日志几乎没有开销（~0.001ms）
- 正常日志每条约 0.1 毫秒
- 建议生产环境使用 INFO 或更高级别

### Q: 支持多线程吗？

**A**: 是的，日志模块完全线程安全，使用 `std::mutex` 保护所有操作。

### Q: 如何在 Objective-C 中使用？

**A**: 两种方式：
```objc
// 方式 1：直接使用 C++ 宏（推荐）
LOG_INFO("消息");

// 方式 2：使用 Objective-C 包装类
[LoggerHelper logInfo:@"消息"];
```

### Q: 如何自定义日志文件位置？

**A**: 在 `Initialize()` 时传入不同的路径：
```cpp
std::string custom_path = "/path/to/custom/location/app";
Logger::GetInstance().Initialize(custom_path);
// 日志将保存在：/path/to/custom/location/debug.log
```

---

## 技术细节

### 架构设计

- **设计模式**：Singleton（单例）+ PIMPL（指针实现）
- **线程安全**：使用 `std::mutex` 保护共享状态
- **时间精度**：使用 `std::chrono` 提供毫秒级精度
- **文件操作**：使用 C++ 标准库 `fstream`

### 性能指标

| 操作 | 耗时 | 说明 |
|------|------|------|
| 被过滤的日志 | ~0.001ms | 快速返回，几乎无影响 |
| 格式化日志 | ~0.1ms | 正常写入 |
| 文件轮转 | ~10ms | 偶尔发生 |

### 文件结构

```
platform/shared/
├── logger.h                    # 头文件（约 200 行）
├── logger.cpp                  # 实现文件（约 400 行）
├── logger_example.cpp          # 示例代码
├── logger_test.cpp             # 测试程序
└── logger_standalone_build.sh  # 独立构建脚本

platform/mac/
├── LoggerHelper.h              # Objective-C++ 包装类
└── LoggerHelper.mm             # 实现文件
```

### 测试

运行独立测试：
```bash
cd platform/shared
./logger_standalone_build.sh
```

---

## 许可证

```
Copyright 2024 The PDFium Authors
Use of this source code is governed by a BSD-style license that can be
found in the LICENSE file.
```

---

**文档版本**: 1.0.0  
**最后更新**: 2024-11-03  
**维护者**: PdfWinViewer Development Team