// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef PLATFORM_MAC_CUSTOM_IMAGE_CALLBACK_H_
#define PLATFORM_MAC_CUSTOM_IMAGE_CALLBACK_H_

#include <map>
#include <string>
#include "platform/shared/watermark_callback.h"
#include "core/fxcrt/retain_ptr.h"

class CFX_DIBitmap;
class CPDF_ImageObject;
class CFX_Matrix;

// [AP-FORM-IMAGE-REPLACEMENT] macOS 应用层图片替换回调
// 提供多种替换策略：
// 1. 全局替换：所有图片使用同一张替换图片
// 2. 条件替换：根据图片大小等条件决定是否替换
// 3. 映射替换：为不同图片对象提供不同的替换图片
class CustomImageCallback : public WatermarkCallback {
 public:
  enum class ReplacementMode {
    kNone,        // 不替换
    kGlobal,      // 全局替换
    kConditional, // 条件替换
    kMapped       // 映射替换
  };
  
  CustomImageCallback();
  ~CustomImageCallback() override;
  
  // ImageCallbackIface 实现
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override;
  
  RetainPtr<CFX_DIBitmap> OnImageRendering(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override;
  
  // 配置接口
  void SetReplacementMode(ReplacementMode mode) { mode_ = mode; }
  ReplacementMode GetReplacementMode() const { return mode_; }
  
  // 开关控制
  void SetReplacementEnabled(bool enabled) { replacement_enabled_ = enabled; }
  bool IsReplacementEnabled() const { return replacement_enabled_; }
  
  void SetWatermarkEnabled(bool enabled) { watermark_enabled_ = enabled; }
  bool IsWatermarkEnabled() const { return watermark_enabled_; }
  
  // 全局替换：设置统一的替换图片
  void SetGlobalReplacementImage(RetainPtr<CFX_DIBitmap> image);
  
  // 条件替换：设置尺寸阈值
  void SetSizeThreshold(int min_width, int min_height);
  void SetConditionalReplacementImage(RetainPtr<CFX_DIBitmap> image);
  
  // 映射替换：注册特定索引的替换图片
  void RegisterMappedReplacement(int index, RetainPtr<CFX_DIBitmap> image);
  void ClearMappedReplacements();
  
  // 从文件加载替换图片
  bool LoadReplacementImageFromFile(const char* file_path);
  
 private:
  ReplacementMode mode_;
  bool replacement_enabled_;  // 图片替换开关
  bool watermark_enabled_;    // 水印开关
  
  // 全局替换图片
  RetainPtr<CFX_DIBitmap> global_replacement_;
  
  // 条件替换
  int min_width_;
  int min_height_;
  RetainPtr<CFX_DIBitmap> conditional_replacement_;
  
  // 映射替换
  std::map<int, RetainPtr<CFX_DIBitmap>> mapped_replacements_;
  int image_counter_;
  
  // 辅助方法
  int GetImageIndex(CPDF_ImageObject* obj);
  bool ShouldReplaceBySize(int width, int height) const;
};

#endif  // PLATFORM_MAC_CUSTOM_IMAGE_CALLBACK_H_

