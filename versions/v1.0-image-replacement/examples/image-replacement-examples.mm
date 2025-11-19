// 示例文件：如何在 macOS 应用中实现图片替换
// 注意：这是一个示例文件，不会被编译，仅供参考

#import <Foundation/Foundation.h>
#import "platform/shared/watermark_callback.h"
#import "platform/shared/logger.h"
#import "core/fxge/dib/cfx_dibitmap.h"

// ============================================================================
// 示例 1: 简单替换 - 所有图片都用同一张替换图片
// ============================================================================

class SimpleReplacementCallback : public WatermarkCallback {
 public:
  SimpleReplacementCallback() {
    // 从应用资源加载替换图片
    replacement_image_ = LoadReplacementFromBundle();
  }
  
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    if (replacement_image_) {
      LOG_INFO_F("[SimpleReplacement] Replacing all images with %dx%d",
                 replacement_image_->GetWidth(), 
                 replacement_image_->GetHeight());
      return replacement_image_;
    }
    
    return nullptr;  // 没有替换图片
  }
  
 private:
  RetainPtr<CFX_DIBitmap> replacement_image_;
  
  RetainPtr<CFX_DIBitmap> LoadReplacementFromBundle() {
    // 从 Bundle 加载图片的实现
    // ... (见下面的辅助函数)
    return nullptr;
  }
};

// ============================================================================
// 示例 2: 条件替换 - 根据原图大小决定是否替换
// ============================================================================

class ConditionalReplacementCallback : public WatermarkCallback {
 public:
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    int width = pOriginalBitmap->GetWidth();
    int height = pOriginalBitmap->GetHeight();
    
    // 只替换大于 200x200 的图片
    if (width > 200 && height > 200) {
      LOG_INFO_F("[ConditionalReplacement] Replacing large image %dx%d", 
                 width, height);
      return LoadLargeReplacement();
    }
    
    // 小图不替换
    LOG_DEBUG_F("[ConditionalReplacement] Keeping small image %dx%d", 
                width, height);
    return nullptr;
  }
  
 private:
  RetainPtr<CFX_DIBitmap> LoadLargeReplacement() {
    // 加载大图替换图片
    return nullptr;
  }
};

// ============================================================================
// 示例 3: 映射替换 - 为不同图片提供不同的替换
// ============================================================================

class MappedReplacementCallback : public WatermarkCallback {
 public:
  // 注册替换映射
  void RegisterReplacement(int image_index, 
                          RetainPtr<CFX_DIBitmap> replacement) {
    replacements_[image_index] = replacement;
    LOG_INFO_F("[MappedReplacement] Registered replacement for image %d", 
               image_index);
  }
  
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    // 获取图片索引（这里需要实现获取方法）
    int index = GetImageIndex(pImageObj);
    
    auto it = replacements_.find(index);
    if (it != replacements_.end()) {
      LOG_INFO_F("[MappedReplacement] Found replacement for image %d", index);
      return it->second;
    }
    
    LOG_DEBUG_F("[MappedReplacement] No replacement for image %d", index);
    return nullptr;
  }
  
 private:
  std::map<int, RetainPtr<CFX_DIBitmap>> replacements_;
  int image_counter_ = 0;
  
  int GetImageIndex(CPDF_ImageObject* obj) {
    // 简单实现：按顺序编号
    // 实际应用中可以用图片的哈希值或其他唯一标识
    return image_counter_++;
  }
};

// ============================================================================
// 在 PdfView 中使用示例
// ============================================================================

/*
// 在你的 PdfView.h 中添加：
@interface PdfView : NSView {
  std::unique_ptr<SimpleReplacementCallback> image_callback_;
}
- (void)setupImageReplacement;
@end

// 在 PdfView.mm 中实现：
- (void)setupImageReplacement {
  // 方式 1: 使用简单替换
  image_callback_ = std::make_unique<SimpleReplacementCallback>();
  
  // 方式 2: 使用条件替换
  // image_callback_ = std::make_unique<ConditionalReplacementCallback>();
  
  // 方式 3: 使用映射替换
  // auto mapped_callback = std::make_unique<MappedReplacementCallback>();
  // 从文件加载图片
  // RetainPtr<CFX_DIBitmap> img1 = LoadImageFromFile(@"/path/to/image1.png");
  // RetainPtr<CFX_DIBitmap> img2 = LoadImageFromFile(@"/path/to/image2.png");
  // mapped_callback->RegisterReplacement(0, img1);
  // mapped_callback->RegisterReplacement(1, img2);
  // image_callback_ = std::move(mapped_callback);
}

- (void)renderPage:(CPDF_Page*)page {
  // 设置回调到渲染状态
  if (image_callback_) {
    render_status_->SetImageCallback(image_callback_.get());
    render_status_->SetInAppearanceForm(true);
  }
  
  // 继续渲染...
}
*/

// ============================================================================
// 辅助函数：从 macOS 文件系统加载图片
// ============================================================================

RetainPtr<CFX_DIBitmap> LoadImageFromFile(NSString* filePath) {
  // 1. 读取文件数据
  NSData* data = [NSData dataWithContentsOfFile:filePath];
  if (!data) {
    LOG_ERROR_F("Failed to load image from %s", [filePath UTF8String]);
    return nullptr;
  }
  
  // 2. 转换为 std::vector
  std::vector<uint8_t> file_data;
  file_data.assign((const uint8_t*)[data bytes],
                   (const uint8_t*)[data bytes] + [data length]);
  
  // 3. 使用 PDFium 解码器解码
  // 参考 platform/shared/watermark_callback.cpp 中的 DecodeImageFile 方法
  // 这里需要根据文件类型选择合适的解码器（JPEG/PNG 等）
  
  LOG_INFO_F("Loaded image from %s, size: %zu bytes", 
             [filePath UTF8String], file_data.size());
  
  // TODO: 实现实际的解码逻辑
  return nullptr;
}

RetainPtr<CFX_DIBitmap> LoadImageFromBundle(NSString* resourceName, 
                                             NSString* fileType) {
  NSString* path = [[NSBundle mainBundle] pathForResource:resourceName 
                                                    ofType:fileType];
  if (!path) {
    LOG_ERROR_F("Resource not found: %s.%s", 
                [resourceName UTF8String], [fileType UTF8String]);
    return nullptr;
  }
  
  return LoadImageFromFile(path);
}

// ============================================================================
// 使用示例总结
// ============================================================================

/*
步骤 1: 选择一个示例类（Simple/Conditional/Mapped）
步骤 2: 在你的 PdfView 中创建该类的实例
步骤 3: 在渲染前设置 render_status_->SetImageCallback()
步骤 4: 设置 render_status_->SetInAppearanceForm(true)
步骤 5: 提供替换图片（从文件、Bundle 或内存加载）

日志示例：
[CustomImageCallback] Created
[CustomImageCallback] Replacement image set: 1000x1000
[AP-FORM-IMAGE-REPLACEMENT] Got replacement image 1000x1000 (original: 200x200)
[AP-FORM-IMAGE-REPLACEMENT] Created internal copy at 0x7f8..., size 1000x1000
*/

