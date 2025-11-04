# 调试环境配置指南

## 1. 使用 lldb 命令行调试

### 基本调试命令

```bash
# 启动应用并附加调试器
cd /Volumes/Lzf-MoveDisk/workspace/github/mac-pdfium
lldb out/Debug/PdfWinViewer.app/Contents/MacOS/PdfWinViewer

# 在 lldb 中设置断点
(lldb) breakpoint set --file cpdf_renderstatus.cpp --line 1534
(lldb) breakpoint set --file App.mm --line 571

# 运行应用
(lldb) run

# 查看变量
(lldb) frame variable
(lldb) print in_appearance_form_
(lldb) print image_callback_

# 继续执行
(lldb) continue

# 单步执行
(lldb) step
(lldb) next

# 查看调用栈
(lldb) bt
```

### 关键断点位置

1. **回调调用位置**：
   - `core/fpdfapi/render/cpdf_renderstatus.cpp:1534` - `OnImageRendering` 调用

2. **回调实现位置**：
   - `platform/mac/App.mm:571` - `WatermarkImageCallback::OnImageRendering`

3. **ProcessImage 入口**：
   - `core/fpdfapi/render/cpdf_renderstatus.cpp:1449` - `ProcessImage` 函数开始

4. **ContinueSingleObject 入口**：
   - `core/fpdfapi/render/cpdf_renderstatus.cpp:360` - `ContinueSingleObject` 函数开始

5. **ProcessForm 入口**：
   - `core/fpdfapi/render/cpdf_renderstatus.cpp:530` - `ProcessForm` 函数开始

## 2. 使用 VS Code 调试（推荐）

### 安装 C++ 扩展

安装 Microsoft C/C++ 扩展。

### 创建 launch.json

在 `.vscode/launch.json` 中配置：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug PdfWinViewer",
      "type": "cppdbg",
      "request": "launch",
      "program": "${workspaceFolder}/out/Debug/PdfWinViewer.app/Contents/MacOS/PdfWinViewer",
      "args": [],
      "stopAtEntry": false,
      "cwd": "${workspaceFolder}",
      "environment": [],
      "externalConsole": false,
      "MIMode": "lldb",
      "preLaunchTask": "build",
      "setupCommands": [
        {
          "description": "Enable pretty-printing",
          "text": "settings set target.process.stop-on-sharedlibrary-events 1",
          "ignoreFailures": true
        },
        {
          "description": "Set breakpoint on OnImageRendering",
          "text": "breakpoint set --file cpdf_renderstatus.cpp --line 1534",
          "ignoreFailures": true
        }
      ]
    }
  ]
}
```

### 创建 tasks.json

在 `.vscode/tasks.json` 中配置：

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "build",
      "type": "shell",
      "command": "./build_mac.sh",
      "group": {
        "kind": "build",
        "isDefault": true
      },
      "problemMatcher": []
    }
  ]
}
```

## 3. 使用 Xcode 调试（需要生成 Xcode 项目）

### 生成 Xcode 项目

```bash
cd /Volumes/Lzf-MoveDisk/workspace/github/mac-pdfium
gn gen out/Debug --ide=xcode
open out/Debug/all.xcworkspace
```

### 在 Xcode 中设置断点

1. 打开 `all.xcworkspace`
2. 找到 `cpdf_renderstatus.cpp` 文件
3. 在第1534行设置断点（`OnImageRendering` 调用）
4. 运行应用

## 4. 查看日志输出

### 实时查看日志

```bash
# 查看日志文件
tail -f out/Debug/PdfWinViewer.app/debug.log

# 查看 stderr 输出（如果在终端运行）
./out/Debug/PdfWinViewer.app/Contents/MacOS/PdfWinViewer 2>&1 | grep -E "ProcessImage|OnImageRendering|ContinueSingleObject"
```

### 日志位置

- **应用日志**：`out/Debug/PdfWinViewer.app/debug.log`
- **Fallback日志**：`/tmp/PdfWinViewer_debug.log`
- **stderr输出**：控制台输出（如果从终端运行）

## 5. 调试技巧

### 检查回调是否设置

在 `ProcessImage` 函数开始处添加断点，检查：
- `in_appearance_form_` 是否为 `true`
- `image_callback_` 是否为非空指针

### 检查调用栈

```lldb
(lldb) bt
# 应该看到类似这样的调用栈：
# 0  CPDF_RenderStatus::ProcessImage
# 1  CPDF_RenderStatus::ProcessObjectNoClip
# 2  CPDF_RenderStatus::RenderSingleObject
# 3  CPDF_RenderStatus::RenderObjectList
# 4  CPDF_RenderStatus::ProcessForm
# ...
```

### 检查 Form 对象

```lldb
# 在 ProcessForm 中检查
(lldb) print pFormObj->form()->GetDict()
(lldb) print pFormObj->form()->GetParseState()
```

### 检查图片对象

```lldb
# 在 ProcessImage 中检查
(lldb) print pImageObj->GetImage()
(lldb) print pImageObj->GetImage()->GetStream()
```

## 6. 常见问题

### 断点无法命中

1. 确认代码已编译（`./build_mac.sh`）
2. 确认是 Debug 构建（不是 Release）
3. 检查断点位置是否正确

### 变量无法查看

1. 确认使用 Debug 构建
2. 检查符号文件是否存在
3. 使用 `frame variable` 查看所有变量

### 日志没有输出

1. 检查日志文件权限
2. 检查 `RenderStatusLog` 是否被调用
3. 检查 stderr 输出（如果从终端运行）

## 7. 快速调试脚本

使用 `debug.sh` 脚本：

```bash
./debug.sh
```

脚本会自动编译并启动 lldb 调试器，设置关键断点。

## 8. VS Code 调试问题排查

### 问题：调试时出现 "Process is not running" 错误

**错误信息：**
```
Unexpected LLDB output from command "-exec-interrupt". Process is not running.
调试模式没有看到程序界面
```

### 解决方案

#### 方案 1：使用命令行调试（最可靠）⭐

直接使用 `debug.sh` 脚本：

```bash
./debug.sh
```

这会使用 lldb 命令行调试器，最可靠，能够看到 GUI 界面。

#### 方案 2：使用 VS Code 附加调试

如果 VS Code 直接启动调试有问题：

1. **先手动启动应用**
   ```bash
   open out/Debug/PdfWinViewer.app
   ```

2. **在 VS Code 中选择 "Debug PdfWinViewer (Attach)" 配置**
   - 按 `F5` 启动调试
   - 选择 "Debug PdfWinViewer (Attach)"
   - 在弹出的进程列表中选择 PdfWinViewer

#### 方案 3：修复 VS Code 直接调试

1. **确保应用程序已编译**
   ```bash
   ./build_mac.sh
   ```

2. **检查是否有已运行的实例**
   ```bash
   ps aux | grep PdfWinViewer
   killall PdfWinViewer  # 如果有，先杀掉
   ```

3. **测试应用程序是否能正常启动**
   ```bash
   ./out/Debug/PdfWinViewer.app/Contents/MacOS/PdfWinViewer
   ```
   如果手动运行能看到界面，说明问题在调试器配置。

4. **在 VS Code 中启动调试**
   - 按 `F5` 或点击调试按钮
   - 选择 "Debug PdfWinViewer (macOS)" 配置

### 常见问题

#### 应用程序立即退出

**检查日志文件：**
```bash
tail -f out/Debug/PdfWinViewer.app/debug.log
```

**检查系统日志：**
```bash
log show --predicate 'process == "PdfWinViewer"' --last 5m
```

#### 看不到 GUI 窗口

macOS GUI 应用需要在前台运行。检查应用包结构：

```bash
ls -la out/Debug/PdfWinViewer.app/Contents/
# 应该看到：
# - MacOS/ - 包含可执行文件
# - Info.plist - 应用配置文件
```

#### 调试器连接失败

**检查 lldb 是否可用：**
```bash
which lldb
/usr/bin/lldb --version
```

**手动测试 lldb：**
```bash
lldb out/Debug/PdfWinViewer.app/Contents/MacOS/PdfWinViewer
(lldb) run
```

如果手动 lldb 可以工作，但 VS Code 不行，可能是 VS Code 配置问题。

### 推荐的调试工作流

1. **首次调试时**：使用 `debug.sh` 脚本 ✅
2. **日常开发**：使用 VS Code 附加调试
3. **复杂问题**：使用命令行 lldb

