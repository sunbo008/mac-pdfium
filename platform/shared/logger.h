// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef PLATFORM_SHARED_LOGGER_H_
#define PLATFORM_SHARED_LOGGER_H_

#include <cstdarg>
#include <string>

namespace pdfium_viewer {

// 日志级别枚举
enum class LogLevel {
  TRACE = 0,    // 详细跟踪信息
  DEBUG = 1,    // 调试信息
  INFO = 2,     // 一般信息
  WARNING = 3,  // 警告信息
  ERROR = 4,    // 错误信息
  CRITICAL = 5  // 严重错误
};

// 全局日志管理器类
class Logger {
 public:
  // 获取全局单例实例
  static Logger& GetInstance();

  // 初始化日志系统
  // app_path: 应用程序可执行文件路径（用于确定日志保存位置）
  // max_file_size: 单个日志文件的最大大小（字节），超过后会轮转
  // max_file_count: 保留的历史日志文件数量
  void Initialize(const std::string& app_path,
                  size_t max_file_size = 10 * 1024 * 1024,  // 默认 10MB
                  int max_file_count = 5);                  // 默认保留 5 个文件

  // 设置日志级别（低于此级别的日志将不会被记录）
  void SetLevel(LogLevel level);
  
  // 获取当前日志级别
  LogLevel GetLevel() const;

  // 启用/禁用日志记录
  void SetEnabled(bool enabled);
  
  // 检查日志是否启用
  bool IsEnabled() const;

  // 启用/禁用控制台输出
  void SetConsoleOutput(bool enabled);

  // 写入日志（C++ 风格）
  void Log(LogLevel level, 
           const char* file, 
           int line, 
           const char* function,
           const std::string& message);

  // 写入格式化日志（C 风格）
  void LogFormat(LogLevel level,
                 const char* file,
                 int line,
                 const char* function,
                 const char* format,
                 ...);

  // 写入宽字符格式化日志（用于兼容现有代码）
  void LogFormatW(LogLevel level,
                  const char* file,
                  int line,
                  const char* function,
                  const wchar_t* format,
                  ...);

  // 写入性能日志
  void LogPerf(int page,
               double zoom_percent,
               double time_ms,
               double mem_mb,
               double delta_mem_mb,
               const char* remarks,
               const char* file,
               int line,
               const char* function);

  // 获取日志文件路径
  std::string GetLogFilePath() const;

  // 清空当前日志文件
  void ClearLog();

  // 刷新日志缓冲区（确保所有日志已写入文件）
  void Flush();

  // 析构函数
  ~Logger();

 private:
  Logger();  // 私有构造函数（单例模式）
  
  // 禁止拷贝和赋值
  Logger(const Logger&) = delete;
  Logger& operator=(const Logger&) = delete;

  // 内部实现方法
  void WriteToFile(const std::string& message);
  void RotateLogFile();
  std::string FormatLogMessage(LogLevel level,
                               const char* file,
                               int line,
                               const char* function,
                               const std::string& message);
  std::string GetLevelString(LogLevel level) const;
  std::string GetCurrentTimeString() const;
  double GetElapsedSeconds() const;
  std::string GetLogDirectory() const;

  class Impl;  // PIMPL 模式，隐藏实现细节
  Impl* impl_;
};

// 便捷宏定义
#define LOG_TRACE(msg) \
  pdfium_viewer::Logger::GetInstance().Log( \
      pdfium_viewer::LogLevel::TRACE, __FILE__, __LINE__, __FUNCTION__, msg)

#define LOG_DEBUG(msg) \
  pdfium_viewer::Logger::GetInstance().Log( \
      pdfium_viewer::LogLevel::DEBUG, __FILE__, __LINE__, __FUNCTION__, msg)

#define LOG_INFO(msg) \
  pdfium_viewer::Logger::GetInstance().Log( \
      pdfium_viewer::LogLevel::INFO, __FILE__, __LINE__, __FUNCTION__, msg)

#define LOG_WARNING(msg) \
  pdfium_viewer::Logger::GetInstance().Log( \
      pdfium_viewer::LogLevel::WARNING, __FILE__, __LINE__, __FUNCTION__, msg)

#define LOG_ERROR(msg) \
  pdfium_viewer::Logger::GetInstance().Log( \
      pdfium_viewer::LogLevel::ERROR, __FILE__, __LINE__, __FUNCTION__, msg)

#define LOG_CRITICAL(msg) \
  pdfium_viewer::Logger::GetInstance().Log( \
      pdfium_viewer::LogLevel::CRITICAL, __FILE__, __LINE__, __FUNCTION__, msg)

// 格式化日志宏
#define LOG_TRACE_F(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormat( \
      pdfium_viewer::LogLevel::TRACE, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_DEBUG_F(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormat( \
      pdfium_viewer::LogLevel::DEBUG, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_INFO_F(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormat( \
      pdfium_viewer::LogLevel::INFO, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_WARNING_F(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormat( \
      pdfium_viewer::LogLevel::WARNING, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_ERROR_F(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormat( \
      pdfium_viewer::LogLevel::ERROR, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_CRITICAL_F(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormat( \
      pdfium_viewer::LogLevel::CRITICAL, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

// 宽字符格式化日志宏（兼容现有代码）
#define LOG_TRACE_W(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormatW( \
      pdfium_viewer::LogLevel::TRACE, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_DEBUG_W(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormatW( \
      pdfium_viewer::LogLevel::DEBUG, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_INFO_W(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormatW( \
      pdfium_viewer::LogLevel::INFO, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_WARNING_W(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormatW( \
      pdfium_viewer::LogLevel::WARNING, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_ERROR_W(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormatW( \
      pdfium_viewer::LogLevel::ERROR, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

#define LOG_CRITICAL_W(fmt, ...) \
  pdfium_viewer::Logger::GetInstance().LogFormatW( \
      pdfium_viewer::LogLevel::CRITICAL, __FILE__, __LINE__, __FUNCTION__, fmt, ##__VA_ARGS__)

// 性能日志宏
#define LOG_PERF(page, zoom, time_ms, mem_mb, delta_mb, remarks) \
  pdfium_viewer::Logger::GetInstance().LogPerf( \
      page, zoom, time_ms, mem_mb, delta_mb, remarks, __FILE__, __LINE__, __FUNCTION__)

}  // namespace pdfium_viewer

#endif  // PLATFORM_SHARED_LOGGER_H_

