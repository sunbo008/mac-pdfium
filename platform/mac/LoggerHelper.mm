// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "platform/mac/LoggerHelper.h"
#include "platform/shared/logger.h"
#import <AppKit/AppKit.h>

using namespace pdfium_viewer;

@implementation LoggerHelper

+ (void)initializeWithMaxFileSize:(NSUInteger)maxSize
                    maxFileCount:(NSInteger)count {
  NSString *execPath = [[NSBundle mainBundle] executablePath];
  std::string app_path = [execPath UTF8String];
  
  Logger::GetInstance().Initialize(app_path, maxSize, (int)count);
}

+ (void)initialize {
  [self initializeWithMaxFileSize:10 * 1024 * 1024 maxFileCount:5];
}

+ (void)setLogLevel:(NSInteger)level {
  if (level >= 0 && level <= 5) {
    Logger::GetInstance().SetLevel(static_cast<LogLevel>(level));
  }
}

+ (void)setEnabled:(BOOL)enabled {
  Logger::GetInstance().SetEnabled(enabled);
}

+ (void)setConsoleOutput:(BOOL)enabled {
  Logger::GetInstance().SetConsoleOutput(enabled);
}

+ (NSString *)logFilePath {
  std::string path = Logger::GetInstance().GetLogFilePath();
  return [NSString stringWithUTF8String:path.c_str()];
}

+ (void)revealLogFileInFinder {
  NSString *path = [self logFilePath];
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    [[NSWorkspace sharedWorkspace] selectFile:path
                     inFileViewerRootedAtPath:[path stringByDeletingLastPathComponent]];
  } else {
    NSLog(@"Log file does not exist: %@", path);
  }
}

+ (void)clearLog {
  Logger::GetInstance().ClearLog();
}

+ (void)flush {
  Logger::GetInstance().Flush();
}

+ (void)logInfo:(NSString *)message {
  LOG_INFO([message UTF8String]);
}

+ (void)logDebug:(NSString *)message {
  LOG_DEBUG([message UTF8String]);
}

+ (void)logWarning:(NSString *)message {
  LOG_WARNING([message UTF8String]);
}

+ (void)logError:(NSString *)message {
  LOG_ERROR([message UTF8String]);
}

+ (void)logPerf:(NSInteger)page
           zoom:(double)zoomPercent
        timeMS:(double)timeMS
         memMB:(double)memMB
      deltaMem:(double)deltaMB
       remarks:(NSString *)remarks {
  const char *remarksStr = remarks ? [remarks UTF8String] : "";
  LOG_PERF((int)page, zoomPercent, timeMS, memMB, deltaMB, remarksStr);
}

@end

