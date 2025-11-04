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
  // [AP-FORM-IMAGE-WATERMARK] 水印文件名（从应用资源目录加载）
  static constexpr char kWatermarkFilename[] = "watermark.jpeg";
  
  WatermarkCallback();
  explicit WatermarkCallback(const char* resource_path);  // 自定义资源路径
  ~WatermarkCallback() override;
  
  // ImageCallbackIface 实现
  RetainPtr<CFX_DIBitmap> OnImageRendering(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override;
      
 private:
  RetainPtr<CFX_DIBitmap> watermark_bitmap_;  // 水印位图
  int image_counter_ = 0;  // 用于生成唯一文件名
  std::string watermark_path_;  // 完整水印路径
  std::string output_dir_;  // 临时输出目录
  
  // 加载水印图片（使用 PDFium 的图片解码器）
  bool LoadWatermarkImage(const char* path);
  
  // 使用 PDFium 解码器解码图片文件
  RetainPtr<CFX_DIBitmap> DecodeImageFile(const std::vector<uint8_t>& file_data);
  
  // 应用水印到位图（左上角 1/3 位置）
  bool ApplyWatermark(CFX_DIBitmap* target_bitmap,
                     const CFX_DIBitmap* watermark);
  
  // 保存位图到文件（PNG 格式）
  bool SaveBitmapToFile(CFX_DIBitmap* bitmap, const std::string& filename);
  
  // 从文件读取数据
  static std::vector<uint8_t> ReadFileData(const char* path);
  
  // 获取应用资源目录路径
  static std::string GetResourcePath();
  
  // 获取临时输出目录路径
  static std::string GetTempOutputPath();
};

#endif  // PLATFORM_SHARED_WATERMARK_CALLBACK_H_

