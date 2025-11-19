# AP-Form 图片替换功能使用指南

## 概述

AP-Form 图片替换功能允许应用层在 PDFium 渲染 AP-Form 图片时，提供外部图片来临时替换原始图片。该功能通过扩展 `ImageCallbackIface` 接口实现，支持任意尺寸的替换图片，PDFium 会自动创建内部副本并处理缩放。

## 核心特性

- ✅ **临时替换**：仅影响当前渲染，不修改 `loader_` 的原始数据
- ✅ **内存安全**：PDFium 使用 `Clone()` 创建内部副本，不依赖外部数据
- ✅ **任意尺寸**：支持不同尺寸的替换图片，自动缩放适配
- ✅ **完全兼容**：与现有水印功能（`OnImageRendering`）完美配合
- ✅ **向后兼容**：默认实现返回 `nullptr`，不影响现有代码

## 接口定义

```cpp
class ImageCallbackIface {
 public:
  // 获取替换图片（在图片加载后、渲染前调用）
  // 参数：
  //   - pImageObj: 当前图片对象
  //   - mtObj2Device: 图片的变换矩阵
  //   - pOriginalBitmap: 原始位图
  // 返回：
  //   - nullptr: 使用原图
  //   - 非空: 使用替换图片（PDFium 会创建内部副本）
  virtual RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) {
    return nullptr;  // 默认：不替换
  }
  
  // 叠加水印（在替换后的图片上）
  virtual RetainPtr<CFX_DIBitmap> OnImageRendering(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) = 0;
};
```

## 使用方法

### 方法 1: 继承 WatermarkCallback 并重写

```cpp
// 自定义回调类
class CustomImageCallback : public WatermarkCallback {
 public:
  // 重写 GetReplacementImage 方法
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    // 示例1: 根据原图尺寸决定是否替换
    if (pOriginalBitmap->GetWidth() < 100) {
      return nullptr;  // 小图不替换
    }
    
    // 示例2: 从外部文件加载替换图片
    RetainPtr<CFX_DIBitmap> replacement = LoadImageFromFile("/path/to/replacement.jpg");
    
    // 注意：replacement 可以是临时数据，PDFium 会创建内部副本
    return replacement;
  }
  
 private:
  RetainPtr<CFX_DIBitmap> LoadImageFromFile(const char* path) {
    // 从文件加载图片的实现
    // ...
  }
};

// 使用自定义回调
auto callback = std::make_unique<CustomImageCallback>();
render_status->SetImageCallback(callback.get());
```

### 方法 2: 使用图片对象 ID 映射

```cpp
class ImageReplacementCallback : public WatermarkCallback {
 public:
  // 注册替换图片
  void RegisterReplacement(int image_id, RetainPtr<CFX_DIBitmap> replacement) {
    replacements_[image_id] = replacement;
  }
  
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    // 根据图片对象查找替换图片
    int image_id = GetImageObjectId(pImageObj);
    
    auto it = replacements_.find(image_id);
    if (it != replacements_.end()) {
      LOG_INFO_F("[ImageReplacement] Found replacement for image %d", image_id);
      return it->second;  // PDFium 会创建副本
    }
    
    return nullptr;  // 没有替换图片
  }
  
 private:
  std::map<int, RetainPtr<CFX_DIBitmap>> replacements_;
  
  int GetImageObjectId(CPDF_ImageObject* obj) {
    // 获取图片对象的唯一标识
    // ...
  }
};
```

### 方法 3: 动态加载替换图片

```cpp
class DynamicImageCallback : public WatermarkCallback {
 public:
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    // 示例：从网络或数据库动态获取替换图片
    std::string image_url = GetImageUrl(pImageObj);
    
    if (!image_url.empty()) {
      // 临时加载图片（可以在回调返回后立即释放）
      RetainPtr<CFX_DIBitmap> temp_image = DownloadImage(image_url);
      
      // PDFium 会创建内部副本，所以 temp_image 可以是临时的
      return temp_image;
    }
    
    return nullptr;
  }
};
```

## 工作流程

```
1. CPDF_ImageLoader 加载原始图片
   ↓
2. loader_->GetBitmap() 返回原始位图
   ↓
3. 调用 GetReplacementImage() 回调
   ↓
4. 如果返回替换图片：
   - 调用 replacement->Clone(nullptr) 创建内部副本
   - dibbase_ = internal_copy
   ↓
5. 调用 OnImageRendering() 叠加水印（在替换后的图片上）
   ↓
6. 使用 dibbase_ 进行渲染
```

## 内存管理说明

### ✅ 安全的做法

```cpp
RetainPtr<CFX_DIBitmap> GetReplacementImage(...) {
  // 方式1: 返回临时数据（推荐）
  {
    RetainPtr<CFX_DIBitmap> temp = LoadFromFile("temp.jpg");
    return temp;  
    // PDFium 会创建副本，temp 可以在这里释放
  }
  
  // 方式2: 返回成员变量（需要确保生命周期）
  if (!cached_replacement_) {
    cached_replacement_ = LoadFromFile("cached.jpg");
  }
  return cached_replacement_;  // PDFium 会创建副本
}
```

### ❌ 不需要担心的问题

```cpp
// 不需要：手动创建副本
RetainPtr<CFX_DIBitmap> copy = image->Clone(nullptr);
return copy;  // PDFium 会再次 Clone，浪费性能

// 不需要：保持外部图片有效
// PDFium 会创建内部副本，外部图片可以立即释放
```

## 完整示例

```cpp
// my_pdf_view.mm

class MyImageReplacementCallback : public WatermarkCallback {
 public:
  MyImageReplacementCallback() {
    // 预加载替换图片
    replacement_image_ = LoadReplacementImage();
  }
  
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    // 检查是否需要替换
    if (ShouldReplace(pImageObj)) {
      LOG_INFO_F("[MyApp] Replacing image %dx%d with %dx%d",
                 pOriginalBitmap->GetWidth(), pOriginalBitmap->GetHeight(),
                 replacement_image_->GetWidth(), replacement_image_->GetHeight());
      return replacement_image_;
    }
    
    return nullptr;
  }
  
 private:
  RetainPtr<CFX_DIBitmap> replacement_image_;
  
  bool ShouldReplace(CPDF_ImageObject* obj) {
    // 根据应用逻辑决定是否替换
    return true;  // 示例：总是替换
  }
  
  RetainPtr<CFX_DIBitmap> LoadReplacementImage() {
    // 从应用资源加载
    NSString* path = [[NSBundle mainBundle] pathForResource:@"replacement" ofType:@"png"];
    // ... 加载实现
  }
};

// 在 PdfView 中使用
- (void)setupRendering {
  auto callback = std::make_unique<MyImageReplacementCallback>();
  render_status_->SetImageCallback(callback.get());
  render_status_->SetInAppearanceForm(true);
}
```

## 调试日志

启用调试日志以追踪图片替换过程：

```
[AP-FORM-IMAGE-REPLACEMENT] Image render check: in_appearance_form_=true, image_callback_=valid
[AP-FORM-IMAGE-REPLACEMENT] Got replacement image 1000x1000 (original: 200x200)
[AP-FORM-IMAGE-REPLACEMENT] Created internal copy at 0x7f8..., size 1000x1000
[AP-FORM-IMAGE-WATERMARK] Applied watermark
```

## 性能考虑

1. **Clone 开销**: PDFium 会调用 `Clone()` 创建副本，对于大图片（如 4K 图片）约需几毫秒
2. **缓存策略**: 应用层应缓存常用的替换图片以避免重复加载
3. **异步加载**: 对于网络图片，建议预加载或使用缓存

## 注意事项

1. ✅ 替换图片可以是任意尺寸，PDFium 会自动缩放
2. ✅ 替换图片可以是临时数据，PDFium 会创建内部副本
3. ✅ 替换在水印之前执行，水印会叠加在替换后的图片上
4. ✅ 仅在 AP-Form 上下文中启用（需要设置 `SetInAppearanceForm(true)`）
5. ⚠️ 默认实现返回 `nullptr`，需要重写方法以提供实际替换图片

## 与水印功能的关系

| 功能 | 时机 | 用途 | 接口方法 |
|------|------|------|----------|
| 图片替换 | 渲染前 | 完全替换原图 | `GetReplacementImage()` |
| 水印叠加 | 渲染时 | 叠加水印 | `OnImageRendering()` |

执行顺序：**替换 → 水印 → 渲染**

## 更多信息

- 设计文档: `openspec/changes/add-external-image-replacement/design.md`
- 任务清单: `openspec/changes/add-external-image-replacement/tasks.md`
- 规范定义: `openspec/changes/add-external-image-replacement/specs/image-rendering/spec.md`

