# 日志文件导航指南

本文档介绍如何在查看 `debug.log` 时快速跳转到日志中提到的源代码位置。

## 问题

日志文件中经常包含类似这样的内容：
```
[DEBUG] ProcessImage called - cpdf_renderstatus.cpp:417
[INFO] Rendering image at cpdf_imagerenderer.cpp:256
```

我们希望能够 **Cmd+点击** 这些文件引用来快速跳转到对应的源代码位置。

## 解决方案

### 方案 1: 使用脚本（推荐）

在终端中运行：
```bash
./open_file_at_line.sh cpdf_renderstatus.cpp:417
```

脚本会：
1. 在项目中查找 `cpdf_renderstatus.cpp` 文件
2. 在 Cursor 中打开该文件
3. 自动跳转到第 417 行

**优点**：
- 自动查找文件（即使在子目录中）
- 自动跳转到指定行
- 适用于任何格式的 `文件名:行号`

### 方案 2: VSCode 内置链接（部分支持）

在 log 文件中，某些格式的路径会自动变成可点击链接：

**支持的格式**：
```
./core/fpdfapi/render/cpdf_renderstatus.cpp:417
/Volumes/Lzf-MoveDisk/workspace/github/mac-pdfium/core/fpdfapi/render/cpdf_renderstatus.cpp:417
```

**不支持的格式**：
```
cpdf_renderstatus.cpp:417  ❌ (仅文件名，无路径)
```

**解决方法**：修改日志输出格式，包含相对路径或绝对路径。

### 方案 3: 快速打开文件

1. **复制文件名**（如 `cpdf_renderstatus.cpp`）
2. 按 **Cmd+P** 打开快速打开面板
3. 粘贴文件名，VSCode 会找到所有匹配的文件
4. 选择正确的文件并打开
5. 按 **Cmd+G** 输入行号跳转

### 方案 4: 使用扩展（推荐安装）

安装 **Log File Highlighter** 扩展（已添加到推荐扩展）：

1. 打开扩展面板 (Cmd+Shift+X)
2. 搜索 "Log File Highlighter"
3. 安装扩展

此扩展提供：
- 日志文件语法高亮
- 增强的文件路径识别
- 更好的日志浏览体验

## 改进日志格式（推荐）

修改您的日志输出代码，使用相对路径或完整路径：

### 当前格式
```cpp
LOG_DEBUG("ProcessImage called - cpdf_renderstatus.cpp:417");
```

### 改进格式（相对路径）
```cpp
LOG_DEBUG("ProcessImage called - core/fpdfapi/render/cpdf_renderstatus.cpp:417");
```

### 改进格式（使用宏）
```cpp
// 在 logger.h 中添加宏
#define LOG_LOCATION \
    std::string(__FILE__).substr(std::string(__FILE__).find("core/")) + ":" + std::to_string(__LINE__)

// 使用
LOG_DEBUG("ProcessImage called - " + LOG_LOCATION);
```

这样日志中会显示：
```
ProcessImage called - core/fpdfapi/render/cpdf_renderstatus.cpp:417
```

此格式可以被 VSCode 识别并变成可点击链接！

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| **Cmd+P** | 快速打开文件 |
| **Cmd+G** | 跳转到指定行 |
| **Cmd+Shift+O** | 在日志文件中快速查找符号 |

## 示例工作流

### 使用脚本
```bash
# 在日志中看到: cpdf_renderstatus.cpp:417
# 在终端执行:
./open_file_at_line.sh cpdf_renderstatus.cpp:417
```

### 手动跳转
1. 在日志中看到：`cpdf_renderstatus.cpp:417`
2. 复制文件名：`cpdf_renderstatus.cpp`
3. 按 **Cmd+P**，粘贴文件名
4. 打开文件后，按 **Cmd+G**
5. 输入行号：`417`
6. 回车跳转

## VSCode 配置

已添加的配置（`.vscode/settings.json`）：

```json
{
  "terminal.integrated.enableFileLinks": "on",
  "[Log]": {
    "editor.wordWrap": "off"
  },
  "files.associations": {
    "*.log": "log",
    "debug.log": "log"
  }
}
```

这些配置启用了：
- 终端中的文件链接
- 日志文件的特殊处理
- `.log` 文件的正确识别

## 未来改进

如果需要更强大的功能，可以考虑：

1. **开发 VSCode 扩展**
   - 自定义链接提供器（Link Provider）
   - 支持 `文件名:行号` 格式
   - 自动在项目中查找文件

2. **修改日志格式**
   - 始终输出相对路径或完整路径
   - 确保格式符合 VSCode 的识别规则

3. **使用问题匹配器**
   - 配置 tasks.json
   - 将日志输出转换为可点击的问题列表

## 参考资料

- [VSCode Terminal Links](https://code.visualstudio.com/docs/terminal/basics#_links)
- [Problem Matchers](https://code.visualstudio.com/docs/editor/tasks#_defining-a-problem-matcher)
- [Log File Highlighter](https://marketplace.visualstudio.com/items?itemName=emilast.LogFileHighlighter)


