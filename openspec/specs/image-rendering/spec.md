# image-rendering Specification

## Purpose
TBD - created by archiving change add-external-image-replacement. Update Purpose after archive.
## Requirements
### Requirement: 外部图片临时替换回调
系统 SHALL 提供回调机制，允许外部应用在渲染前临时替换位图数据，用于当前渲染周期，而不修改 `loader_` 的原始数据。

#### Scenario: AP-Form 图片成功临时替换
- **WHEN** 渲染器加载 AP-Form 中的图片对象
- **AND** 图片回调接口已注册且实现了 `GetReplacementImage()` 方法
- **AND** 回调返回有效的替换位图
- **THEN** 渲染器 SHALL 将 `dibbase_` 指向替换位图用于本次渲染
- **AND** `loader_` 的原始位图数据 SHALL 保持不变
- **AND** 替换位图 SHALL 应用原图的变换矩阵进行缩放和定位
- **AND** 替换仅在当前 `CPDF_ImageRenderer` 实例有效

#### Scenario: 回调返回 nullptr 保持原图
- **WHEN** 渲染器加载 AP-Form 中的图片对象
- **AND** 图片回调接口已注册
- **AND** `GetReplacementImage()` 回调返回 `nullptr`
- **THEN** 渲染器 SHALL 使用原始位图进行渲染
- **AND** 不产生任何错误或警告

#### Scenario: 替换图片尺寸与原图不同
- **WHEN** 渲染器加载 AP-Form 中的图片对象
- **AND** 回调返回替换位图
- **AND** 替换位图的尺寸与原图不同
- **THEN** 渲染器 SHALL 接受替换位图
- **AND** 记录 INFO 级别日志显示原图尺寸和替换图尺寸
- **AND** 使用原图的变换矩阵自动缩放替换图到相同的显示区域

#### Scenario: 非 AP-Form 场景不触发替换
- **WHEN** 渲染器加载非 AP-Form 上下文的图片对象
- **AND** 图片回调接口已注册
- **THEN** `GetReplacementImage()` 回调 SHALL NOT 被调用
- **AND** 使用标准图片加载流程

### Requirement: 接口方法签名
`ImageCallbackIface` 接口 SHALL 定义 `GetReplacementImage()` 方法，签名如下：

```cpp
virtual RetainPtr<CFX_DIBitmap> GetReplacementImage(
    CPDF_ImageObject* image_object,
    const CFX_Matrix& image_matrix,
    RetainPtr<CFX_DIBitmap> original_bitmap
);
```

**方法语义**: 请求为当前图片对象提供替换位图，返回 `nullptr` 表示不替换。

#### Scenario: 接口参数传递正确
- **WHEN** 调用 `GetReplacementImage()` 回调
- **THEN** `image_object` 参数 SHALL 指向当前渲染的图片对象
- **AND** `image_matrix` 参数 SHALL 包含图片的变换矩阵
- **AND** `original_bitmap` 参数 SHALL 包含从 loader 加载的原始位图
- **AND** 所有参数 SHALL 为有效的非空值

#### Scenario: 默认实现向后兼容
- **WHEN** 实现类未重写 `GetReplacementImage()` 方法
- **THEN** 默认实现 SHALL 返回 `nullptr`
- **AND** 不影响现有代码的编译和运行

### Requirement: 调用时机
图片替换回调 SHALL 在以下时机被调用：

1. 在 `CPDF_ImageLoader::GetBitmap()` 成功返回之后
2. 在应用颜色转换函数（TransferFunc）之前
3. 在水印回调（`OnImageRendering()`）之前
4. 仅在 `in_appearance_form_` 标志为 true 时

#### Scenario: 替换在颜色转换前执行
- **WHEN** 原始位图需要应用颜色转换函数
- **AND** 替换回调返回新位图
- **THEN** 颜色转换 SHALL 应用于替换后的位图
- **AND** 不应用于原始位图

#### Scenario: 替换在水印前执行
- **WHEN** 同时配置了图片替换和水印回调
- **THEN** `GetReplacementImage()` SHALL 先于 `OnImageRendering()` 被调用
- **AND** 水印 SHALL 叠加在替换后的位图上
- **AND** 不叠加在原始位图上

### Requirement: 内存管理和数据隔离
图片替换功能 SHALL 创建外部图片的内部副本，使用 `RetainPtr` 智能指针管理位图生命周期，并确保不依赖外部临时数据。

#### Scenario: 创建内部副本避免外部依赖
- **WHEN** 回调返回替换位图
- **THEN** 系统 SHALL 调用 `Clone(nullptr)` 创建完全独立的内部副本
- **AND** 将 `dibbase_` 指向内部副本而非外部返回的位图
- **AND** 外部位图可以在回调返回后立即释放
- **AND** 不影响 PDFium 内部的渲染过程

#### Scenario: 替换位图自动释放
- **WHEN** 当前 `CPDF_ImageRenderer` 实例销毁或 `dibbase_` 被重新赋值
- **THEN** 内部副本的引用计数 SHALL 自动减少
- **AND** 当引用计数为零时自动释放内存
- **AND** 不需要应用层手动释放

#### Scenario: 外部临时数据不影响渲染
- **WHEN** 外部提供临时图片数据（如从文件即时加载）
- **AND** 回调返回后外部图片被释放
- **THEN** PDFium 内部的副本 SHALL 仍然有效
- **AND** 渲染 SHALL 正常完成
- **AND** 不产生悬空指针或数据损坏

#### Scenario: loader_ 原始数据保持不变
- **WHEN** `dibbase_` 指向替换位图
- **THEN** `loader_` 内部的原始位图 SHALL 保持不变
- **AND** `loader_->GetBitmap()` SHALL 仍然返回原始位图
- **AND** 其他使用同一 `loader_` 的渲染器 SHALL 不受影响

#### Scenario: 多次渲染独立性
- **WHEN** 同一图片对象被多次渲染
- **AND** 第一次渲染使用了替换图片
- **THEN** 第二次渲染 SHALL 仍可从 `loader_` 获取原始图片
- **AND** 第二次渲染 SHALL 可以选择使用不同的替换图片或原图
- **AND** 不产生内存泄漏或悬空指针

### Requirement: 图片尺寸自动适配
系统 SHALL 支持任意尺寸的替换图片，并自动缩放到原图的显示区域。

#### Scenario: 替换图片尺寸大于原图
- **WHEN** 替换图片尺寸为 1000x1000
- **AND** 原图尺寸为 200x200
- **AND** 原图显示区域为 100x100（经过变换矩阵）
- **THEN** 系统 SHALL 将替换图片缩小到 100x100 显示区域
- **AND** 不修改变换矩阵
- **AND** 使用 PDFium 现有的图片缩放机制

#### Scenario: 替换图片尺寸小于原图
- **WHEN** 替换图片尺寸为 50x50
- **AND** 原图尺寸为 200x200
- **AND** 原图显示区域为 100x100
- **THEN** 系统 SHALL 将替换图片放大到 100x100 显示区域
- **AND** 保持原图的变换矩阵不变

#### Scenario: 替换图片纵横比不同
- **WHEN** 替换图片纵横比为 2:1（如 400x200）
- **AND** 原图纵横比为 1:1（如 200x200）
- **THEN** 系统 SHALL 保持原图的变换矩阵
- **AND** 替换图片 SHALL 按变换矩阵缩放（可能产生拉伸或压缩）
- **AND** 不自动调整纵横比

### Requirement: 日志记录
系统 SHALL 记录图片替换和内存管理的关键信息。

#### Scenario: 记录替换操作
- **WHEN** 尝试替换图片
- **THEN** 系统 SHALL 记录 INFO 级别日志，包含原图尺寸
- **AND** 如果替换成功，SHALL 记录替换图尺寸（包括是否需要缩放）
- **AND** 记录是否成功创建内部副本
- **AND** 如果替换失败，SHALL 记录原因

#### Scenario: 记录内存操作
- **WHEN** 创建内部副本
- **THEN** 系统 SHALL 记录 DEBUG 级别日志
- **AND** 日志 SHALL 包含副本的内存地址和尺寸
- **AND** 记录外部图片是否可以安全释放

#### Scenario: 记录错误情况
- **WHEN** 替换过程中发生错误（如 Clone 失败、回调返回空指针）
- **THEN** 系统 SHALL 记录 WARNING 级别日志
- **AND** 日志 SHALL 包含具体的错误描述
- **AND** 系统 SHALL 继续使用原始位图（不中断渲染）

