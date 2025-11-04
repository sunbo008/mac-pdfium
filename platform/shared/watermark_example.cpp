// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// [AP-FORM-IMAGE-WATERMARK] 水印回调使用示例

#include "platform/shared/watermark_callback.h"
#include "fpdfsdk/cpdfsdk_renderpage.h"
#include "platform/shared/logger.h"

// 全局回调实例（在应用生命周期内保持）
static WatermarkCallback* g_watermark_callback = nullptr;

// 在应用初始化时调用
void InitializeWatermarkCallback() {
  // 创建水印回调实例
  g_watermark_callback = new WatermarkCallback();
  
  // 注册到 PDFium
  CPDFSDK_SetApFormImageCallback(g_watermark_callback);
  
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Callback registered");
}

// 在应用退出时调用（可选）
void CleanupWatermarkCallback() {
  if (g_watermark_callback) {
    // 取消注册
    CPDFSDK_SetApFormImageCallback(nullptr);
    
    // 删除实例
    delete g_watermark_callback;
    g_watermark_callback = nullptr;
    
    LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Callback unregistered");
  }
}

// ========================================
// macOS 平台示例
// ========================================
#if defined(__APPLE__)

// 在 AppDelegate 或 main 函数中调用
// 示例 1: 在 applicationDidFinishLaunching 中初始化
/*
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  // ... 其他初始化代码 ...
  
  // 初始化日志系统
  NSString* execPath = [[NSBundle mainBundle] executablePath];
  std::string app_path = [execPath UTF8String];
  pdfium_viewer::Logger::GetInstance().Initialize(app_path);
  
  // 初始化 PDFium
  FPDF_InitLibrary();
  
  // 初始化水印回调
  InitializeWatermarkCallback();
  
  // ... 其他代码 ...
}
*/

// 示例 2: 在 main 函数中初始化
/*
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // 初始化日志
    NSString* execPath = [[NSProcessInfo processInfo] arguments][0];
    pdfium_viewer::Logger::GetInstance().Initialize([execPath UTF8String]);
    
    // 初始化 PDFium
    FPDF_InitLibrary();
    
    // 初始化水印回调
    InitializeWatermarkCallback();
    
    // 运行应用
    return NSApplicationMain(argc, argv);
  }
}
*/

#endif  // __APPLE__

// ========================================
// 使用说明
// ========================================
/*
1. 确保在调用 FPDF_InitLibrary() 之后初始化水印回调

2. 确保水印图片存在：
   - 路径：/Volumes/Lzf-MoveDisk/图片/水印.jpeg
   - 格式：JPEG

3. 确保输出目录存在：
   - 路径：/Volumes/Lzf-MoveDisk/图片/

4. 查看日志输出：
   - 日志文件位置：<应用目录>/debug.log
   - 搜索关键词：[AP-FORM-IMAGE-WATERMARK]

5. 验证水印功能：
   - 打开包含图片注释的 PDF 文件
   - 水印应该出现在图片的左上角
   - 水印尺寸为原图的 1/3

6. 测试 PDF 准备：
   - 使用 Adobe Acrobat 或 macOS 预览添加图片注释
   - 或使用 PDFium API 创建包含图片的注释外观流
*/

