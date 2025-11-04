// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef PLATFORM_SHARED_WATERMARK_CALLBACK_H_
#define PLATFORM_SHARED_WATERMARK_CALLBACK_H_

#include <string>
#include <vector>
#include "core/fpdfapi/render/cpdf_renderstatus.h"
#include "core/fxcrt/retain_ptr.h"

class CFX_DIBitmap;
class CPDF_ImageObject;
class CFX_Matrix;

// [AP-FORM-IMAGE-WATERMARK] 跨平台水印回调实现
class WatermarkCallback : public CPDF_RenderStatus::ImageCallbackIface {
 public:
  // 硬编码的路径，后续可改为配置
  static constexpr char kWatermarkPath[] = "/Volumes/Lzf-MoveDisk/图片/水印.jpeg";
  static constexpr char kOutputDir[] = "/Volumes/Lzf-MoveDisk/图片/";
  
  WatermarkCallback();
  ~WatermarkCallback() override;
  
  // ImageCallbackIface 实现
  RetainPtr<CFX_DIBitmap> OnImageRendering(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override;
      
 private:
  RetainPtr<CFX_DIBitmap> watermark_bitmap_;  // 水印位图
  int image_counter_ = 0;  // 用于生成唯一文件名
  
  // 加载水印图片（使用 PDFium 的图片解码器）
  bool LoadWatermarkImage(const char* path);
  
  // 应用水印到位图（左上角 1/3 位置）
  bool ApplyWatermark(CFX_DIBitmap* target_bitmap,
                     const CFX_DIBitmap* watermark);
  
  // 保存位图到文件（PNG 格式）
  bool SaveBitmapToFile(CFX_DIBitmap* bitmap, const std::string& filename);
  
  // 从文件读取数据
  static std::vector<uint8_t> ReadFileData(const char* path);
};

#endif  // PLATFORM_SHARED_WATERMARK_CALLBACK_H_

