# CFX_DIBitmap 详细分析

[TOC]

## 概述

`CFX_DIBitmap` 是 PDFium 中用于表示设备无关位图（Device-Independent Bitmap）的核心类。它继承自 `CFX_DIBBase`，提供了实际的位图数据存储和操作功能。这是 PDFium 图形系统中最重要的类之一，负责所有光栅图形数据的管理和处理。

## 类层次结构

```
Retainable (引用计数基类)
    ↓
CFX_DIBBase (设备无关位图基类，只读接口)
    ↓
CFX_DIBitmap (可写位图实现，包含实际数据存储)
```

### 文件位置

- **头文件**:       `core/fxge/dib/cfx_dibitmap.h`
- **实现文件**:     `core/fxge/dib/cfx_dibitmap.cpp`
- **基类头文件**:   `core/fxge/dib/cfx_dibbase.h`
- **类型定义**:     `core/fxge/dib/fx_dib.h`

## 核心数据成员

### 继承自 CFX_DIBBase 的成员

```cpp
class CFX_DIBBase : public Retainable {
 private:
  FXDIB_Format format_ = FXDIB_Format::kInvalid;  // 像素格式
  int width_ = 0;                                  // 宽度（像素）
  int height_ = 0;                                 // 高度（像素）
  uint32_t pitch_ = 0;                             // 行跨度（字节）
  DataVector<uint32_t> palette_;                   // 调色板（索引颜色模式使用）
};
```

### CFX_DIBitmap 特有成员

```cpp
class CFX_DIBitmap final : public CFX_DIBBase {
 private:
  MaybeOwned<uint8_t, FxFreeDeleter> buffer_;  // 像素数据缓冲区
};
```

**关键点**:
- `buffer_` 是实际存储像素数据的地方
- 使用 `MaybeOwned` 可以拥有或引用外部缓冲区
- `FxFreeDeleter` 确保使用 `FX_Free()` 释放内存

## 像素格式 (FXDIB_Format)

### 格式编码方式

```cpp
// 编码规则：value & 0xFF = 位深度
//           value & 0x100 = 是否为遮罩
//           value & 0x200 = 是否有Alpha通道
//           value & 0x400 = 是否预乘Alpha
enum class FXDIB_Format : uint16_t {
  kInvalid = 0,
  k1bppRgb = 0x001,      // 1位索引色
  k8bppRgb = 0x008,      // 8位索引色
  kBgr = 0x018,          // 24位RGB (B,G,R)
  kBgrx = 0x020,         // 32位RGB+填充 (B,G,R,X)
  k1bppMask = 0x101,     // 1位遮罩
  k8bppMask = 0x108,     // 8位遮罩
  kBgra = 0x220,         // 32位RGBA (B,G,R,A)
  kBgraPremul = 0x620,   // 32位预乘RGBA (仅Skia模式)
};
```

### 格式详细说明

| 格式 | 位深度 | 字节/像素 | 通道顺序 | 用途 |
|------|--------|----------|----------|------|
| `k1bppRgb` | 1 | 1/8 | 索引 | 黑白图像（2色调色板） |
| `k8bppRgb` | 8 | 1 | 索引 | 256色图像 |
| `kBgr` | 24 | 3 | B,G,R | 真彩色图像 |
| `kBgrx` | 32 | 4 | B,G,R,X | RGB+填充字节 |
| `k1bppMask` | 1 | 1/8 | 灰度 | 黑白遮罩 |
| `k8bppMask` | 8 | 1 | Alpha | 256级遮罩 |
| `kBgra` | 32 | 4 | B,G,R,A | 带Alpha的真彩色 |
| `kBgraPremul` | 32 | 4 | B,G,R,A | Skia预乘Alpha |

### 辅助函数

```cpp
// 获取每像素位数
int GetBppFromFormat(FXDIB_Format format) {
  return static_cast<uint16_t>(format) & 0xff;
}

// 判断是否为遮罩格式
bool GetIsMaskFromFormat(FXDIB_Format format) {
  return !!(static_cast<uint16_t>(format) & 0x100);
}

// 判断是否有Alpha通道
bool GetIsAlphaFromFormat(FXDIB_Format format) {
  return !!(static_cast<uint16_t>(format) & 0x200);
}
```

## 内存布局

### Pitch 计算

**Pitch（行跨度）**: 每行像素数据所占的字节数，通常对齐到4字节边界。

```cpp
// 计算公式
pitch = ((width * bpp + 31) / 32) * 4;
```

**示例**:
```cpp
// 100像素宽的24位图像
width = 100
bpp = 24
pitch = ((100 * 24 + 31) / 32) * 4
      = ((2400 + 31) / 32) * 4
      = (2431 / 32) * 4
      = 75 * 4 = 300 字节

// 实际只需要 100 * 3 = 300 字节
// 正好对齐，无填充
```

```cpp
// 101像素宽的24位图像
width = 101
bpp = 24
pitch = ((101 * 24 + 31) / 32) * 4
      = ((2424 + 31) / 32) * 4
      = (2455 / 32) * 4
      = 76 * 4 = 304 字节

// 实际需要 101 * 3 = 303 字节
// 填充1字节到304以对齐到4字节边界
```

### 缓冲区布局

```cpp
// 以 100x50 像素，24位BGR格式为例
width = 100
height = 50
format = kBgr (24 bpp)
pitch = 300 (每行300字节)

buffer_ 内存布局:
┌─────────────────────────────────────────────────┐
│ 行0: [B₀,G₀,R₀][B₁,G₁,R₁]...[B₉₉,G₉₉,R₉₉]      │ 0-299字节
├─────────────────────────────────────────────────┤
│ 行1: [B₀,G₀,R₀][B₁,G₁,R₁]...[B₉₉,G₉₉,R₉₉]      │ 300-599字节
├─────────────────────────────────────────────────┤
│ ...                                             │
├─────────────────────────────────────────────────┤
│ 行49: [B₀,G₀,R₀][B₁,G₁,R₁]...[B₉₉,G₉₉,R₉₉]     │ 14700-14999字节
└─────────────────────────────────────────────────┘

总大小 = pitch * height = 300 * 50 = 15000 字节
```

### 不同格式的内存布局

#### 32位 BGRA 格式

```cpp
像素(x, y) 的偏移 = y * pitch + x * 4
内存顺序: [Blue, Green, Red, Alpha]

示例: 像素(5, 10) 在 pitch=400 的位图中
offset = 10 * 400 + 5 * 4 = 4020
buffer_[4020] = Blue
buffer_[4021] = Green
buffer_[4022] = Red
buffer_[4023] = Alpha
```

#### 8位索引格式

```cpp
像素(x, y) 的偏移 = y * pitch + x
每个字节存储一个调色板索引

示例: 像素(5, 10)
offset = 10 * pitch + 5
palette_index = buffer_[offset]
actual_color = palette_[palette_index]
```

#### 1位格式

```cpp
像素(x, y) 的计算:
byte_offset = y * pitch + x / 8
bit_offset = 7 - (x % 8)
pixel_value = (buffer_[byte_offset] >> bit_offset) & 1

示例: 像素(13, 5)
byte_offset = 5 * pitch + 13 / 8 = 5 * pitch + 1
bit_offset = 7 - (13 % 8) = 7 - 5 = 2
value = (buffer_[byte_offset] >> 2) & 1
```

## 核心功能分析

### 1. 创建位图

#### Create() - 基本创建

```cpp
bool Create(int width, int height, FXDIB_Format format);
```

**功能**: 分配内存并创建指定大小和格式的位图。

**工作流程**:
```
1. 验证参数有效性（宽度、高度、格式）
   ↓
2. 计算 pitch 和总大小
   ↓
3. 分配内存（size + 4字节额外空间用于安全边界）
   ↓
4. 设置成员变量
   ↓
5. 返回成功/失败
```

**实现细节**:
```cpp
bool CFX_DIBitmap::Create(int width, int height, FXDIB_Format format) {
  // 计算 pitch 和 size
  std::optional<PitchAndSize> pitch_size =
      CalculatePitchAndSize(width, height, format, /*pitch=*/0);
  
  if (!pitch_size.has_value()) {
    return false;
  }
  
  // 分配额外4字节作为安全边界
  const size_t buffer_size = GetAllocSizeOrZero(pitch_size.value().size);
  
  buffer_ = std::unique_ptr<uint8_t, FxFreeDeleter>(
      FX_TryAlloc(uint8_t, buffer_size));
  
  if (!buffer_) {
    return false;
  }
  
  SetWidth(width);
  SetHeight(height);
  SetPitch(pitch_size.value().pitch);
  SetFormat(format);
  
  return true;
}
```

#### Create() - 使用外部缓冲区

```cpp
bool Create(int width, int height, FXDIB_Format format,
            uint8_t* pBuffer, uint32_t pitch);
```

**功能**: 使用外部提供的缓冲区创建位图（不分配内存）。

**用途**: 
- 包装已有的像素数据
- 零拷贝操作
- 与其他图形库互操作

**示例**:
```cpp
// 外部缓冲区（例如来自系统API）
uint8_t* external_buffer = GetBufferFromSomewhere();

auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
bitmap->Create(width, height, FXDIB_Format::kBgr, 
               external_buffer, calculated_pitch);

// bitmap 现在引用外部缓冲区，不拥有内存
```

### 2. 数据访问

#### GetScanline() - 获取扫描线

```cpp
pdfium::span<const uint8_t> GetScanline(int line) const;
```

**功能**: 返回指定行的像素数据。

**实现**:
```cpp
pdfium::span<const uint8_t> CFX_DIBitmap::GetScanline(int line) const {
  auto buffer_span = GetBuffer();
  if (buffer_span.empty()) {
    return pdfium::span<const uint8_t>();
  }
  
  return buffer_span.subspan(line * GetPitch(), GetPitch());
}
```

**使用示例**:
```cpp
// 读取第10行的像素数据
auto scanline = bitmap->GetScanline(10);

// 对于BGR格式，每3字节是一个像素
for (size_t i = 0; i < scanline.size(); i += 3) {
  uint8_t blue = scanline[i];
  uint8_t green = scanline[i + 1];
  uint8_t red = scanline[i + 2];
  // 处理像素...
}
```

#### GetWritableScanline() - 可写扫描线

```cpp
pdfium::span<uint8_t> GetWritableScanline(int line);
```

**功能**: 返回可修改的扫描线数据。

**使用示例**:
```cpp
// 修改第10行的所有像素为红色
auto scanline = bitmap->GetWritableScanline(10);

// BGR格式
for (size_t i = 0; i < scanline.size(); i += 3) {
  scanline[i] = 0;      // Blue = 0
  scanline[i + 1] = 0;  // Green = 0
  scanline[i + 2] = 255; // Red = 255
}
```

#### GetWritableScanlineAs<T>() - 类型化访问

```cpp
template <typename T>
pdfium::span<T> GetWritableScanlineAs(int line);
```

**功能**: 以指定类型访问扫描线（更类型安全）。

**使用示例**:
```cpp
// BGR格式使用 FX_BGR_STRUCT
auto scanline = bitmap->GetWritableScanlineAs<FX_BGR_STRUCT<uint8_t>>(10);
for (auto& pixel : scanline) {
  pixel.red = 255;
  pixel.green = 0;
  pixel.blue = 0;
}

// BGRA格式使用 FX_BGRA_STRUCT
auto scanline = bitmap->GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(10);
for (auto& pixel : scanline) {
  pixel.red = 255;
  pixel.green = 0;
  pixel.blue = 0;
  pixel.alpha = 255;
}
```

### 3. 像素操作

#### Clear() - 清空位图

```cpp
void Clear(uint32_t color);
```

**功能**: 将整个位图填充为指定颜色。

**不同格式的处理**:

```cpp
// 对于BGR格式
FX_BGR_STRUCT<uint8_t> bgr = ArgbToBGRStruct(color);
if (bgr.red == bgr.green && bgr.green == bgr.blue) {
  // 纯色，可以用 memset 优化
  std::ranges::fill(buffer, bgr.red);
} else {
  // 逐像素填充
  for (int row = 0; row < height; row++) {
    auto scanline = GetWritableScanlineAs<FX_BGR_STRUCT<uint8_t>>(row);
    std::ranges::fill(scanline, bgr);
  }
}

// 对于BGRA格式
for (int row = 0; row < height; row++) {
  auto scanline = GetWritableScanlineAs<uint32_t>(row);
  std::ranges::fill(scanline, color);
}

// 对于索引格式
int palette_index = FindPalette(color);
std::ranges::fill(buffer, palette_index);
```

#### MultiplyAlpha() - Alpha混合

```cpp
bool MultiplyAlpha(float alpha);
```

**功能**: 将位图的所有Alpha值乘以指定系数（0.0-1.0）。

**实现**:
```cpp
bool CFX_DIBitmap::MultiplyAlpha(float alpha) {
  // 转换为BGRA格式（如果还不是）
  if (!ConvertFormat(FXDIB_Format::kBgra)) {
    return false;
  }
  
  const int bitmap_alpha = static_cast<int>(alpha * 255.0f);
  
  for (int row = 0; row < GetHeight(); row++) {
    auto scanline = GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(row);
    for (auto& pixel : scanline) {
      pixel.alpha = pixel.alpha * bitmap_alpha / 255;
    }
  }
  
  return true;
}
```

**用途**: 实现半透明效果、淡入淡出等。

#### MultiplyAlphaMask() - 遮罩Alpha混合

```cpp
bool MultiplyAlphaMask(RetainPtr<const CFX_DIBitmap> mask);
```

**功能**: 使用另一个位图作为遮罩，逐像素混合Alpha值。

**要求**:
- `mask` 必须是 `k8bppMask` 格式
- 尺寸必须相同

**实现**:
```cpp
for (int row = 0; row < GetHeight(); row++) {
  auto dest_scan = GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(row);
  auto mask_scan = mask->GetScanline(row);
  
  for (int col = 0; col < GetWidth(); col++) {
    dest_scan[col].alpha = dest_scan[col].alpha * mask_scan[col] / 255;
  }
}
```

### 4. 位图转换

#### ConvertFormat() - 格式转换

```cpp
bool ConvertFormat(FXDIB_Format dest_format);
```

**支持的转换**:

| 源格式 | 目标格式 | 操作 |
|--------|---------|------|
| `k8bppRgb` | `k8bppMask` | 直接改变格式标志 |
| `kBgrx` | `kBgra` | 设置Alpha为255 |
| `kBgrx` | `kBgraPremul` | 设置Alpha为255（Skia） |
| `kBgra` | `kBgraPremul` | 预乘Alpha（Skia） |
| `kBgraPremul` | `kBgra` | 反预乘Alpha（Skia） |
| 其他 | 其他 | 通过 `ConvertBuffer` 转换 |

**预乘Alpha示例**:
```cpp
// 预乘: R' = R * A / 255
void CFX_DIBitmap::PreMultiply() {
  for (int row = 0; row < GetHeight(); row++) {
    auto scanline = GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(row);
    for (auto& pixel : scanline) {
      if (pixel.alpha != 255) {
        pixel.red = pixel.red * pixel.alpha / 255;
        pixel.green = pixel.green * pixel.alpha / 255;
        pixel.blue = pixel.blue * pixel.alpha / 255;
      }
    }
  }
  SetFormat(FXDIB_Format::kBgraPremul);
}

// 反预乘: R = R' * 255 / A
void CFX_DIBitmap::UnPreMultiply() {
  for (int row = 0; row < GetHeight(); row++) {
    auto scanline = GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(row);
    for (auto& pixel : scanline) {
      if (pixel.alpha != 0 && pixel.alpha != 255) {
        pixel.red = pixel.red * 255 / pixel.alpha;
        pixel.green = pixel.green * 255 / pixel.alpha;
        pixel.blue = pixel.blue * 255 / pixel.alpha;
      }
    }
  }
  SetFormat(FXDIB_Format::kBgra);
}
```

#### TransferBitmap() - 位图传输

```cpp
bool TransferBitmap(int width, int height,
                    RetainPtr<const CFX_DIBBase> source,
                    int src_left, int src_top);
```

**功能**: 将源位图的一部分复制到当前位图。

**工作流程**:
```
1. 计算重叠区域
   ↓
2. 检查格式是否相同
   ↓
   ├─ 相同格式
   │  ├─ BPP = 1: 逐位复制
   │  └─ BPP > 1: 逐行 memcpy
   │
   └─ 不同格式
      └─ 使用 ConvertBuffer 转换
```

**示例**:
```cpp
// 将 source 的 (50, 50) 开始的 100x100 区域
// 复制到 dest 的 (0, 0)
dest->TransferBitmap(100, 100, source, 50, 50);
```

### 5. 合成操作

#### CompositeBitmap() - 位图合成

```cpp
bool CompositeBitmap(int dest_left, int dest_top,
                     int width, int height,
                     RetainPtr<const CFX_DIBBase> source,
                     int src_left, int src_top,
                     BlendMode blend_type,
                     const CFX_AggClipRgn* pClipRgn,
                     bool bRgbByteOrder);
```

**功能**: 将源位图合成到目标位图上，支持各种混合模式。

**混合模式**:
```cpp
enum class BlendMode {
  kNormal = 0,      // 正常
  kMultiply,        // 正片叠底
  kScreen,          // 滤色
  kOverlay,         // 叠加
  kDarken,          // 变暗
  kLighten,         // 变亮
  kColorDodge,      // 颜色减淡
  kColorBurn,       // 颜色加深
  kHardLight,       // 强光
  kSoftLight,       // 柔光
  kDifference,      // 差值
  kExclusion,       // 排除
  kHue,             // 色相
  kSaturation,      // 饱和度
  kColor,           // 颜色
  kLuminosity,      // 明度
};
```

**Alpha合成公式** (kNormal模式):
```
result.alpha = src.alpha + dest.alpha * (1 - src.alpha / 255)
result.color = (src.color * src.alpha + dest.color * dest.alpha * (1 - src.alpha / 255)) / result.alpha
```

#### CompositeMask() - 遮罩合成

```cpp
bool CompositeMask(int dest_left, int dest_top,
                   int width, int height,
                   RetainPtr<const CFX_DIBBase> pMask,
                   uint32_t color,
                   int src_left, int src_top,
                   BlendMode blend_type,
                   const CFX_AggClipRgn* pClipRgn,
                   bool bRgbByteOrder);
```

**功能**: 使用遮罩位图在指定位置绘制纯色。

**用途**: 
- 文本渲染（文本光栅化为遮罩，然后用颜色填充）
- 形状渲染

**工作原理**:
```
对于每个像素:
  mask_alpha = mask_bitmap[x, y]
  effective_alpha = color.alpha * mask_alpha / 255
  dest[x, y] = blend(dest[x, y], color, effective_alpha)
```

#### CompositeRect() - 矩形合成

```cpp
bool CompositeRect(int left, int top,
                   int width, int height,
                   uint32_t color);
```

**功能**: 在指定区域绘制纯色矩形。

**优化策略**:
```cpp
// alpha = 255: 直接填充
if (src_alpha == 255) {
  for (int row = rect.top; row < rect.bottom; row++) {
    auto scanline = GetWritableScanlineAs<uint32_t>(row);
    std::ranges::fill(scanline, color);
  }
}

// alpha < 255: Alpha混合
else {
  for (int row = rect.top; row < rect.bottom; row++) {
    auto scanline = GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(row);
    for (auto& pixel : scanline) {
      pixel.red = FXDIB_ALPHA_MERGE(pixel.red, color_red, src_alpha);
      pixel.green = FXDIB_ALPHA_MERGE(pixel.green, color_green, src_alpha);
      pixel.blue = FXDIB_ALPHA_MERGE(pixel.blue, color_blue, src_alpha);
    }
  }
}
```

### 6. 特殊功能

#### TakeOver() - 接管位图

```cpp
void TakeOver(RetainPtr<CFX_DIBitmap>&& pSrcBitmap);
```

**功能**: 接管另一个位图的数据，转移所有权。

**实现**:
```cpp
void CFX_DIBitmap::TakeOver(RetainPtr<CFX_DIBitmap>&& pSrcBitmap) {
  buffer_ = std::move(pSrcBitmap->buffer_);  // 转移缓冲区所有权
  palette_ = std::move(pSrcBitmap->palette_); // 转移调色板
  pSrcBitmap->buffer_ = nullptr;              // 源位图失效
  
  // 复制属性
  SetFormat(pSrcBitmap->GetFormat());
  SetWidth(pSrcBitmap->GetWidth());
  SetHeight(pSrcBitmap->GetHeight());
  SetPitch(pSrcBitmap->GetPitch());
}
```

**用途**: 
- 避免大量像素数据拷贝
- 转移临时位图的所有权

#### SetRedFromAlpha() - 从Alpha设置红色

```cpp
void SetRedFromAlpha();
```

**功能**: 将Alpha通道的值复制到红色通道（用于特殊效果）。

**要求**: 必须是 `kBgra` 格式。

**实现**:
```cpp
for (int row = 0; row < GetHeight(); row++) {
  auto scanline = GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(row);
  for (auto& pixel : scanline) {
    pixel.red = pixel.alpha;
  }
}
```

#### SetUniformOpaqueAlpha() - 设置不透明Alpha

```cpp
void SetUniformOpaqueAlpha();
```

**功能**: 将所有Alpha值设置为255（完全不透明）。

**用途**: 将 `kBgrx` 转换为 `kBgra`。

## 内存管理

### MaybeOwned 智能指针

```cpp
MaybeOwned<uint8_t, FxFreeDeleter> buffer_;
```

**功能**: 
- 可以拥有内存（自己分配）
- 可以引用外部内存（不负责释放）

**两种模式**:

```cpp
// 模式1: 拥有内存
auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
bitmap->Create(100, 100, FXDIB_Format::kBgr);
// buffer_ 指向自己分配的内存，析构时自动释放

// 模式2: 引用外部内存
uint8_t* external_buffer = ...;
auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
bitmap->Create(100, 100, FXDIB_Format::kBgr, external_buffer, pitch);
// buffer_ 引用外部内存，析构时不释放
```

### 内存分配策略

```cpp
// 分配额外4字节的安全边界
size_t GetAllocSizeOrZero(uint32_t size) {
  FX_SAFE_SIZE_T safe_buffer_size = size;
  safe_buffer_size += 4;  // 额外4字节
  return safe_buffer_size.ValueOrDefault(0);
}

// 使用FX_TryAlloc防止内存分配失败导致崩溃
buffer_ = std::unique_ptr<uint8_t, FxFreeDeleter>(
    FX_TryAlloc(uint8_t, buffer_size));
```

**额外4字节的原因**:
- 防止某些算法越界访问
- 提供安全边界
- 对齐优化

### 引用计数

```cpp
// CFX_DIBitmap 继承自 Retainable，使用引用计数
class CFX_DIBitmap final : public CFX_DIBBase {
  // ...
};

class CFX_DIBBase : public Retainable {
  // ...
};

// 使用 RetainPtr 管理生命周期
RetainPtr<CFX_DIBitmap> bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
bitmap->Create(100, 100, FXDIB_Format::kBgr);

// 共享同一个位图
RetainPtr<CFX_DIBitmap> another = bitmap;  // 引用计数+1

// 当最后一个 RetainPtr 析构时，位图自动删除
```

## 性能优化技巧

### 1. 选择合适的格式

```cpp
// ✅ 好：对于不需要Alpha的图片使用BGR
bitmap->Create(width, height, FXDIB_Format::kBgr);
// 节省 25% 内存 (24位 vs 32位)

// ❌ 不好：总是使用BGRA
bitmap->Create(width, height, FXDIB_Format::kBgra);
// 浪费内存和带宽
```

### 2. 使用类型化访问

```cpp
// ✅ 好：使用类型化访问
auto scanline = bitmap->GetWritableScanlineAs<FX_BGR_STRUCT<uint8_t>>(row);
for (auto& pixel : scanline) {
  pixel.red = 255;
  // 编译器可以优化为高效的SIMD指令
}

// ❌ 不好：手动计算偏移
auto scanline = bitmap->GetWritableScanline(row);
for (int i = 0; i < width * 3; i += 3) {
  scanline[i + 2] = 255;
  // 容易出错，难以优化
}
```

### 3. 避免不必要的格式转换

```cpp
// ✅ 好：检查格式
if (bitmap->GetFormat() != FXDIB_Format::kBgra) {
  bitmap->ConvertFormat(FXDIB_Format::kBgra);
}
DoSomethingWithBGRA(bitmap);

// ❌ 不好：总是转换
bitmap->ConvertFormat(FXDIB_Format::kBgra);  // 可能已经是BGRA
DoSomethingWithBGRA(bitmap);
```

### 4. 利用 Clear() 优化

```cpp
// ✅ 好：使用 Clear() 初始化
bitmap->Create(width, height, format);
bitmap->Clear(0xFFFFFFFF);  // 内部优化为 memset

// ❌ 不好：逐像素初始化
bitmap->Create(width, height, format);
for (int y = 0; y < height; y++) {
  auto scanline = bitmap->GetWritableScanlineAs<uint32_t>(y);
  for (int x = 0; x < width; x++) {
    scanline[x] = 0xFFFFFFFF;
  }
}
```

### 5. 预分配位图

```cpp
// ✅ 好：重用位图对象
RetainPtr<CFX_DIBitmap> cached_bitmap;

void RenderFrame() {
  if (!cached_bitmap || 
      cached_bitmap->GetWidth() != width ||
      cached_bitmap->GetHeight() != height) {
    cached_bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
    cached_bitmap->Create(width, height, format);
  }
  
  // 重用 cached_bitmap
  cached_bitmap->Clear(0);
  // ... 渲染到 cached_bitmap
}

// ❌ 不好：每次都创建新位图
void RenderFrame() {
  auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
  bitmap->Create(width, height, format);  // 每次都分配内存
  // ... 渲染
}
```

## 常见使用模式

### 模式1: 创建和填充

```cpp
// 创建100x100的白色位图
auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
if (!bitmap->Create(100, 100, FXDIB_Format::kBgr)) {
  return nullptr;  // 创建失败
}
bitmap->Clear(0xFFFFFFFF);  // 填充白色
```

### 模式2: 从现有位图复制

```cpp
// 复制位图
auto copy = pdfium::MakeRetain<CFX_DIBitmap>();
if (!copy->Copy(original)) {
  return nullptr;
}

// 或者接管位图（转移所有权）
auto moved = pdfium::MakeRetain<CFX_DIBitmap>();
moved->TakeOver(std::move(original));
// original 不再有效
```

### 模式3: 逐像素处理

```cpp
// 反色处理
for (int y = 0; y < bitmap->GetHeight(); y++) {
  auto scanline = bitmap->GetWritableScanlineAs<FX_BGR_STRUCT<uint8_t>>(y);
  for (auto& pixel : scanline) {
    pixel.red = 255 - pixel.red;
    pixel.green = 255 - pixel.green;
    pixel.blue = 255 - pixel.blue;
  }
}
```

### 模式4: 合成多个图层

```cpp
// 创建背景
auto background = pdfium::MakeRetain<CFX_DIBitmap>();
background->Create(width, height, FXDIB_Format::kBgra);
background->Clear(0xFFFFFFFF);

// 合成前景
background->CompositeBitmap(
    dest_left, dest_top, width, height,
    foreground, 0, 0,
    BlendMode::kNormal, nullptr, false);

// 合成遮罩
background->CompositeMask(
    dest_left, dest_top, width, height,
    mask, color, 0, 0,
    BlendMode::kNormal, nullptr, false);
```

### 模式5: 包装外部缓冲区

```cpp
// 零拷贝包装
uint8_t* system_buffer = GetBufferFromSystem();
uint32_t system_pitch = GetPitchFromSystem();

auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
bitmap->Create(width, height, FXDIB_Format::kBgr,
               system_buffer, system_pitch);

// 现在可以使用 PDFium 的 API 操作系统缓冲区
// 注意：不要在 bitmap 使用期间释放 system_buffer
```

## 与其他类的关系

### CFX_DIBBase

```cpp
// CFX_DIBitmap 实现了 CFX_DIBBase 的虚函数
class CFX_DIBitmap final : public CFX_DIBBase {
  // 实现 GetScanline()
  pdfium::span<const uint8_t> GetScanline(int line) const override;
  
  // 实现 GetEstimatedImageMemoryBurden()
  size_t GetEstimatedImageMemoryBurden() const override;
};
```

### CPDF_DIB

```cpp
// CPDF_DIB 也继承自 CFX_DIBBase
// 用于从 PDF 流解码图片
class CPDF_DIB : public CFX_DIBBase {
  // 可能使用 CFX_DIBitmap 存储解码后的数据
  private:
    RetainPtr<CFX_DIBitmap> cached_bitmap_;
};
```

**关系**:
```
CFX_DIBBase (抽象基类)
    ↓
    ├─ CFX_DIBitmap (内存中的位图)
    └─ CPDF_DIB (PDF流中的位图)
           └─ 内部使用 CFX_DIBitmap 缓存
```

### CFX_ImageRenderer

```cpp
// 图片渲染器使用 CFX_DIBitmap 存储渲染结果
class CPDF_ImageRenderer {
  private:
    RetainPtr<CFX_DIBBase> dibbase_;  // 通常是 CFX_DIBitmap
    std::unique_ptr<CPDF_ImageLoader> loader_;
};
```

### CFX_RenderDevice

```cpp
// 渲染设备接受 CFX_DIBitmap 作为输入
class CFX_RenderDevice {
  public:
    bool SetDIBits(RetainPtr<const CFX_DIBBase> source, int left, int top);
    bool SetDIBitsWithBlend(RetainPtr<const CFX_DIBBase> source,
                            int left, int top, BlendMode blend_mode);
};
```

## 调试和故障排查

### 常见问题

#### 1. 内存泄漏

```cpp
// ❌ 错误：忘记使用 RetainPtr
CFX_DIBitmap* bitmap = new CFX_DIBitmap();
bitmap->Create(100, 100, FXDIB_Format::kBgr);
// 泄漏！

// ✅ 正确：使用 RetainPtr
RetainPtr<CFX_DIBitmap> bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
bitmap->Create(100, 100, FXDIB_Format::kBgr);
// 自动管理生命周期
```

#### 2. 缓冲区越界

```cpp
// ❌ 错误：超出宽度范围
auto scanline = bitmap->GetWritableScanline(0);
for (int i = 0; i < width * 4; i += 3) {  // 错误：应该是 * 3
  scanline[i] = 0;
}

// ✅ 正确：使用类型化访问
auto scanline = bitmap->GetWritableScanlineAs<FX_BGR_STRUCT<uint8_t>>(0);
for (auto& pixel : scanline) {  // 自动处理范围
  pixel.blue = 0;
}
```

#### 3. 格式不匹配

```cpp
// ❌ 错误：假设格式
auto scanline = bitmap->GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(0);
// 如果实际是BGR格式，会出错

// ✅ 正确：检查格式
if (bitmap->GetFormat() == FXDIB_Format::kBgra) {
  auto scanline = bitmap->GetWritableScanlineAs<FX_BGRA_STRUCT<uint8_t>>(0);
  // ...
} else {
  // 处理其他格式
}
```

### 调试技巧

```cpp
// 1. 打印位图信息
void PrintBitmapInfo(const CFX_DIBitmap* bitmap) {
  printf("Size: %dx%d\n", bitmap->GetWidth(), bitmap->GetHeight());
  printf("Format: 0x%x\n", static_cast<int>(bitmap->GetFormat()));
  printf("BPP: %d\n", bitmap->GetBPP());
  printf("Pitch: %d\n", bitmap->GetPitch());
  printf("Has Alpha: %d\n", bitmap->IsAlphaFormat());
  printf("Is Mask: %d\n", bitmap->IsMaskFormat());
}

// 2. 验证像素值
void VerifyPixel(const CFX_DIBitmap* bitmap, int x, int y) {
  auto scanline = bitmap->GetScanlineAs<FX_BGR_STRUCT<uint8_t>>(y);
  const auto& pixel = scanline[x];
  printf("Pixel(%d,%d): R=%d G=%d B=%d\n",
         x, y, pixel.red, pixel.green, pixel.blue);
}

// 3. 保存为BMP文件（调试用）
void SaveAsBMP(const CFX_DIBitmap* bitmap, const char* filename);
```

## 总结

`CFX_DIBitmap` 是 PDFium 图形系统的核心，提供了：

1. **灵活的像素格式支持** - 从1位到32位，支持索引色、RGB、RGBA等
2. **高效的内存管理** - 引用计数、零拷贝、预分配等优化
3. **丰富的操作接口** - 创建、复制、转换、合成等
4. **类型安全的访问** - 模板化的扫描线访问
5. **跨平台兼容** - 支持不同渲染后端（AGG、Skia等）

理解 `CFX_DIBitmap` 的工作原理对于：
- 实现图片处理功能（如水印、滤镜）
- 优化渲染性能
- 调试图形相关问题
- 与外部图形库集成

都至关重要。

## 相关文档

- [图片加载流程](image-loading-process.md)
- [AP-Form 图片水印回调](ap-form-image-watermark.md)
- [PDFium 入门指南](getting-started.md)

## 版本历史

- **v1.0** (2025-01-04): 初始版本，详细分析 CFX_DIBitmap 类