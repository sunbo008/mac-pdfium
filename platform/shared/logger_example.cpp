// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// 这是一个示例文件，展示如何使用全局日志模块
// 此文件不会被编译，仅供参考

#include "platform/shared/logger.h"
#include <string>

using namespace pdfium_viewer;

void ExampleUsage() {
  // 1. 初始化日志系统（通常在应用启动时调用一次）
  // 获取应用程序路径（在 macOS 中）
  std::string app_path = "/Applications/PdfWinViewer.app/Contents/MacOS/mac_pdf_viewer";
  
  // 初始化日志系统
  // 参数: 应用路径, 单文件最大大小(10MB), 保留文件数量(5个)
  Logger::GetInstance().Initialize(app_path, 10 * 1024 * 1024, 5);
  
  // 2. 设置日志级别（可选，默认是 DEBUG）
  Logger::GetInstance().SetLevel(LogLevel::DEBUG);
  
  // 3. 启用控制台输出（可选，默认关闭）
  Logger::GetInstance().SetConsoleOutput(true);
  
  // 4. 使用便捷宏记录日志
  LOG_INFO("Application started successfully");
  LOG_DEBUG("Debug information");
  LOG_WARNING("This is a warning message");
  LOG_ERROR("An error occurred");
  
  // 5. 使用格式化日志
  int page_num = 5;
  double zoom = 150.5;
  LOG_INFO_F("Opening page %d with zoom %.1f%%", page_num, zoom);
  
  // 6. 使用宽字符格式化日志（兼容现有代码）
  LOG_DEBUG_W(L"处理中文字符: 页面 %d", page_num);
  
  // 7. 记录性能日志
  double render_time_ms = 123.45;
  double memory_mb = 256.78;
  double delta_mem_mb = 12.34;
  LOG_PERF(page_num, zoom, render_time_ms, memory_mb, delta_mem_mb, "Page rendering completed");
  
  // 8. 获取日志文件路径
  std::string log_path = Logger::GetInstance().GetLogFilePath();
  LOG_INFO_F("Log file location: %s", log_path.c_str());
  
  // 9. 临时禁用日志（可选）
  Logger::GetInstance().SetEnabled(false);
  LOG_INFO("This message will not be logged");
  
  // 10. 重新启用日志
  Logger::GetInstance().SetEnabled(true);
  LOG_INFO("Logging re-enabled");
  
  // 11. 清空日志文件（谨慎使用）
  // Logger::GetInstance().ClearLog();
  
  // 12. 刷新日志缓冲区（确保所有日志已写入）
  Logger::GetInstance().Flush();
}

// 在类中使用日志的示例
class PDFRenderer {
 public:
  void RenderPage(int page_number) {
    LOG_INFO_F("Starting to render page %d", page_number);
    
    try {
      // 渲染逻辑...
      LOG_DEBUG_F("Page %d rendered successfully", page_number);
    } catch (const std::exception& e) {
      LOG_ERROR_F("Failed to render page %d: %s", page_number, e.what());
    }
  }
  
  void LoadDocument(const std::string& path) {
    LOG_INFO_F("Loading document: %s", path.c_str());
    
    // 加载逻辑...
    if (/* 加载成功 */ true) {
      LOG_INFO("Document loaded successfully");
    } else {
      LOG_ERROR("Failed to load document");
    }
  }
};

// 在 Objective-C++ 代码中使用的示例
#ifdef __OBJC__
#import <Foundation/Foundation.h>

void ObjectiveCExample() {
  // 从 NSBundle 获取应用路径
  NSString* execPath = [[NSBundle mainBundle] executablePath];
  std::string app_path = [execPath UTF8String];
  
  // 初始化日志
  Logger::GetInstance().Initialize(app_path);
  
  // 记录日志
  LOG_INFO("Objective-C++ integration example");
  
  NSString* filename = @"document.pdf";
  LOG_INFO_F("Processing file: %s", [filename UTF8String]);
}
#endif


