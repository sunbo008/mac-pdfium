#!/bin/bash
# Mac PDF Viewer 快速构建脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 检查 Python
if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 未安装"
    exit 1
fi

# 运行构建脚本
python3 tools/mac/build_mac_app.py --auto --build-type Debug

echo ""
echo "🎉 构建完成!"
echo "应用位置: out/Debug/PdfWinViewer.app"

