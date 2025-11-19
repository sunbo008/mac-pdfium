# Change: 添加 AP-Form 图片外部替换能力

## Why
当前的 AP-Form 图片水印功能可以在渲染时叠加水印，但无法完全替换原始图片。在某些场景下（如敏感信息保护、动态内容替换），需要能够从外部加载一张图片，在 PDFium 渲染 AP-Form 图片时，临时用外部图片替换当前渲染使用的位图，而不修改 `loader_` 中的原始缓存数据。

这个功能扩展了现有的图片回调机制，允许应用层在渲染前提供替换图片，用于当前渲染周期，同时保持 `loader_` 的原始数据不变，确保其他渲染操作不受影响。

## What Changes
- 在 `CPDF_ImageRenderer::StartRenderDIBBase()` 中添加图片临时替换回调点
- 扩展现有的 `ImageCallbackIface` 接口，添加 `GetReplacementImage()` 方法
- 方法语义：主动请求替换图片（Get），而非被动通知（On）
- **内存管理策略**：使用 `Clone()` 创建外部图片的内部副本，不依赖外部临时数据
- 替换策略：修改 `dibbase_` 成员变量指向内部副本，而不修改 `loader_` 的内部数据
- 支持外部提供任意尺寸的 `CFX_DIBitmap` 对象（可以是临时的），由 PDFium 自动缩放
- 使用 `RetainPtr` 智能指针管理内部副本的生命周期
- 保持 `loader_` 原始数据不变，确保多次渲染的独立性
- 外部可以在回调返回后立即释放临时图片，不影响 PDFium 内部渲染
- 保持现有水印功能（`OnImageRendering()`）不受影响
- 添加日志记录以便追踪图片替换和内存操作

## Impact
- **受影响的规范**: 新增 `image-rendering` capability
- **受影响的代码**:
  - `core/fpdfapi/render/cpdf_imagerenderer.cpp`: 添加图片替换逻辑
  - `core/fpdfapi/render/cpdf_imagerenderer.h`: 添加成员变量和方法声明
  - `core/fpdfapi/render/cpdf_renderstatus.h`: 扩展 `ImageCallbackIface` 接口
  - `platform/shared/watermark_callback.h/cpp`: 实现新的接口方法
  - `platform/mac/PdfView.mm`: 提供外部图片加载机制
- **向后兼容**: 完全兼容，新的接口方法为可选实现