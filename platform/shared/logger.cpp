// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "platform/shared/logger.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <vector>

#ifdef __APPLE__
#include <mach/mach.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace pdfium_viewer {

// Logger 实现类（PIMPL 模式）
class Logger::Impl {
 public:
  Impl()
      : enabled_(true),
        console_output_(false),
        level_(LogLevel::DEBUG),
        max_file_size_(10 * 1024 * 1024),
        max_file_count_(5),
        current_file_size_(0),
        start_time_(std::chrono::steady_clock::now()) {}

  std::mutex mutex_;
  bool enabled_;
  bool console_output_;
  LogLevel level_;
  std::string log_directory_;
  std::string log_file_path_;
  size_t max_file_size_;
  int max_file_count_;
  size_t current_file_size_;
  std::chrono::steady_clock::time_point start_time_;
};

Logger::Logger() : impl_(new Impl()) {}

Logger::~Logger() {
  Flush();
  delete impl_;
}

Logger& Logger::GetInstance() {
  static Logger instance;
  return instance;
}

void Logger::Initialize(const std::string& app_path,
                        size_t max_file_size,
                        int max_file_count) {
  std::lock_guard<std::mutex> lock(impl_->mutex_);

  impl_->max_file_size_ = max_file_size;
  impl_->max_file_count_ = max_file_count;

  // 确定日志目录（应用程序所在目录）
  size_t pos = app_path.find_last_of("/\\");
  if (pos != std::string::npos) {
    impl_->log_directory_ = app_path.substr(0, pos);
  } else {
    impl_->log_directory_ = ".";
  }

  impl_->log_file_path_ = impl_->log_directory_ + "/debug.log";

  // 检查并获取当前日志文件大小
  std::ifstream file(impl_->log_file_path_, std::ios::ate | std::ios::binary);
  if (file.is_open()) {
    impl_->current_file_size_ = file.tellg();
    file.close();
  } else {
    impl_->current_file_size_ = 0;
  }

  // 写入启动日志
  std::ostringstream oss;
  oss << "\n========================================\n"
      << "Logger initialized at " << GetCurrentTimeString() << "\n"
      << "Log directory: " << impl_->log_directory_ << "\n"
      << "Log file: " << impl_->log_file_path_ << "\n"
      << "Max file size: " << (impl_->max_file_size_ / 1024 / 1024) << " MB\n"
      << "Max file count: " << impl_->max_file_count_ << "\n"
      << "========================================\n";

  WriteToFile(oss.str());
}

void Logger::SetLevel(LogLevel level) {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  impl_->level_ = level;
}

LogLevel Logger::GetLevel() const {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  return impl_->level_;
}

void Logger::SetEnabled(bool enabled) {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  impl_->enabled_ = enabled;
}

bool Logger::IsEnabled() const {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  return impl_->enabled_;
}

void Logger::SetConsoleOutput(bool enabled) {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  impl_->console_output_ = enabled;
}

void Logger::Log(LogLevel level,
                 const char* file,
                 int line,
                 const char* function,
                 const std::string& message) {
  std::lock_guard<std::mutex> lock(impl_->mutex_);

  if (!impl_->enabled_ || level < impl_->level_) {
    return;
  }

  std::string formatted =
      FormatLogMessage(level, file, line, function, message);

  WriteToFile(formatted);

  if (impl_->console_output_) {
    std::cout << formatted << std::endl;
  }
}

void Logger::LogFormat(LogLevel level,
                       const char* file,
                       int line,
                       const char* function,
                       const char* format,
                       ...) {
  if (!impl_->enabled_ || level < impl_->level_) {
    return;
  }

  char buffer[2048];
  va_list args;
  va_start(args, format);
  vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);

  Log(level, file, line, function, std::string(buffer));
}

void Logger::LogFormatW(LogLevel level,
                        const char* file,
                        int line,
                        const char* function,
                        const wchar_t* format,
                        ...) {
  if (!impl_->enabled_ || level < impl_->level_) {
    return;
  }

  wchar_t wbuffer[2048];
  va_list args;
  va_start(args, format);
  vswprintf(wbuffer, sizeof(wbuffer) / sizeof(wchar_t), format, args);
  va_end(args);

  // 将宽字符转换为多字节字符（UTF-8）
  char buffer[4096];
  size_t converted = 0;

#ifdef _WIN32
  wcstombs_s(&converted, buffer, sizeof(buffer), wbuffer, _TRUNCATE);
#else
  wcstombs(buffer, wbuffer, sizeof(buffer) - 1);
  buffer[sizeof(buffer) - 1] = '\0';
#endif

  Log(level, file, line, function, std::string(buffer));
}

void Logger::LogPerf(int page,
                     double zoom_percent,
                     double time_ms,
                     double mem_mb,
                     double delta_mem_mb,
                     const char* remarks,
                     const char* file,
                     int line,
                     const char* function) {
  std::lock_guard<std::mutex> lock(impl_->mutex_);

  if (!impl_->enabled_) {
    return;
  }

  std::ostringstream oss;
  oss << "[PERF] [+" << std::fixed << std::setprecision(3)
      << GetElapsedSeconds() << "s] Page=" << page << " Zoom=" << std::fixed
      << std::setprecision(0) << zoom_percent << "%"
      << " Time=" << std::fixed << std::setprecision(2) << time_ms << "ms"
      << " Mem=" << std::fixed << std::setprecision(2) << mem_mb << "MB"
      << " DeltaMem=" << std::fixed << std::setprecision(2) << delta_mem_mb
      << "MB";

  if (remarks && remarks[0] != '\0') {
    oss << " | " << remarks;
  }

  if (file && function) {
    const char* filename = strrchr(file, '/');
    if (!filename) {
      filename = strrchr(file, '\\');
    }
    if (filename) {
      filename++;
    } else {
      filename = file;
    }
    oss << " | " << filename << ":" << line << " " << function;
  }

  oss << "\n";

  WriteToFile(oss.str());

  if (impl_->console_output_) {
    std::cout << oss.str();
  }
}

std::string Logger::GetLogFilePath() const {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  return impl_->log_file_path_;
}

void Logger::ClearLog() {
  std::lock_guard<std::mutex> lock(impl_->mutex_);

  std::ofstream file(impl_->log_file_path_, std::ios::trunc);
  if (file.is_open()) {
    file.close();
    impl_->current_file_size_ = 0;
  }
}

void Logger::Flush() {
  // 文件流在每次写入后会自动刷新，这里保留接口以便将来需要
}

void Logger::WriteToFile(const std::string& message) {
  // 检查是否需要轮转日志文件
  if (impl_->current_file_size_ + message.size() > impl_->max_file_size_) {
    RotateLogFile();
  }

  std::ofstream file(impl_->log_file_path_, std::ios::app);
  if (file.is_open()) {
    file << message;
    file.close();
    impl_->current_file_size_ += message.size();
  }
}

void Logger::RotateLogFile() {
  // 删除最旧的日志文件
  if (impl_->max_file_count_ > 1) {
    std::string oldest_log = impl_->log_file_path_ + "." +
                             std::to_string(impl_->max_file_count_ - 1);
    remove(oldest_log.c_str());

    // 重命名现有日志文件
    for (int i = impl_->max_file_count_ - 2; i >= 0; i--) {
      std::string old_name =
          (i == 0) ? impl_->log_file_path_
                   : (impl_->log_file_path_ + "." + std::to_string(i));
      std::string new_name =
          impl_->log_file_path_ + "." + std::to_string(i + 1);
      rename(old_name.c_str(), new_name.c_str());
    }
  } else {
    // 如果只保留一个文件，直接清空
    remove(impl_->log_file_path_.c_str());
  }

  impl_->current_file_size_ = 0;

  // 在新文件中写入轮转标记
  std::ostringstream oss;
  oss << "\n========================================\n"
      << "Log file rotated at " << GetCurrentTimeString() << "\n"
      << "========================================\n";
  WriteToFile(oss.str());
}

std::string Logger::FormatLogMessage(LogLevel level,
                                     const char* file,
                                     int line,
                                     const char* function,
                                     const std::string& message) {
  std::ostringstream oss;

  // 时间戳和日志级别
  oss << "[" << GetLevelString(level) << "] "
      << "[" << GetCurrentTimeString() << "] "
      << "[+" << std::fixed << std::setprecision(3) << GetElapsedSeconds()
      << "s] ";

  // 文件名和行号
  if (file) {
    const char* filename = strrchr(file, '/');
    if (!filename) {
      filename = strrchr(file, '\\');
    }
    if (filename) {
      filename++;
    } else {
      filename = file;
    }
    oss << "[" << filename << ":" << line << "] ";
  }

  // 函数名
  if (function) {
    oss << "[" << function << "] ";
  }

  // 消息内容
  oss << message << "\n";

  return oss.str();
}

std::string Logger::GetLevelString(LogLevel level) const {
  switch (level) {
    case LogLevel::TRACE:
      return "TRACE";
    case LogLevel::DEBUG:
      return "DEBUG";
    case LogLevel::INFO:
      return "INFO ";
    case LogLevel::WARNING:
      return "WARN ";
    case LogLevel::ERROR:
      return "ERROR";
    case LogLevel::CRITICAL:
      return "CRIT ";
    default:
      return "UNKN ";
  }
}

std::string Logger::GetCurrentTimeString() const {
  auto now = std::chrono::system_clock::now();
  auto time_t_now = std::chrono::system_clock::to_time_t(now);
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                now.time_since_epoch()) %
            1000;

  std::tm tm_now;
#ifdef _WIN32
  localtime_s(&tm_now, &time_t_now);
#else
  localtime_r(&time_t_now, &tm_now);
#endif

  std::ostringstream oss;
  oss << std::put_time(&tm_now, "%Y-%m-%d %H:%M:%S") << "." << std::setfill('0')
      << std::setw(3) << ms.count();
  return oss.str();
}

double Logger::GetElapsedSeconds() const {
  auto now = std::chrono::steady_clock::now();
  auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      now - impl_->start_time_);
  return elapsed.count() / 1000.0;
}

std::string Logger::GetLogDirectory() const {
  std::lock_guard<std::mutex> lock(impl_->mutex_);
  return impl_->log_directory_;
}

}  // namespace pdfium_viewer
