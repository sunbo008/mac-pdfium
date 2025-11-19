# 如何使用图片替换功能

## 快速开始

`CustomImageCallback` 类已经为你实现好了，提供三种替换模式。

### 方式 1: 全局替换（最简单）

所有图片都用同一张替换图片。

```objc
// 在你的 PdfView 或 ViewController 中

#import "platform/mac/CustomImageCallback.h"

@interface YourViewController () {
  std::unique_ptr<CustomImageCallback> image_callback_;
}
@end

@implementation YourViewController

- (void)setupImageReplacement {
  // 1. 创建回调实例
  image_callback_ = std::make_unique<CustomImageCallback>();
  
  // 2. 设置为全局替换模式
  image_callback_->SetReplacementMode(
      CustomImageCallback::ReplacementMode::kGlobal);
  
  // 3. 从文件加载替换图片
  NSString* imagePath = [[NSBundle mainBundle] 
      pathForResource:@"my_replacement" ofType:@"png"];
  
  image_callback_->LoadReplacementImageFromFile([imagePath UTF8String]);
  
  // 完成！
}

- (void)renderPage {
  // 在渲染时启用回调
  render_status->SetImageCallback(image_callback_.get());
  render_status->SetInAppearanceForm(true);
  
  // 继续正常渲染...
}

@end
```

### 方式 2: 条件替换

只替换大于特定尺寸的图片。

```objc
- (void)setupConditionalReplacement {
  image_callback_ = std::make_unique<CustomImageCallback>();
  
  // 设置为条件替换模式
  image_callback_->SetReplacementMode(
      CustomImageCallback::ReplacementMode::kConditional);
  
  // 设置阈值：只替换大于 200x200 的图片
  image_callback_->SetSizeThreshold(200, 200);
  
  // 加载替换图片
  NSString* path = @"/path/to/replacement.png";
  image_callback_->LoadReplacementImageFromFile([path UTF8String]);
}
```

### 方式 3: 映射替换

为不同的图片提供不同的替换。

```objc
- (void)setupMappedReplacement {
  image_callback_ = std::make_unique<CustomImageCallback>();
  
  // 设置为映射替换模式
  image_callback_->SetReplacementMode(
      CustomImageCallback::ReplacementMode::kMapped);
  
  // 加载多张替换图片
  RetainPtr<CFX_DIBitmap> image1 = LoadImageFromFile(@"/path/to/image1.png");
  RetainPtr<CFX_DIBitmap> image2 = LoadImageFromFile(@"/path/to/image2.png");
  
  // 注册映射（图片索引从 0 开始）
  image_callback_->RegisterMappedReplacement(0, image1);
  image_callback_->RegisterMappedReplacement(1, image2);
}
```

## 在 PdfView 中集成

如果你想在 PdfView 中直接使用，可以这样修改：

```objc
// PdfView.h
#import "platform/mac/CustomImageCallback.h"

@interface PdfView : NSView {
  std::unique_ptr<CustomImageCallback> image_callback_;
}

// 添加配置方法
- (void)enableImageReplacement:(BOOL)enable;
- (void)setReplacementImagePath:(NSString*)path;

@end

// PdfView.mm
@implementation PdfView

- (void)awakeFromNib {
  [super awakeFromNib];
  
  // 初始化图片替换
  image_callback_ = std::make_unique<CustomImageCallback>();
  image_callback_->SetReplacementMode(
      CustomImageCallback::ReplacementMode::kGlobal);
}

- (void)enableImageReplacement:(BOOL)enable {
  if (enable) {
    image_callback_->SetReplacementMode(
        CustomImageCallback::ReplacementMode::kGlobal);
  } else {
    image_callback_->SetReplacementMode(
        CustomImageCallback::ReplacementMode::kNone);
  }
}

- (void)setReplacementImagePath:(NSString*)path {
  if (path) {
    image_callback_->LoadReplacementImageFromFile([path UTF8String]);
  }
}

// 在渲染方法中使用
- (void)renderCurrentPage {
  // ... 创建 render_status ...
  
  // 设置图片回调
  if (image_callback_) {
    render_status->SetImageCallback(image_callback_.get());
    render_status->SetInAppearanceForm(true);
  }
  
  // ... 继续渲染 ...
}

@end
```

## 测试

```bash
# 编译
cd /Volumes/Lzf-MoveDisk/workspace/github/mac-pdfium
./build_mac.sh

# 运行
open out/Debug/PdfWinViewer.app

# 查看日志
tail -f out/Debug/PdfWinViewer.app/Contents/MacOS/debug.log | grep IMAGE-REPLACEMENT
```

## 预期日志输出

```
[CustomImageCallback] Created, mode=None
[CustomImageCallback] Global replacement image set: 1000x1000
[CustomImageCallback] Global replacement: 200x200 -> 1000x1000
[AP-FORM-IMAGE-REPLACEMENT] Got replacement image 1000x1000 (original: 200x200)
[AP-FORM-IMAGE-REPLACEMENT] Created internal copy at 0x7f8..., size 1000x1000
```

## 提供替换图片的位置

你需要提供替换图片文件，可以放在：
1. 应用 Bundle 的 Resources 目录
2. 任意文件系统路径
3. 通过代码动态加载

就这么简单！`CustomImageCallback` 已经帮你处理了所有复杂的逻辑。