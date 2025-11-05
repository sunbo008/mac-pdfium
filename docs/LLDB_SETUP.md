# LLDB 调试环境配置

## 问题描述

在调试 PDFium 项目时，LLDB 默认显示**汇编代码**而不是**源代码**，这是因为编译器在调试信息中使用了相对路径（如 `../../fpdfsdk/cpdfsdk_renderpage.cpp`），而 LLDB 无法自动解析这些路径。

## 快速配置

只需运行一个命令：

```bash
./setup_lldb.sh
```

脚本会自动：
- ✅ 从模板生成 `.lldbinit` 配置文件
- ✅ 自动检测并设置正确的项目路径
- ✅ 配置用户级 `~/.lldbinit` 以信任项目配置
- ✅ 优化调试显示设置

## 手动配置（不推荐）

如果你更喜欢手动配置：

```bash
# 1. 从模板创建配置
cp .lldbinit.template .lldbinit

# 2. 替换路径（修改为你的实际项目路径）
sed -i '' 's|YOUR_PROJECT_PATH|/Volumes/Lzf-MoveDisk/workspace/github/mac-pdfium|g' .lldbinit

# 3. 配置用户级设置
echo "settings set target.load-cwd-lldbinit true" >> ~/.lldbinit
```

## 使用说明

配置完成后：

1. **重启 IDE**：如果使用 VS Code/Cursor，完全退出后重新打开
2. **选择调试配置**：在调试面板选择 `Debug PdfWinViewer (CodeLLDB)`
3. **开始调试**：设置断点后按 F5

现在调试时应该能看到**源代码**而不是汇编代码了！🎉

## 故障排查

### 调试时仍然显示汇编代码

在 LLDB 调试控制台中检查配置：

```lldb
# 查看源文件映射
(lldb) settings show target.source-map

# 尝试显示源码
(lldb) list

# 查看当前帧信息
(lldb) frame info
```

### 配置未生效

1. 确认配置文件存在：
   ```bash
   ls -la .lldbinit ~/.lldbinit
   ```

2. 检查项目级配置内容：
   ```bash
   cat .lldbinit | grep "settings set target.source-map"
   ```

3. 完全重启 IDE

## 文件说明

| 文件 | 说明 | 版本控制 |
|------|------|----------|
| `.lldbinit.template` | 配置模板 | ✅ 入库 |
| `.lldbinit` | 实际配置（包含本地路径） | ❌ 不入库（已在 .gitignore） |
| `setup_lldb.sh` | 自动配置脚本 | ✅ 入库 |
| `~/.lldbinit` | 用户级全局配置 | N/A |

## 技术细节

### 为什么需要路径映射？

编译器在调试信息中记录的源文件路径是相对路径（如 `../../fpdfsdk/...`），LLDB 需要知道如何将这些相对路径映射到实际文件系统路径。

### 配置原理

通过 `settings set target.source-map` 命令建立路径映射：

```lldb
settings set target.source-map . /actual/project/path
settings append target.source-map ../../fpdfsdk /actual/project/path/fpdfsdk
```

这样 LLDB 就能正确找到源文件并显示。

## 更多信息

详细的调试说明请查看：[docs/debug_setup.md](docs/debug_setup.md)