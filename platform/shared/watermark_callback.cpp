// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "platform/shared/watermark_callback.h"
#include "platform/shared/logger.h"
#include "core/fxge/dib/cfx_dibitmap.h"
#include "core/fxge/dib/cfx_dibbase.h"
#include <fstream>
#include <sstream>
#include <iomanip>

// [AP-FORM-IMAGE-WATERMARK] 硬编码路径定义
constexpr char WatermarkCallback::kWatermarkPath[];
constexpr char WatermarkCallback::kOutputDir[];

WatermarkCallback::WatermarkCallback() {
  // [AP-FORM-IMAGE-WATERMARK] 不在构造函数中加载水印
  // 延迟到首次使用时加载，确保 PDFium 已经初始化
  LOG_INFO("[AP-FORM-IMAGE-WATERMARK] WatermarkCallback created (lazy loading)");
}

WatermarkCallback::~WatermarkCallback() = default;

std::vector<uint8_t> WatermarkCallback::ReadFileData(const char* path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Cannot open file: %s", path);
    return {};
  }
  
  auto size = file.tellg();
  if (size <= 0) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] File is empty: %s", path);
    return {};
  }
  
  std::vector<uint8_t> data(size);
  file.seekg(0);
  file.read(reinterpret_cast<char*>(data.data()), size);
  
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Read %zu bytes from %s", data.size(), path);
  return data;
}

bool WatermarkCallback::LoadWatermarkImage(const char* path) {
  // [AP-FORM-IMAGE-WATERMARK] 读取文件数据
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Loading watermark from: %s", path);
  std::vector<uint8_t> file_data = ReadFileData(path);
  if (file_data.empty()) {
    return false;
  }
  
  // TODO: 使用 PDFium 的解码器加载图片
  // 当前简化实现：创建一个简单的彩色矩形作为水印
  int width = 200;
  int height = 200;
  
  auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
  if (!bitmap->Create(width, height, FXDIB_Format::kBgra)) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to create bitmap");
    return false;
  }
  
  // 填充红色作为临时水印
  pdfium::span<uint8_t> buffer = bitmap->GetWritableBuffer();
  for (size_t i = 0; i < buffer.size(); i += 4) {
    buffer[i] = 0;      // B
    buffer[i+1] = 0;    // G
    buffer[i+2] = 255;  // R
    buffer[i+3] = 128;  // A (半透明)
  }
  
  watermark_bitmap_ = bitmap;
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Created watermark: %dx%d (temporary red rectangle)", width, height);
  return true;
}

RetainPtr<CFX_DIBitmap> WatermarkCallback::OnImageRendering(
    CPDF_ImageObject* pImageObj,
    const CFX_Matrix& mtObj2Device,
    RetainPtr<CFX_DIBitmap> pOriginalBitmap) {
  
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] OnImageRendering called");
  
  if (!pOriginalBitmap) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Original bitmap is null");
    return nullptr;
  }
  
  // [AP-FORM-IMAGE-WATERMARK] 懒加载：首次使用时才加载水印
  if (!watermark_bitmap_) {
    LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Loading watermark on first use");
    if (!LoadWatermarkImage(kWatermarkPath)) {
      LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to load watermark, returning original");
      return nullptr;
    }
  }
  
  // 克隆原始位图
  RetainPtr<CFX_DIBitmap> result = pOriginalBitmap->Realize();
  if (!result) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to realize bitmap");
    return nullptr;
  }
  
  // 应用水印
  if (!ApplyWatermark(result.Get(), watermark_bitmap_.Get())) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to apply watermark");
    return nullptr;
  }
  
  // 保存中间产物
  std::ostringstream filename;
  filename << "watermarked_" << std::setw(4) << std::setfill('0') 
           << (++image_counter_) << ".png";
  SaveBitmapToFile(result.Get(), filename.str());
  
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] SUCCESS: Watermark applied");
  return result;
}

bool WatermarkCallback::ApplyWatermark(CFX_DIBitmap* target_bitmap,
                                       const CFX_DIBitmap* watermark) {
  // [AP-FORM-IMAGE-WATERMARK] 计算水印尺寸（1/3）
  int target_width = target_bitmap->GetWidth();
  int target_height = target_bitmap->GetHeight();
  int wm_width = target_width / 3;
  int wm_height = target_height / 3;
  
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Target: %dx%d, Watermark size: %dx%d",
           target_width, target_height, wm_width, wm_height);
  
  // 缩放水印到目标尺寸
  RetainPtr<CFX_DIBitmap> scaled_watermark = 
      watermark->StretchTo(wm_width, wm_height, 
                          FXDIB_ResampleOptions(), nullptr);
  
  if (!scaled_watermark) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to scale watermark");
    return false;
  }
  
  // [AP-FORM-IMAGE-WATERMARK] 合成到左上角
  // 位置：(0, 0)
  bool success = target_bitmap->CompositeBitmap(
      0, 0,  // left, top
      wm_width, wm_height,  // width, height
      scaled_watermark, 0, 0,  // source left, top
      BlendMode::kNormal,
      nullptr, false);
  
  if (success) {
    LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Watermark composited at (0,0), size: %dx%d", 
               wm_width, wm_height);
  }
  
  return success;
}

bool WatermarkCallback::SaveBitmapToFile(CFX_DIBitmap* bitmap,
                                         const std::string& filename) {
  // [AP-FORM-IMAGE-WATERMARK] 保存到指定目录
  std::string full_path = std::string(kOutputDir) + filename;
  
  // TODO: 实现 PNG 编码保存
  // 当前 PDFium 没有直接的 PNG 编码器，需要使用平台特定的保存方法
  // 或者暂时跳过保存功能
  
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Would save to: %s", full_path.c_str());
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Bitmap: %dx%d, format: %d",
           bitmap->GetWidth(), bitmap->GetHeight(), 
           static_cast<int>(bitmap->GetFormat()));
  
  return true;
}

