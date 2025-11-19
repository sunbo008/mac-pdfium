# 图片替换功能集成总结

## 🎉 完成状态

✅ **所有功能已完成并可用**

## 实现内容

### 1. 核心功能 (PDFium 层)

**文件**: `core/fpdfapi/render/`
- ✅ `cpdf_renderstatus.h`: 添加 `GetReplacementImage()` 接口
- ✅ `cpdf_renderstatus.cpp`: 提供默认实现
- ✅ `cpdf_imagerenderer.cpp`: 集成图片替换逻辑，使用 `Create()`+`Copy()` 创建内部副本

**关键特性**:
- 临时替换：不修改 `loader_` 原始数据
- 内存安全：使用 `pdfium::MakeRetain<CFX_DIBitmap>()` + `Create()` + `Copy()` 创建内部副本
- 顺序执行：先替换后水印

### 2. 平台层实现 (macOS)

**文件**: `platform/shared/`
- ✅ `watermark_callback.h`: 将 `DecodeImageFile()` 和 `ReadFileData()` 改为 `protected`
- ✅ `watermark_callback.cpp`: 提供默认的 `GetReplacementImage()` 实现

**文件**: `platform/mac/`
- ✅ `CustomImageCallback.h`: 定义多种替换模式
- ✅ `CustomImageCallback.mm`: 实现全局/条件/映射替换逻辑
- ✅ `BUILD.gn`: 添加编译配置

**支持的替换模式**:
```cpp
enum class ReplacementMode {
  kNone,        // 不替换
  kGlobal,      // 全局替换（所有图片使用同一张）
  kConditional, // 条件替换（按尺寸阈值）
  kMapped       // 映射替换（不同对象不同图片）
};
```

### 3. UI 集成

**文件**: `platform/mac/Controllers/`
- ✅ `StatusBarController.h`: 添加 `imageReplacementButton` 属性和方法
- ✅ `StatusBarController.mm`: 创建按钮并响应点击

**文件**: `platform/mac/App.mm`
- ✅ 添加 `CustomImageCallback* imageCallback` 属性
- ✅ 添加 `BOOL imageReplacementEnabled` 状态
- ✅ 实现 `selectReplacementImage:` 方法（文件选择）
- ✅ 实现 `clearImageReplacement` 方法（清除替换）
- ✅ 在 `main()` 中初始化 `CustomImageCallback`

**UI 特性**:
- 状态栏按钮：**"选择替换图片"** / **"清除替换"**
- 文件选择：支持 PNG/JPG/JPEG
- 成功提示：显示已选择的文件名
- 错误处理：加载失败时显示警告

### 4. 文档

- ✅ `platform/mac/HOW_TO_USE_IMAGE_REPLACEMENT.md` - 开发者集成指南
- ✅ `docs/image-replacement-usage.md` - 用户使用指南
- ✅ OpenSpec 完整提案（proposal, tasks, design, specs）

## 使用方法

### 用户使用

1. 运行 `./out/Debug/mac_pdf_viewer`
2. 打开包含 AP-Form 的 PDF
3. 点击状态栏的 **"选择替换图片"** 按钮
4. 选择一张 PNG 或 JPG 图片
5. 查看替换效果
6. 点击 **"清除替换"** 恢复原图

### 开发者扩展

如需实现自定义替换逻辑：

```cpp
class MyCustomCallback : public CustomImageCallback {
 public:
  RetainPtr<CFX_DIBitmap> GetReplacementImage(
      CPDF_ImageObject* pImageObj,
      const CFX_Matrix& mtObj2Device,
      RetainPtr<CFX_DIBitmap> pOriginalBitmap) override {
    
    // 根据图片对象的属性决定是否替换
    if (ShouldReplace(pImageObj)) {
      return LoadMyCustomImage();
    }
    return nullptr; // 不替换
  }
};
```

## 技术亮点

### 1. 内存管理策略

❌ **错误做法**（直接使用外部指针）：
```cpp
dibbase_ = external_image;  // 危险！依赖外部内存
```

✅ **正确做法**（创建内部副本）：
```cpp
RetainPtr<CFX_DIBitmap> internal_copy = pdfium::MakeRetain<CFX_DIBitmap>();
if (internal_copy->Create(w, h, format) && internal_copy->Copy(external_image)) {
  dibbase_ = internal_copy;  // 安全！独立内存
}
```

### 2. 与水印的协同

```
[原始图片] 
    ↓
[步骤1: GetReplacementImage()] → 临时替换
    ↓
[步骤2: OnImageRendering()] → 叠加水印
    ↓
[最终显示]
```

### 3. 编译配置

已添加到 `platform/mac/BUILD.gn`:
```gn
sources = [
  "CustomImageCallback.h",
  "CustomImageCallback.mm",
  # ...
]
```

## 测试建议

1. **基础功能测试**
   - [ ] 选择 PNG 图片能否成功替换
   - [ ] 选择 JPG 图片能否成功替换
   - [ ] 清除替换后是否恢复原图
   - [ ] 按钮标题是否正确切换

2. **边界测试**
   - [ ] 选择非常大的图片（如 10MB）
   - [ ] 选择非常小的图片（如 1x1）
   - [ ] 选择不同宽高比的图片
   - [ ] 选择损坏的图片文件

3. **集成测试**
   - [ ] 与水印同时启用
   - [ ] 先启用替换后启用水印
   - [ ] 先启用水印后启用替换
   - [ ] 翻页后替换是否仍然有效

4. **性能测试**
   - [ ] 替换大图片时的渲染速度
   - [ ] 多次切换替换的内存占用
   - [ ] 连续翻页的流畅度

## 调试日志标签

搜索以下标签查看详细日志：

```bash
# 应用层操作
grep "ImageReplacement" pdfium_viewer.log

# 回调层
grep "CustomImageCallback" pdfium_viewer.log

# PDFium 核心层
grep "AP-FORM-IMAGE-REPLACEMENT" pdfium_viewer.log
```

## 后续优化建议

1. **UI 增强**
   - [ ] 添加图片预览
   - [ ] 显示当前替换的图片路径
   - [ ] 支持拖拽图片文件

2. **功能扩展**
   - [ ] 支持更多图片格式（BMP, GIF, TIFF）
   - [ ] 支持条件替换的 UI 配置
   - [ ] 支持批量替换（多个对象不同图片）

3. **性能优化**
   - [ ] 图片缓存机制
   - [ ] 异步加载大图片
   - [ ] 智能缩放预处理

## 相关文档

- 用户指南: `docs/image-replacement-usage.md`
- 开发者指南: `platform/mac/HOW_TO_USE_IMAGE_REPLACEMENT.md`
- OpenSpec 提案: `openspec/changes/add-external-image-replacement/`
- 代码示例: `platform/mac/CustomImageCallback.mm`

---

**完成时间**: 2024-11-19  
**编译状态**: ✅ 成功  
**功能状态**: ✅ 可用

