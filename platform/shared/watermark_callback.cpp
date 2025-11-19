// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "platform/shared/watermark_callback.h"
#include <cerrno>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <sstream>
#include "core/fxcodec/jpeg/jpegmodule.h"
#include "core/fxcodec/scanlinedecoder.h"
#include "core/fxge/dib/cfx_dibbase.h"
#include "core/fxge/dib/cfx_dibitmap.h"
#include "platform/shared/logger.h"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>  // [AP-FORM-IMAGE-REPLACEMENT] For image loading
#include <ImageIO/ImageIO.h>            // [AP-FORM-IMAGE-REPLACEMENT] For image I/O
#include <mach-o/dyld.h>
#endif

// [AP-FORM-IMAGE-WATERMARK] 水印文件名定义
constexpr char WatermarkCallback::kWatermarkFilename[];

// [AP-FORM-IMAGE-REPLACEMENT] 前向声明
static RetainPtr<CFX_DIBitmap> DecodePngFile(const std::vector<uint8_t>& file_data);

WatermarkCallback::WatermarkCallback() {
  // [AP-FORM-IMAGE-WATERMARK] 使用应用资源目录路径
  std::string resource_path = GetResourcePath();
  watermark_path_ = resource_path + "/" + kWatermarkFilename;
  output_dir_ = GetTempOutputPath();

  LOG_INFO_F(
      "[AP-FORM-IMAGE-WATERMARK] WatermarkCallback created (lazy loading)");
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Watermark path: %s",
             watermark_path_.c_str());
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Output dir: %s", output_dir_.c_str());
}

WatermarkCallback::WatermarkCallback(const char* resource_path)
    : watermark_path_(resource_path), output_dir_(GetTempOutputPath()) {
  LOG_INFO_F(
      "[AP-FORM-IMAGE-WATERMARK] WatermarkCallback created with custom path: "
      "%s",
      watermark_path_.c_str());
}

WatermarkCallback::~WatermarkCallback() = default;

// [AP-FORM-IMAGE-WATERMARK] 获取应用资源目录路径
std::string WatermarkCallback::GetResourcePath() {
#ifdef __APPLE__
  CFBundleRef mainBundle = CFBundleGetMainBundle();
  if (mainBundle) {
    CFURLRef resourcesURL = CFBundleCopyResourcesDirectoryURL(mainBundle);
    if (resourcesURL) {
      char path[PATH_MAX];
      if (CFURLGetFileSystemRepresentation(resourcesURL, TRUE, (UInt8*)path,
                                           PATH_MAX)) {
        CFRelease(resourcesURL);
        LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Resource path: %s", path);
        return std::string(path);
      }
      CFRelease(resourcesURL);
    }
  }
  LOG_WARNING(
      "[AP-FORM-IMAGE-WATERMARK] Failed to get bundle resource path, using "
      "current directory");
  return ".";
#else
  // 其他平台可以根据需要实现
  return ".";
#endif
}

// [AP-FORM-IMAGE-WATERMARK] 获取临时输出目录路径
std::string WatermarkCallback::GetTempOutputPath() {
#ifdef __APPLE__
  CFBundleRef mainBundle = CFBundleGetMainBundle();
  if (mainBundle) {
    CFURLRef bundleURL = CFBundleCopyBundleURL(mainBundle);
    if (bundleURL) {
      char path[PATH_MAX];
      if (CFURLGetFileSystemRepresentation(bundleURL, TRUE, (UInt8*)path,
                                           PATH_MAX)) {
        CFRelease(bundleURL);
        std::string tmp_path = std::string(path) + "/tmp/";
        LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Temp output path: %s",
                   tmp_path.c_str());

        // 创建目录（如果不存在）
        std::system(("mkdir -p \"" + tmp_path + "\"").c_str());

        return tmp_path;
      }
      CFRelease(bundleURL);
    }
  }
  LOG_WARNING(
      "[AP-FORM-IMAGE-WATERMARK] Failed to get bundle path, using /tmp/");
  return "/tmp/";
#else
  return "/tmp/";
#endif
}

std::vector<uint8_t> WatermarkCallback::ReadFileData(const char* path) {
  LOG_INFO_F("[ReadFileData] Attempting to read file: %s", path);
  
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    LOG_ERROR_F("[ReadFileData] ❌ Cannot open file: %s", path);
    LOG_ERROR_F("[ReadFileData] errno: %d (%s)", errno, strerror(errno));
    return {};
  }

  auto size = file.tellg();
  LOG_INFO_F("[ReadFileData] File size: %lld bytes", (long long)size);
  
  if (size <= 0) {
    LOG_ERROR_F("[ReadFileData] ❌ File is empty or invalid: %s", path);
    return {};
  }

  std::vector<uint8_t> data(size);
  file.seekg(0);
  
  if (!file.read(reinterpret_cast<char*>(data.data()), size)) {
    LOG_ERROR_F("[ReadFileData] ❌ Failed to read file data: %s", path);
    return {};
  }

  LOG_INFO_F("[ReadFileData] ✅ Successfully read %zu bytes from %s", 
             data.size(), path);
  
  // 打印文件头（前8个字节）用于调试
  if (data.size() >= 8) {
    LOG_INFO_F("[ReadFileData] File header: %02X %02X %02X %02X %02X %02X %02X %02X",
               data[0], data[1], data[2], data[3], 
               data[4], data[5], data[6], data[7]);
  }
  
  return data;
}

// [AP-FORM-IMAGE-REPLACEMENT] 自动检测并解码图片文件（支持 PNG 和 JPEG）
RetainPtr<CFX_DIBitmap> WatermarkCallback::DecodeImageFile(
    const std::vector<uint8_t>& file_data) {
  
  if (file_data.size() < 8) {
    LOG_ERROR("[DecodeImageFile] File data too small");
    return nullptr;
  }
  
  // 检测文件类型（PNG 签名: 89 50 4E 47）
  bool is_png = (file_data.size() >= 4 && 
                 file_data[0] == 0x89 && 
                 file_data[1] == 0x50 && 
                 file_data[2] == 0x4E && 
                 file_data[3] == 0x47);
  
  // 检测 JPEG 签名（FF D8 FF）
  bool is_jpeg = (file_data.size() >= 3 && 
                  file_data[0] == 0xFF && 
                  file_data[1] == 0xD8 && 
                  file_data[2] == 0xFF);
  
  if (is_png) {
    LOG_INFO("[DecodeImageFile] Detected PNG format");
    return DecodePngFile(file_data);
  } else if (is_jpeg) {
    LOG_INFO("[DecodeImageFile] Detected JPEG format");
    // 使用原有的 JPEG 解码逻辑
    auto info_opt = fxcodec::JpegModule::LoadInfo(
        pdfium::span<const uint8_t>(file_data.data(), file_data.size()));

    if (!info_opt.has_value()) {
      LOG_ERROR("[DecodeImageFile] Failed to load JPEG info");
      return nullptr;
    }

    auto& info = info_opt.value();
    LOG_INFO_F("[DecodeImageFile] JPEG info: %dx%d, %d components",
               info.width, info.height, info.num_components);

    auto decoder = fxcodec::JpegModule::CreateDecoder(
        pdfium::span<const uint8_t>(file_data.data(), file_data.size()),
        info.width, info.height, info.num_components, info.color_transform);

    if (!decoder) {
      LOG_ERROR("[DecodeImageFile] Failed to create JPEG decoder");
      return nullptr;
    }

    FXDIB_Format format = FXDIB_Format::kBgr;
    if (info.num_components == 1) {
      format = FXDIB_Format::k8bppMask;
    } else if (info.num_components == 3) {
      format = FXDIB_Format::kBgr;
    } else if (info.num_components == 4) {
      format = FXDIB_Format::kBgra;
    }

    auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
    if (!bitmap->Create(info.width, info.height, format)) {
      LOG_ERROR("[DecodeImageFile] Failed to create bitmap");
      return nullptr;
    }

    for (uint32_t row = 0; row < info.height; ++row) {
      auto scanline = decoder->GetScanline(row);
      if (scanline.empty()) {
        LOG_ERROR_F("[DecodeImageFile] Failed to decode JPEG row %u", row);
        return nullptr;
      }

      uint8_t* dest = bitmap->GetWritableScanline(row).data();
      memcpy(dest, scanline.data(), scanline.size());
    }

    LOG_INFO_F("[DecodeImageFile] Successfully decoded JPEG: %dx%d", 
               bitmap->GetWidth(), bitmap->GetHeight());
    return bitmap;
  } else {
    LOG_ERROR("[DecodeImageFile] Unknown image format (not PNG or JPEG)");
    return nullptr;
  }
}

// [AP-FORM-IMAGE-REPLACEMENT] 使用 macOS 原生API 解码图片（支持 PNG/JPEG 等）
#ifdef __APPLE__
static RetainPtr<CFX_DIBitmap> DecodePngFile(
    const std::vector<uint8_t>& file_data) {
  
  LOG_INFO_F("[DecodePngFile] Starting decode, data size: %zu bytes", file_data.size());
  
  // 创建 CFData
  CFDataRef data = CFDataCreate(nullptr, file_data.data(), file_data.size());
  if (!data) {
    LOG_ERROR("[DecodePngFile] ❌ Failed to create CFData");
    return nullptr;
  }
  LOG_INFO("[DecodePngFile] ✅ Created CFData");
  
  // 创建图片源
  CGImageSourceRef source = CGImageSourceCreateWithData(data, nullptr);
  CFRelease(data);
  
  if (!source) {
    LOG_ERROR("[DecodePngFile] ❌ Failed to create CGImageSource");
    return nullptr;
  }
  LOG_INFO("[DecodePngFile] ✅ Created CGImageSource");
  
  // 获取图片类型和数量
  CFStringRef type = CGImageSourceGetType(source);
  if (type) {
    char type_str[256];
    CFStringGetCString(type, type_str, sizeof(type_str), kCFStringEncodingUTF8);
    LOG_INFO_F("[DecodePngFile] Image type: %s", type_str);
  }
  
  size_t count = CGImageSourceGetCount(source);
  LOG_INFO_F("[DecodePngFile] Image count: %zu", count);
  
  if (count == 0) {
    LOG_ERROR("[DecodePngFile] ❌ No images found in source");
    CFRelease(source);
    return nullptr;
  }
  
  // 创建 CGImage
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  CFRelease(source);
  
  if (!image) {
    LOG_ERROR("[DecodePngFile] ❌ Failed to create CGImage at index 0");
    return nullptr;
  }
  LOG_INFO("[DecodePngFile] ✅ Created CGImage");
  
  // 获取图片信息
  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  size_t bpp = CGImageGetBitsPerPixel(image);
  size_t bpc = CGImageGetBitsPerComponent(image);
  LOG_INFO_F("[DecodePngFile] Image: %zux%zu, %zu bpp, %zu bpc", 
             width, height, bpp, bpc);
  
  // 创建位图 (使用 BGRA 格式，与 macOS 兼容)
  auto bitmap = pdfium::MakeRetain<CFX_DIBitmap>();
  if (!bitmap->Create(static_cast<int>(width), static_cast<int>(height), 
                      FXDIB_Format::kBgra)) {
    LOG_ERROR("[DecodePngFile] Failed to create bitmap");
    CGImageRelease(image);
    return nullptr;
  }
  
  // 创建 CGContext 并绘制图片
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      bitmap->GetWritableBuffer().data(),
      width, height,
      8, // bits per component
      bitmap->GetPitch(),
      colorSpace,
      static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
  
  CGColorSpaceRelease(colorSpace);
  
  if (!context) {
    LOG_ERROR("[DecodePngFile] Failed to create CGContext");
    CGImageRelease(image);
    return nullptr;
  }
  
  // 绘制图片
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  
  CGContextRelease(context);
  CGImageRelease(image);
  
  LOG_INFO_F("[DecodePngFile] Successfully decoded image: %dx%d", 
             bitmap->GetWidth(), bitmap->GetHeight());
  return bitmap;
}
#else
// 非 macOS 平台不支持
static RetainPtr<CFX_DIBitmap> DecodePngFile(
    const std::vector<uint8_t>& file_data) {
  LOG_ERROR("[DecodePngFile] PNG decoding not supported on this platform");
  return nullptr;
}
#endif

bool WatermarkCallback::LoadWatermarkImage(const char* path) {
  // [AP-FORM-IMAGE-WATERMARK] 读取文件数据
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Loading watermark from: %s", path);
  std::vector<uint8_t> file_data = ReadFileData(path);
  if (file_data.empty()) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to read file data");
    return false;
  }

  // 使用 PDFium 解码器解码图片
  watermark_bitmap_ = DecodeImageFile(file_data);
  if (!watermark_bitmap_) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to decode image");
    return false;
  }

  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Loaded watermark: %dx%d",
             watermark_bitmap_->GetWidth(), watermark_bitmap_->GetHeight());
  return true;
}

// [AP-FORM-IMAGE-REPLACEMENT] 获取替换图片
// 默认实现：不替换图片，返回 nullptr
// 应用层可以继承此类并重写此方法以提供实际的替换逻辑
// 例如：
//   - 根据 pImageObj 的属性判断是否需要替换
//   - 从外部文件加载替换图片
//   - 根据图片对象 ID 从映射表中查找替换图片
RetainPtr<CFX_DIBitmap> WatermarkCallback::GetReplacementImage(
    CPDF_ImageObject* pImageObj,
    const CFX_Matrix& mtObj2Device,
    RetainPtr<CFX_DIBitmap> pOriginalBitmap) {
  LOG_DEBUG_F(
      "[AP-FORM-IMAGE-REPLACEMENT] GetReplacementImage called for image %dx%d",
      pOriginalBitmap->GetWidth(), pOriginalBitmap->GetHeight());
  
  // 默认实现：不替换，返回 nullptr
  // 外部可以继承此类并重写此方法以提供实际的替换图片
  return nullptr;
}

// [AP-FORM-IMAGE-WATERMARK] 叠加水印
RetainPtr<CFX_DIBitmap> WatermarkCallback::OnImageRendering(
    CPDF_ImageObject* pImageObj,
    const CFX_Matrix& mtObj2Device,
    RetainPtr<CFX_DIBitmap> pOriginalBitmap) {
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] OnImageRendering called");

  if (!pOriginalBitmap) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Original bitmap is null");
    return nullptr;
  }

  // [AP-FORM-IMAGE-WATERMARK] 懒加载：首次使用时才加载水印
  if (!watermark_bitmap_) {
    LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Loading watermark on first use");
    if (!LoadWatermarkImage(watermark_path_.c_str())) {
      LOG_ERROR_F(
          "[AP-FORM-IMAGE-WATERMARK] Failed to load watermark, returning "
          "original");
      return nullptr;
    }
  }

  // 克隆原始位图
  RetainPtr<CFX_DIBitmap> result = pOriginalBitmap->Realize();
  if (!result) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to realize bitmap");
    return nullptr;
  }

  // 应用水印
  if (!ApplyWatermark(result.Get(), watermark_bitmap_.Get())) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to apply watermark");
    return nullptr;
  }

  // 保存中间产物
  std::ostringstream filename;
  filename << "watermarked_" << std::setw(4) << std::setfill('0')
           << (++image_counter_) << ".png";
  SaveBitmapToFile(result.Get(), filename.str());

  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] SUCCESS: Watermark applied");
  return result;
}

bool WatermarkCallback::ApplyWatermark(CFX_DIBitmap* target_bitmap,
                                       const CFX_DIBitmap* watermark) {
  // [AP-FORM-IMAGE-WATERMARK] 计算水印尺寸（1/3）
  int target_width = target_bitmap->GetWidth();
  int target_height = target_bitmap->GetHeight();
  int wm_width = target_width / 3;
  int wm_height = target_height / 3;

  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Target: %dx%d, Watermark size: %dx%d",
             target_width, target_height, wm_width, wm_height);

  // 缩放水印到目标尺寸
  RetainPtr<CFX_DIBitmap> scaled_watermark = watermark->StretchTo(
      wm_width, wm_height, FXDIB_ResampleOptions(), nullptr);

  if (!scaled_watermark) {
    LOG_ERROR_F("[AP-FORM-IMAGE-WATERMARK] Failed to scale watermark");
    return false;
  }

  // [AP-FORM-IMAGE-WATERMARK] 合成到左上角
  // 位置：(0, 0)
  bool success = target_bitmap->CompositeBitmap(
      0, 0,                    // left, top
      wm_width, wm_height,     // width, height
      scaled_watermark, 0, 0,  // source left, top
      BlendMode::kNormal, nullptr, false);

  if (success) {
    LOG_INFO_F(
        "[AP-FORM-IMAGE-WATERMARK] Watermark composited at (0,0), size: %dx%d",
        wm_width, wm_height);
  }

  return success;
}

bool WatermarkCallback::SaveBitmapToFile(CFX_DIBitmap* bitmap,
                                         const std::string& filename) {
  // [AP-FORM-IMAGE-WATERMARK] 保存到临时输出目录
  std::string full_path = output_dir_ + filename;

  // TODO: 实现 PNG 编码保存
  // 当前 PDFium 没有直接的 PNG 编码器，需要使用平台特定的保存方法
  // 或者暂时跳过保存功能

  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Would save to: %s", full_path.c_str());
  LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Bitmap: %dx%d, format: %d",
             bitmap->GetWidth(), bitmap->GetHeight(),
             static_cast<int>(bitmap->GetFormat()));

  return true;
}
