#!/bin/bash
# 从日志中提取文件名和行号并在 Cursor 中打开
# 使用方法: ./open_file_at_line.sh "cpdf_renderstatus.cpp:417"

if [ $# -eq 0 ]; then
    echo "用法: $0 <文件名:行号>"
    echo "示例: $0 cpdf_renderstatus.cpp:417"
    exit 1
fi

INPUT="$1"
FILE_LINE="$INPUT"

# 提取文件名和行号
if [[ $FILE_LINE =~ ^(.+):([0-9]+)$ ]]; then
    FILE="${BASH_REMATCH[1]}"
    LINE="${BASH_REMATCH[2]}"
    
    # 在项目中查找文件
    FOUND_FILE=$(find . -name "$FILE" -type f 2>/dev/null | head -1)
    
    if [ -z "$FOUND_FILE" ]; then
        echo "❌ 找不到文件: $FILE"
        exit 1
    fi
    
    # 转换为绝对路径
    ABS_PATH=$(cd "$(dirname "$FOUND_FILE")" && pwd)/$(basename "$FOUND_FILE")
    
    echo "📂 打开文件: $ABS_PATH"
    echo "📍 跳转到行: $LINE"
    
    # 使用 Cursor/VSCode 打开文件并跳转到指定行
    # 方法1: 使用 cursor 命令（如果已安装）
    if command -v cursor &> /dev/null; then
        cursor -g "$ABS_PATH:$LINE"
    # 方法2: 使用 code 命令（VSCode）
    elif command -v code &> /dev/null; then
        code -g "$ABS_PATH:$LINE"
    # 方法3: 使用 open 命令
    else
        open -a "Cursor" "$ABS_PATH"
        echo "⚠️  无法自动跳转到行 $LINE，请手动跳转 (Cmd+G)"
    fi
else
    echo "❌ 无效格式，应该是: 文件名:行号"
    exit 1
fi








