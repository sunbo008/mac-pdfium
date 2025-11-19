# Implementation Tasks

## 1. 扩展接口定义

- [X] 1.1 在 `CPDF_RenderStatus::ImageCallbackIface` 中添加 `GetReplacementImage()` 方法
- [X] 1.2 定义方法签名：`RetainPtr<CFX_DIBitmap> GetReplacementImage(CPDF_ImageObject*, const CFX_Matrix&, RetainPtr<CFX_DIBitmap>)`
- [X] 1.3 添加方法文档注释，说明返回 `nullptr` 表示使用原图，返回非空表示替换
- [X] 1.4 说明方法语义：主动请求替换图片（Get 语义），与 `OnImageRendering` 的通知语义形成对比

## 2. 修改 CPDF_ImageRenderer 核心逻辑

- [X] 2.1 在 `StartRenderDIBBase()` 中添加图片替换检查点
- [X] 2.2 在获取 `loader_->GetBitmap()` 后、应用水印前调用 `GetReplacementImage()`
- [X] 2.3 如果回调返回替换图片，调用 `external_image->Clone(nullptr)` 创建内部副本
- [X] 2.4 检查 Clone 是否成功，失败则记录警告并使用原图
- [X] 2.5 将 `dibbase_` 指向内部副本（不修改 `loader_`，不依赖外部数据）
- [X] 2.6 确保 `loader_` 原始数据保持不变，仅修改 `dibbase_` 成员变量
- [X] 2.7 添加调试日志记录图片尺寸、Clone 操作和内存地址

## 3. 实现回调接口

- [X] 3.1 在 `WatermarkCallback` 类中实现 `GetReplacementImage()` 方法
- [X] 3.2 添加外部图片源管理说明（默认返回 nullptr，应用层可重写）
- [X] 3.3 验证无需实现图片尺寸适配（由 PDFium 自动处理）
- [X] 3.4 处理错误情况（默认实现返回 `nullptr`）
- [X] 3.5 说明外部可以使用临时数据（PDFium 会创建副本，外部可立即释放）

## 4. 集成到 macOS 平台

- [x] 4.1 创建使用指南文档 `docs/ap-form-image-replacement-usage.md`
- [x] 4.2 创建 `CustomImageCallback` 类提供完整的应用层实现
- [x] 4.3 实现多种替换模式（全局/条件/映射）
- [x] 4.4 提供从文件加载图片的方法
- [x] 4.5 添加到 BUILD.gn 编译系统

## 5. 测试和文档

- [X] 5.1 创建完整的使用指南，包含多个示例
- [X] 5.2 说明与水印功能的配合使用
- [X] 5.3 说明内存管理和安全策略
- [X] 5.4 说明性能考虑和最佳实践
- [ ] 5.5 编写单元测试验证图片替换逻辑和 Clone 操作（可选）
- [ ] 5.6 测试 AP-Form 场景下的实际替换（需要应用层实现）
- [X] 5.7 文档化调试日志格式
- [X] 5.8 提供完整代码示例
