// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// 简单的日志模块测试程序

#include "platform/shared/logger.h"
#include <iostream>
#include <string>

using namespace pdfium_viewer;

int main(int argc, char* argv[]) {
  std::cout << "=== Logger Module Test ===" << std::endl;
  
  // 1. 初始化日志系统
  std::string test_path = "/tmp/test_app";
  Logger::GetInstance().Initialize(test_path, 1024 * 1024, 3);  // 1MB, 3 files
  
  std::cout << "Logger initialized" << std::endl;
  std::cout << "Log file: " << Logger::GetInstance().GetLogFilePath() << std::endl;
  
  // 2. 测试各种日志级别
  std::cout << "\nTesting log levels..." << std::endl;
  LOG_TRACE("This is a TRACE message");
  LOG_DEBUG("This is a DEBUG message");
  LOG_INFO("This is an INFO message");
  LOG_WARNING("This is a WARNING message");
  LOG_ERROR("This is an ERROR message");
  LOG_CRITICAL("This is a CRITICAL message");
  
  // 3. 测试格式化日志
  std::cout << "\nTesting formatted logs..." << std::endl;
  int page = 5;
  double zoom = 150.5;
  LOG_INFO_F("Opening page %d with zoom %.1f%%", page, zoom);
  LOG_DEBUG_F("Processing %d items", 100);
  
  // 4. 测试宽字符日志
  std::cout << "\nTesting wide character logs..." << std::endl;
  LOG_INFO_W(L"Wide character test: 中文测试 page %d", page);
  
  // 5. 测试性能日志
  std::cout << "\nTesting performance logs..." << std::endl;
  LOG_PERF(1, 100.0, 123.45, 256.0, 10.5, "Test render");
  LOG_PERF(2, 150.0, 234.56, 266.5, 10.5, "Another render");
  
  // 6. 测试日志级别过滤
  std::cout << "\nTesting log level filtering..." << std::endl;
  Logger::GetInstance().SetLevel(LogLevel::WARNING);
  LOG_DEBUG("This should NOT appear (level too low)");
  LOG_WARNING("This SHOULD appear");
  LOG_ERROR("This SHOULD appear too");
  
  // 7. 测试启用/禁用
  std::cout << "\nTesting enable/disable..." << std::endl;
  Logger::GetInstance().SetEnabled(false);
  LOG_INFO("This should NOT appear (disabled)");
  Logger::GetInstance().SetEnabled(true);
  LOG_INFO("This SHOULD appear (re-enabled)");
  
  // 8. 重置日志级别
  Logger::GetInstance().SetLevel(LogLevel::DEBUG);
  
  // 9. 测试控制台输出
  std::cout << "\nTesting console output..." << std::endl;
  Logger::GetInstance().SetConsoleOutput(true);
  LOG_INFO("This should appear in console too");
  Logger::GetInstance().SetConsoleOutput(false);
  
  // 10. 刷新日志
  Logger::GetInstance().Flush();
  
  std::cout << "\n=== Test completed ===" << std::endl;
  std::cout << "Check log file at: " << Logger::GetInstance().GetLogFilePath() << std::endl;
  
  return 0;
}

