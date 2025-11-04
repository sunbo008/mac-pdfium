#!/bin/bash
# 检查本地 clangd 缓存

cd /Volumes/Lzf-MoveDisk/workspace/github/mac-pdfium

echo "🔍 检查本地 clangd 缓存"
echo "========================================"
echo ""

echo "【1】缓存目录："
if [ -d ".clangd-cache/tmp" ]; then
    echo "✓ .clangd-cache/tmp 存在"
    
    # 统计缓存文件
    pch_count=$(find .clangd-cache/tmp -name "preamble-*.pch" 2>/dev/null | wc -l)
    if [ "$pch_count" -gt 0 ]; then
        echo "✓ 找到 $pch_count 个 preamble 文件"
        echo ""
        echo "总大小："
        du -sh .clangd-cache/tmp 2>/dev/null
        echo ""
        echo "最新文件（前5个）："
        ls -lht .clangd-cache/tmp/preamble-*.pch 2>/dev/null | head -5
    else
        echo "⏳ 尚未生成 preamble 文件"
        echo "   提示：请在 Cursor 中重新加载窗口并打开 C++ 文件"
    fi
else
    echo "✗ .clangd-cache/tmp 不存在"
    echo "   正在创建..."
    mkdir -p .clangd-cache/tmp
    echo "✓ 已创建"
fi

echo ""
echo "【2】clangd wrapper 脚本："
if [ -x ".clangd-cache/clangd-wrapper.sh" ]; then
    echo "✓ clangd-wrapper.sh 存在且可执行"
else
    echo "✗ clangd-wrapper.sh 不存在或不可执行"
fi

echo ""
echo "【3】VSCode 配置："
if grep -q "clangd-wrapper.sh" .vscode/settings.json 2>/dev/null; then
    echo "✓ VSCode 已配置使用本地 wrapper"
else
    echo "✗ VSCode 未配置使用本地 wrapper"
fi

echo ""
echo "========================================"
echo "💡 如果缓存未生成，请在 Cursor 中："
echo "   1. Cmd+Shift+P"
echo "   2. Developer: Reload Window"
echo "   3. 打开任意 C++ 文件"


