# Project Context

## Purpose
mac-pdfium 是 PDFium 的 macOS 平台定制版本，基于 Google 的 PDFium 库（Chromium 的 PDF 渲染引擎）。项目目标：
- 为 macOS 平台提供高性能的 PDF 渲染能力
- 添加 macOS 原生界面和交互功能
- 扩展 PDFium 功能，包括图片水印、表单处理、注释渲染等
- 提供独立的 macOS PDF 查看器应用

## Tech Stack
- **核心语言**: C++20 (主要代码库)
- **平台代码**: Objective-C++ (.mm 文件) for macOS
- **构建系统**: GN (Generate Ninja) + Ninja
- **JavaScript 引擎**: V8 (可选，用于 PDF JavaScript 支持)
- **图形后端**: AGG (默认) / Skia (实验性)
- **UI 框架**: macOS AppKit.framework
- **依赖管理**: gclient (Chromium depot_tools)

### 关键第三方库
- FreeType: 字体渲染 (bundled)
- Fontations: Rust 字体库 (实验性)
- libjpeg/libpng/libtiff: 图片编解码
- zlib: 压缩
- lcms2: 颜色管理
- libopenjpeg2: JPEG2000 解码

## Project Conventions

### Code Style
- 遵循 [Chromium C++ Style Guide](https://chromium.googlesource.com/chromium/src/+/main/styleguide/c++/c++.md)
- 使用 Clang 编译器（推荐 clang-cl on Windows）
- 命名约定：
  - 类名: `PascalCase` (e.g., `CPDF_Image`, `CFX_DIBitmap`)
  - 函数名: `PascalCase` (e.g., `LoadDIBBase()`)
  - 变量名: `snake_case` with trailing underscore for members (e.g., `stream_`, `dibbase_`)
  - 常量: `kPascalCase` (e.g., `kMaxImageSize`)
- 文件命名: `snake_case` (e.g., `cpdf_image.cpp`, `cfx_dibitmap.h`)
- 头文件保护: `#ifndef CORE_FPDFAPI_PAGE_CPDF_IMAGE_H_`
- UTF-8 编码（Windows 使用 `/utf-8` 编译选项）

### Architecture Patterns
- **模块化分层架构**:
  - `public/`: 公共 API 头文件（稳定接口）
  - `core/`: 核心 PDF 解析和渲染逻辑
    - `fpdfapi/`: PDF API 实现 (parser, page, render, edit, font)
    - `fpdfdoc/`: PDF 文档结构 (表单、注释、动作)
    - `fpdftext/`: 文本提取
    - `fxcodec/`: 图片编解码器
    - `fxcrt/`: 运行时基础库 (容器、字符串、内存管理)
    - `fxge/`: 图形引擎 (绘图、字体、设备抽象)
  - `fpdfsdk/`: Embedder SDK
  - `xfa/`: XFA 表单支持（可选）
  - `fxjs/`: JavaScript 支持（可选）
  - `platform/`: 平台特定代码
    - `mac/`: macOS 应用实现
    - `shared/`: 跨平台共享工具

- **智能指针和所有权**:
  - `RetainPtr<T>`: 引用计数智能指针（类似 `std::shared_ptr`）
  - `UnownedPtr<T>`: 非所有权原始指针包装器
  - 避免手动内存管理

- **设备无关位图 (DIB) 模式**:
  - `CFX_DIBBase`: 抽象位图基类
  - `CFX_DIBitmap`: 具体位图实现
  - `CPDF_DIB`: PDF 流的 DIB 解码器

### Testing Strategy
- **测试类型**:
  - `pdfium_unittests`: 单元测试 (gtest/gmock)
  - `pdfium_embeddertests`: 嵌入器集成测试
  - `run_corpus_tests.py`: 语料库测试
  - `run_javascript_tests.py`: JavaScript 测试
  - `run_pixel_tests.py`: 像素级渲染测试

- **测试文件格式**:
  - `.pdf`: 标准 PDF 测试文件
  - `.in`: PDF 模板文件（通过 `fixup_pdf_template.py` 转换）
  - `.expected.*.png`: 预期渲染结果

- **测试要求**:
  - 所有新功能必须包含测试（单元测试或集成测试）
  - 渲染变化需要添加像素测试 (`testing/resources/pixel/`)
  - 测试文件应使用 `ASCIIHexDecode` 而非二进制流以提高可读性
  - 使用 `optipng` 优化 PNG 测试图片

### Git Workflow
- **分支策略**:
  - `main`: 主分支（跟踪上游 PDFium）
  - `feature/*`: 功能分支（如 `feature/form-image-watermark`）
  - 跟踪上游: 定期同步 Google 的 PDFium 仓库

- **提交规范**:
  - 遵循 Chromium 提交格式
  - 功能标记: 使用注释标记功能点 (e.g., `// [AP-FORM-IMAGE-WATERMARK]`)
  - 变更必须通过代码审查
  - 提交前必须通过所有 trybot 测试

- **代码审查**:
  - 所有变更需要 committer 审查
  - OWNERS 文件定义审查权限
  - 使用 Gerrit 进行代码审查

## Domain Context

### PDF 术语
- **AP (Appearance) Stream**: 注释外观流，定义注释的视觉呈现
- **Form XObject**: 可重用的图形内容流
- **DIB (Device Independent Bitmap)**: 设备无关位图
- **Stream**: PDF 中的二进制数据对象（可压缩）
- **Content Stream**: 包含绘图操作符的流
- **Annotation**: PDF 注释对象（高亮、文本、图章等）

### 关键代码路径
- **图片渲染流程**: `CPDF_Annot` → `CPDF_Form` → `CPDF_RenderStatus` → `CPDF_ImageRenderer` → `CPDF_ImageLoader` → `CPDF_Image` → `CPDF_DIB`
- **流解码**: `CPDF_Stream` → `CPDF_StreamAcc` → 解码器 (JPX/JBIG2/DCT/Flate)
- **表单渲染**: `CPDF_FormObject` → `CPDF_Form::ParseContent()` → Content Stream Processor

### 编码类型
- **DCT**: JPEG 编码
- **JPX**: JPEG2000
- **JBIG2**: 单色图片压缩
- **Flate**: zlib 压缩
- **CCITTFax**: 传真压缩

## Important Constraints

### 技术约束
- **编译器**: 必须使用 Clang（不接受 MSVC patches，社区 GCC patches 可考虑）
- **架构**: 主要支持 x64，Windows 支持 x86，Android 默认 arm
- **大端架构**: 不保证支持（已知问题）
- **C++ 版本**: C++20
- **依赖隔离**: `public/` 外的代码可随时变更，embedder 不应直接调用

### API 稳定性
- **Experimental API**: 可随时变更或移除（文档标记 `// Experimental API.`）
- **Stable API**: 变更前需社区通知（移除 experimental 标记）
- **Deprecated API**: 6-12 个月弃用期，提供替代方案

### 性能约束
- **大文件支持**: 需要流式加载和增量渲染
- **内存管理**: 使用 PartitionAlloc（可选）进行内存隔离
- **缓存策略**: 页面图片缓存 (`CPDF_PageImageCache`)

### 平台约束
- **macOS**: 需要 AppKit 和 CoreFoundation
- **Fonts**: macOS 使用系统字体 + FreeType fallback
- **沙盒**: 构建默认在沙盒中运行（网络/git 操作需申请权限）

## External Dependencies

### 构建工具
- **depot_tools**: Chromium 工具链（包含 gclient, gn, ninja）
- **gclient**: 依赖管理和同步
- **gn**: 元构建系统（生成 Ninja 文件）
- **ninja**: 实际构建执行器

### 上游依赖
- **Chromium build**: 共享构建配置和工具
- **V8**: JavaScript 引擎（如果 `pdf_enable_v8=true`）
- **Skia**: 图形库（如果 `pdf_use_skia=true`）

### 社区和支持
- **邮件列表**:
  - [PDFium](https://groups.google.com/forum/#!forum/pdfium): 讨论
  - [PDFium Reviews](https://groups.google.com/forum/#!forum/pdfium-reviews): 代码审查（只读）
  - [PDFium Bugs](https://groups.google.com/forum/#!forum/pdfium-bugs): Bug 通知（只读）
- **Bug Tracker**: [crbug.com/pdfium](https://crbug.com/pdfium/new)
- **Code Review**: Gerrit (pdfium-review.googlesource.com)
- **CI/CD**: [Chromium CI](https://ci.chromium.org/p/pdfium/g/main/console)

### 文档资源
- 本地文档: `docs/` 目录（包含功能实现详解）
- 上游文档: Chromium build instructions
- 代码覆盖率: [Chromium Coverage](https://chromium-coverage.appspot.com/) (third_party/pdfium)

## Current Features

### 已实现功能
- **AP-Form 图片水印**: 在注释外观表单中添加图片水印
  - 位置: `platform/shared/watermark_callback.cpp`
  - 文档: `docs/ap-form-image-watermark.md`
  - 资源: `platform/shared/Resources/watermark.jpeg`
  
- **macOS PDF 查看器**:
  - 拖放打开 PDF
  - 书签导航面板
  - 文本选择和复制
  - 页面缩放和滚动
  - 最近文件管理
  - Inspector 面板（对象信息查看）
  - 状态栏显示

### 构建配置
```gn
use_remoteexec = false
is_debug = true
pdf_use_skia = false
pdf_enable_fontations = false
pdf_enable_xfa = true
pdf_enable_v8 = true
pdf_is_standalone = true
is_component_build = false
```

## Development Tools

### 调试工具
- `debug.sh`: 调试脚本
- `setup_lldb.sh`: LLDB 调试配置
- `open_file_at_line.sh`: 在编辑器中打开文件到指定行
- `watch_clangd.sh`: 监控 clangd 日志
- `check_clangd.sh`: 检查 clangd 状态

### 日志系统
- `LogManager`: 统一日志管理 (`platform/mac/Utils/LogManager.mm`)
- `FXSYS_LOG_*` 宏: 核心日志接口
- 输出位置: `out/Debug/PdfWinViewer.app/Contents/MacOS/debug.log`

### 编译命令数据库
- `compile_commands.json`: Clang 工具链索引
- `compile_commands.json.backup`: 备份

## Special Notes for AI Assistants

### 重要文件不要修改
- `public/*.h`: 公共 API 头文件（需要社区讨论才能变更）
- `DEPS`: 依赖版本锁定
- `AUTHORS`: 贡献者列表（需要 CLA）

### 常见任务
1. **添加新功能**: 先在 `openspec/changes/` 创建提案
2. **修改渲染**: 在 `core/fpdfapi/render/` 添加逻辑
3. **扩展 macOS 界面**: 在 `platform/mac/` 添加 Objective-C++ 代码
4. **添加测试**: 在对应模块的 `*_unittest.cpp` 或 `*_embeddertest.cpp`

### 代码搜索提示
- 使用 `CPDF_` 前缀搜索 PDF 对象类
- 使用 `CFX_` 前缀搜索 FX 库类
- 使用 `FXSYS_` 前缀搜索系统级宏和函数
- 关键对象: `CPDF_Document`, `CPDF_Page`, `CPDF_RenderContext`, `CFX_RenderDevice`
