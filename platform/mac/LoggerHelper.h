// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef PLATFORM_MAC_LOGGER_HELPER_H_
#define PLATFORM_MAC_LOGGER_HELPER_H_

#import <Foundation/Foundation.h>

// Objective-C 包装类，用于在 macOS 应用中方便地使用全局日志模块
@interface LoggerHelper : NSObject

// 初始化日志系统（使用当前应用的路径）
+ (void)initializeWithMaxFileSize:(NSUInteger)maxSize
                    maxFileCount:(NSInteger)count;

// 使用默认参数初始化（10MB, 5个文件）
+ (void)initialize;

// 设置日志级别 (0=TRACE, 1=DEBUG, 2=INFO, 3=WARNING, 4=ERROR, 5=CRITICAL)
+ (void)setLogLevel:(NSInteger)level;

// 启用/禁用日志
+ (void)setEnabled:(BOOL)enabled;

// 启用/禁用控制台输出
+ (void)setConsoleOutput:(BOOL)enabled;

// 获取日志文件路径
+ (NSString *)logFilePath;

// 在 Finder 中显示日志文件
+ (void)revealLogFileInFinder;

// 清空日志文件
+ (void)clearLog;

// 刷新日志缓冲区
+ (void)flush;

// 记录简单日志
+ (void)logInfo:(NSString *)message;
+ (void)logDebug:(NSString *)message;
+ (void)logWarning:(NSString *)message;
+ (void)logError:(NSString *)message;

// 记录格式化日志
+ (void)logInfo:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logDebug:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logWarning:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logError:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

// 记录性能日志
+ (void)logPerf:(NSInteger)page
           zoom:(double)zoomPercent
        timeMS:(double)timeMS
         memMB:(double)memMB
      deltaMem:(double)deltaMB
       remarks:(NSString *)remarks;

@end

#endif  // PLATFORM_MAC_LOGGER_HELPER_H_

