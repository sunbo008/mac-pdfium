# Design: AP-Form 图片外部替换能力

## Context
当前 PDFium 的 `CPDF_ImageRenderer` 通过 `CPDF_ImageLoader` 加载图片数据，并在 `StartRenderDIBBase()` 中准备渲染。现有的水印功能在渲染阶段叠加水印图片，但无法完全替换原始图片内容。

### 背景
- 图片渲染流程：`CPDF_ImageLoader::Start()` → `loader_->GetBitmap()` → `StartRenderDIBBase()` → 渲染到设备
- 现有回调机制在渲染阶段工作（`OnImageRendering()`），此时位图已经准备好
- 需求是在渲染前临时替换 `loader_` 中的图片，用于本次渲染，而不修改 `loader_` 的原始数据
- `loader_` 保持原始状态，替换仅在当前渲染周期有效

### 约束
- 必须保持现有水印功能向后兼容
- 不能破坏 PDFium 的内存管理机制（使用 `RetainPtr` 智能指针）
- 替换图片可以是任意尺寸，PDFium 的现有变换矩阵会自动处理缩放
- **不修改 `loader_` 的原始数据**，替换仅影响 `dibbase_` 用于当前渲染
- 仅在 AP-Form 上下文中启用（通过 `in_appearance_form_` 标志判断）

## Goals / Non-Goals

### Goals
- 允许外部应用在渲染前临时替换位图数据用于本次渲染
- 提供清晰的回调接口，返回值语义明确
- 支持完全替换（而非叠加）原始图片
- 支持任意尺寸的替换图片，由 PDFium 自动缩放适配
- 保持 `loader_` 原始数据不变，替换图片仅在当前渲染周期有效
- 使用 `RetainPtr` 确保替换图片的内存安全管理

### Non-Goals
- 不修改 `loader_` 的内部状态或缓存数据
- 不支持非 AP-Form 场景的图片替换（可以后续扩展）
- 不提供图片缓存管理（使用现有的 `CPDF_PageImageCache`）
- 不修改图片的变换矩阵（使用原图的变换矩阵）

## Decisions

### Decision 1: 回调时机和替换策略
**选择**: 在 `StartRenderDIBBase()` 中，从 `loader_->GetBitmap()` 获取原始位图后，调用 `GetReplacementImage()` 回调，如果返回替换位图，则将 `dibbase_` 指向替换位图而非原始位图

**理由**:
- 此时原始位图已经加载完成，可以获取其尺寸信息
- `dibbase_` 是 `CPDF_ImageRenderer` 的成员变量，用于后续渲染
- 替换 `dibbase_` 不影响 `loader_` 的内部状态
- 还未应用转换函数和颜色处理，替换操作更简单
- 在水印回调之前，可以先替换再叠加水印

**内存管理（正确做法 - 创建内部副本）**:
```cpp
// loader_->GetBitmap() 返回 RetainPtr<CFX_DIBBase>
dibbase_ = loader_->GetBitmap();  // 原始引用，增加引用计数

// 调用回调获取替换图片（外部可能是临时数据）
RetainPtr<CFX_DIBitmap> external_image = callback->GetReplacementImage(...);

if (external_image) {
  // 创建内部副本，不依赖外部内存
  RetainPtr<CFX_DIBitmap> internal_copy = external_image->Clone(nullptr);
  
  if (internal_copy) {
    dibbase_ = internal_copy;  // 指向 PDFium 内部管理的副本
    // 外部的 external_image 可以随时释放，不影响渲染
    // internal_copy 由 PDFium 的 RetainPtr 管理生命周期
  }
}
```

**为什么需要 Clone**:
- 外部提供的图片可能是临时的（如从文件即时加载）
- 外部内存可能在回调返回后被释放
- PDFium 的渲染是异步的，可能在回调返回后才真正使用图片
- `Clone()` 创建完全独立的副本，由 PDFium 内部管理

**替代方案**:
- 在 `StartLoadDIBBase()` 中替换：太早，位图还未加载
- 在渲染循环中替换：太晚，已经开始绘制
- 修改 `loader_` 内部数据：破坏缓存，影响其他渲染

### Decision 2: 接口设计
**选择**: 扩展 `ImageCallbackIface` 添加新方法 `GetReplacementImage`
```cpp
virtual RetainPtr<CFX_DIBitmap> GetReplacementImage(
    CPDF_ImageObject* image_object,
    const CFX_Matrix& image_matrix,
    RetainPtr<CFX_DIBitmap> original_bitmap) {
  return nullptr;  // 默认实现：不替换
}
```

**命名理由**:
- `GetReplacementImage` 清晰表达"获取替换图片"的语义
- 不会与"加载完成通知"混淆
- 与现有 `OnImageRendering()` 形成对比：
  - `GetReplacementImage`: 主动请求替换（Get 语义）
  - `OnImageRendering`: 被动通知渲染（On 语义）

**参数和返回值**:
- 返回 `nullptr` 表示不替换，使用原图（向后兼容）
- 返回非空表示使用替换图片
- 传递 `image_object` 允许应用层根据对象属性决定是否替换
- 传递 `original_bitmap` 允许应用层参考原图尺寸和格式

**替代方案**:
- `OnImageLoaded`: 容易误解为"加载通知"而非"请求替换" ❌
- `ReplaceImage`: 动词形式，暗示修改操作，不符合 Get 语义 ❌
- 使用 `std::optional<RetainPtr<CFX_DIBitmap>>`：语义相同但更冗长
- 创建新的回调接口：破坏现有代码结构

### Decision 3: 图片尺寸处理
**选择**: 支持任意尺寸的替换图片，由 PDFium 的现有变换流程自动处理缩放

**理由**:
- PDFium 已有完整的图片变换和缩放机制（`obj_to_device_` 矩阵）
- 替换发生在变换之前，新图片会自动应用原图的变换矩阵
- 简化应用层逻辑，无需预先调整图片尺寸
- 灵活性更高，可以用高分辨率图片替换低分辨率原图

**实现说明**:
- 直接替换 `dibbase_` 指针，不修改变换矩阵
- PDFium 的 `CPDF_ImageRenderer` 会根据 `obj_to_device_` 矩阵自动缩放
- 无论替换图片是 100x100 还是 1000x1000，都会缩放到原图的显示区域

**示例**:
```cpp
// 原图是 200x200，显示区域是 100x100（经过变换矩阵）
// 替换图是 500x500
dibbase_ = replacement_bitmap;  // 直接替换
// PDFium 会自动将 500x500 缩放到 100x100 显示区域
```

### Decision 4: 日志记录
**选择**: 使用现有的 `LOG_*` 宏系统记录关键操作

**记录内容**:
- 是否调用了 `OnImageLoaded()`
- 原图尺寸和替换图尺寸（如果尺寸不同会记录缩放信息）
- 是否成功替换
- 错误情况（如空指针）

## Risks / Trade-offs

### Risk 1: 性能影响
**风险**: 每次渲染 AP-Form 图片都会调用回调，可能影响性能

**缓解措施**:
- 仅在 `in_appearance_form_` 且 `image_callback_` 存在时调用
- 应用层应实现快速查找机制（如 hash map）
- 考虑在应用层缓存已加载的替换图片

### Risk 2: 内存管理安全性
**风险**: 直接引用外部提供的临时图片可能导致悬空指针或数据不一致

**缓解措施 - 使用 Clone 创建内部副本**:
- **核心策略**: 调用 `external_image->Clone(nullptr)` 创建完全独立的内部副本
- 外部图片可以在回调返回后立即释放，不影响 PDFium 内部
- 使用 `RetainPtr` 智能指针管理内部副本的生命周期
- `loader_` 内部保持对原始位图的引用，确保其不会被提前释放
- 替换仅在当前 `CPDF_ImageRenderer` 实例有效，不影响其他渲染器

**内存安全验证**:
```cpp
// 场景1: 外部临时数据安全
{
  RetainPtr<CFX_DIBitmap> temp_image = LoadFromFile("temp.jpg");
  RetainPtr<CFX_DIBitmap> replacement = callback->GetReplacementImage(...);
  // replacement 可能就是 temp_image 或其引用
  
  RetainPtr<CFX_DIBitmap> internal_copy = replacement->Clone(nullptr);
  dibbase_ = internal_copy;  // PDFium 持有独立副本
}  
// temp_image 和 replacement 都可能已释放
// 但 dibbase_ 指向的 internal_copy 仍然有效

// 场景2: loader_ 被多次使用
CPDF_ImageRenderer renderer1;  // 第一次渲染，使用替换图片的副本
CPDF_ImageRenderer renderer2;  // 第二次渲染，仍可从 loader_ 获取原始图片

// 场景3: 异步渲染安全
RetainPtr<CFX_DIBitmap> external = GetExternalImage();
RetainPtr<CFX_DIBitmap> copy = external->Clone(nullptr);
dibbase_ = copy;
external.Reset();  // 外部图片立即释放
// 渲染稍后执行，使用 copy，安全无虞
```

**性能考虑**:
- `Clone()` 会复制图片数据，有一定开销
- 但这是确保内存安全的必要代价
- 对于大图片，复制开销可接受（通常几 MB）
- 可以在应用层缓存替换图片以减少 Clone 次数

### Risk 3: loader_ 状态一致性
**风险**: 如果其他代码直接访问 `loader_->GetBitmap()`，可能得到与 `dibbase_` 不同的图片

**缓解措施**:
- 在 `CPDF_ImageRenderer` 中，所有后续操作都使用 `dibbase_` 而非 `loader_->GetBitmap()`
- 文档明确说明：`dibbase_` 是实际用于渲染的位图，可能与 `loader_` 不同
- 这是设计意图，不是 bug：`loader_` 保持缓存的原始数据，`dibbase_` 是当前渲染使用的数据

### Risk 4: 向后兼容性
**风险**: 新增接口方法可能破坏现有实现

**缓解措施**:
- 提供默认实现（返回 `nullptr`）
- 现有代码无需修改即可编译通过
- 仅在显式实现新方法时启用替换功能

## Migration Plan

### 阶段 1: 实现核心功能
1. 扩展 `ImageCallbackIface` 接口
2. 修改 `CPDF_ImageRenderer::StartRenderDIBBase()`
3. 添加调试日志

### 阶段 2: 平台集成
1. 在 `WatermarkCallback` 中实现接口
2. 在 `PdfView` 中添加配置 API
3. 提供示例代码

### 阶段 3: 测试和优化
1. 单元测试和集成测试
2. 性能测试和优化
3. 文档完善

### 回滚计划
如果发现严重问题，可以快速回滚：
1. 在 `StartRenderDIBBase()` 中注释掉 `OnImageLoaded()` 调用
2. 接口定义保留但不使用
3. 应用层代码不调用新 API

## Open Questions
- [ ] 是否需要支持图片格式转换（如 RGB ↔ RGBA）？
- [ ] 是否应该在非 AP-Form 场景也支持替换？
- [ ] 是否需要提供批量替换接口以提高性能？
- [ ] 替换图片的颜色空间如何处理？
