// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "platform/mac/CustomImageCallback.h"
#include "core/fpdfapi/page/cpdf_imageobject.h"
#include "core/fxge/dib/cfx_dibitmap.h"
#include "platform/shared/logger.h"

CustomImageCallback::CustomImageCallback()
    : WatermarkCallback(),
      mode_(ReplacementMode::kNone),
      replacement_enabled_(false),
      watermark_enabled_(false),
      min_width_(0),
      min_height_(0),
      image_counter_(0) {
  LOG_INFO("[CustomImageCallback] Created, mode=None, replacement=OFF, "
           "watermark=OFF");
}

CustomImageCallback::~CustomImageCallback() = default;

RetainPtr<CFX_DIBitmap> CustomImageCallback::GetReplacementImage(
    CPDF_ImageObject* pImageObj,
    const CFX_Matrix& mtObj2Device,
    RetainPtr<CFX_DIBitmap> pOriginalBitmap) {
  // 检查替换开关
  if (!replacement_enabled_) {
    LOG_DEBUG("[CustomImageCallback] Replacement disabled, using original");
    return nullptr;
  }

  if (!pOriginalBitmap) {
    LOG_WARNING("[CustomImageCallback] Original bitmap is null");
    return nullptr;
  }

  int orig_width = pOriginalBitmap->GetWidth();
  int orig_height = pOriginalBitmap->GetHeight();

  switch (mode_) {
    case ReplacementMode::kNone:
      LOG_DEBUG_F("[CustomImageCallback] Mode=None, no replacement for %dx%d",
                  orig_width, orig_height);
      return nullptr;

    case ReplacementMode::kGlobal:
      if (global_replacement_) {
        LOG_INFO_F("[CustomImageCallback] Global replacement: %dx%d -> %dx%d",
                   orig_width, orig_height, global_replacement_->GetWidth(),
                   global_replacement_->GetHeight());
        return global_replacement_;
      }
      LOG_WARNING("[CustomImageCallback] Global mode but no image set");
      return nullptr;

    case ReplacementMode::kConditional:
      if (ShouldReplaceBySize(orig_width, orig_height)) {
        if (conditional_replacement_) {
          LOG_INFO_F(
              "[CustomImageCallback] Conditional replacement: %dx%d -> %dx%d "
              "(threshold: %dx%d)",
              orig_width, orig_height, conditional_replacement_->GetWidth(),
              conditional_replacement_->GetHeight(), min_width_, min_height_);
          return conditional_replacement_;
        }
      } else {
        LOG_DEBUG_F("[CustomImageCallback] Image %dx%d below threshold %dx%d, "
                    "no replacement",
                    orig_width, orig_height, min_width_, min_height_);
      }
      return nullptr;

    case ReplacementMode::kMapped: {
      int index = GetImageIndex(pImageObj);
      auto it = mapped_replacements_.find(index);
      if (it != mapped_replacements_.end()) {
        LOG_INFO_F("[CustomImageCallback] Mapped replacement for image %d: "
                   "%dx%d -> %dx%d",
                   index, orig_width, orig_height, it->second->GetWidth(),
                   it->second->GetHeight());
        return it->second;
      }
      LOG_DEBUG_F(
          "[CustomImageCallback] No mapped replacement for image %d (%dx%d)",
          index, orig_width, orig_height);
      return nullptr;
    }
  }

  return nullptr;
}

void CustomImageCallback::SetGlobalReplacementImage(
    RetainPtr<CFX_DIBitmap> image) {
  global_replacement_ = image;
  if (image) {
    LOG_INFO_F("[CustomImageCallback] Global replacement image set: %dx%d",
               image->GetWidth(), image->GetHeight());
  } else {
    LOG_INFO("[CustomImageCallback] Global replacement image cleared");
  }
}

void CustomImageCallback::SetSizeThreshold(int min_width, int min_height) {
  min_width_ = min_width;
  min_height_ = min_height;
  LOG_INFO_F("[CustomImageCallback] Size threshold set: %dx%d", min_width,
             min_height);
}

void CustomImageCallback::SetConditionalReplacementImage(
    RetainPtr<CFX_DIBitmap> image) {
  conditional_replacement_ = image;
  if (image) {
    LOG_INFO_F("[CustomImageCallback] Conditional replacement image set: %dx%d",
               image->GetWidth(), image->GetHeight());
  } else {
    LOG_INFO("[CustomImageCallback] Conditional replacement image cleared");
  }
}

void CustomImageCallback::RegisterMappedReplacement(
    int index,
    RetainPtr<CFX_DIBitmap> image) {
  mapped_replacements_[index] = image;
  if (image) {
    LOG_INFO_F("[CustomImageCallback] Registered mapped replacement %d: %dx%d",
               index, image->GetWidth(), image->GetHeight());
  }
}

void CustomImageCallback::ClearMappedReplacements() {
  mapped_replacements_.clear();
  LOG_INFO("[CustomImageCallback] Cleared all mapped replacements");
}

bool CustomImageCallback::LoadReplacementImageFromFile(const char* file_path) {
  LOG_INFO_F("[CustomImageCallback] Loading replacement image from: %s",
             file_path);

  // 读取文件数据
  std::vector<uint8_t> file_data = ReadFileData(file_path);
  if (file_data.empty()) {
    LOG_ERROR_F("[CustomImageCallback] Failed to read file: %s", file_path);
    return false;
  }

  // 使用 PDFium 解码器解码图片
  RetainPtr<CFX_DIBitmap> bitmap = DecodeImageFile(file_data);
  if (!bitmap) {
    LOG_ERROR_F("[CustomImageCallback] Failed to decode image: %s", file_path);
    return false;
  }

  // 根据当前模式设置替换图片
  switch (mode_) {
    case ReplacementMode::kGlobal:
      SetGlobalReplacementImage(bitmap);
      break;
    case ReplacementMode::kConditional:
      SetConditionalReplacementImage(bitmap);
      break;
    default:
      LOG_WARNING_F("[CustomImageCallback] LoadReplacementImageFromFile called "
                    "but mode is %d",
                    static_cast<int>(mode_));
      return false;
  }

  LOG_INFO_F("[CustomImageCallback] Successfully loaded image %dx%d from %s",
             bitmap->GetWidth(), bitmap->GetHeight(), file_path);
  return true;
}

int CustomImageCallback::GetImageIndex(CPDF_ImageObject* obj) {
  // 简单实现：按顺序编号
  // 实际应用中可以使用图片对象的哈希值或其他唯一标识
  return image_counter_++;
}

bool CustomImageCallback::ShouldReplaceBySize(int width, int height) const {
  return width >= min_width_ && height >= min_height_;
}

// [AP-FORM-IMAGE-WATERMARK] 重写水印方法，添加开关检查
RetainPtr<CFX_DIBitmap> CustomImageCallback::OnImageRendering(
    CPDF_ImageObject* pImageObj,
    const CFX_Matrix& mtObj2Device,
    RetainPtr<CFX_DIBitmap> pOriginalBitmap) {
  // 检查水印开关
  if (!watermark_enabled_) {
    LOG_DEBUG("[CustomImageCallback] Watermark disabled, returning original");
    return nullptr;  // 返回 nullptr 表示使用原图，不叠加水印
  }

  // 调用父类的水印实现
  LOG_DEBUG("[CustomImageCallback] Watermark enabled, applying watermark");
  return WatermarkCallback::OnImageRendering(pImageObj, mtObj2Device,
                                             pOriginalBitmap);
}
