#!/bin/bash
# 快速调试脚本

cd "$(dirname "$0")"

echo "🔨 编译应用..."
if ! ./build_mac.sh; then
    echo "❌ 编译失败，退出"
    exit 1
fi

APP_PATH="out/Debug/PdfWinViewer.app/Contents/MacOS/PdfWinViewer"

if [ ! -f "$APP_PATH" ]; then
    echo "❌ 找不到可执行文件: $APP_PATH"
    exit 1
fi

echo ""
echo "🐛 启动调试器..."
echo ""

# 创建临时 lldb 命令文件
LLDB_SCRIPT=$(mktemp)
cat > "$LLDB_SCRIPT" << 'LLDBEOF'
# 设置关键断点
breakpoint set --file cpdf_renderstatus.cpp --line 1534 -C "print in_appearance_form_"
breakpoint set --file cpdf_renderstatus.cpp --line 1534 -C "print image_callback_"
breakpoint set --file App.mm --line 571
breakpoint set --file cpdf_renderstatus.cpp --line 1449 -C "print in_appearance_form_"
breakpoint set --file cpdf_renderstatus.cpp --line 360 -C "print in_appearance_form_"

# 显示断点
breakpoint list

# 运行应用
run
LLDBEOF

# 启动 lldb
lldb -s "$LLDB_SCRIPT" "$APP_PATH"

# 清理临时文件
rm -f "$LLDB_SCRIPT"

