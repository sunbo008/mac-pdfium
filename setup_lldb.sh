#!/bin/bash
# LLDB 调试环境配置脚本
# 
# 功能说明：
# 1. 从 .lldbinit.template 生成 .lldbinit 文件
# 2. 自动检测并替换项目路径
# 3. 配置用户级 ~/.lldbinit 以信任项目配置
# 4. 优化调试体验，确保调试时显示源码而不是汇编代码
#
# 使用方法：
#   ./setup_lldb.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}   LLDB 调试环境配置脚本${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 获取脚本所在目录（即项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${YELLOW}📁 项目路径:${NC} $SCRIPT_DIR"
echo ""

# 检查模板文件是否存在
if [ ! -f ".lldbinit.template" ]; then
    echo -e "${RED}❌ 错误: 找不到 .lldbinit.template 文件${NC}"
    exit 1
fi

# 步骤1: 生成项目级 .lldbinit 文件
echo -e "${YELLOW}[1/3]${NC} 生成项目级 .lldbinit 文件..."

if [ -f ".lldbinit" ]; then
    echo -e "${YELLOW}⚠️  .lldbinit 文件已存在，是否覆盖？ [y/N]${NC}"
    read -r response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo -e "${BLUE}ℹ️  跳过生成 .lldbinit${NC}"
    else
        # 备份现有文件
        mv .lldbinit .lldbinit.backup
        echo -e "${GREEN}✓${NC} 已备份现有配置到 .lldbinit.backup"
        
        # 从模板生成
        sed "s|YOUR_PROJECT_PATH|$SCRIPT_DIR|g" .lldbinit.template > .lldbinit
        echo -e "${GREEN}✓${NC} .lldbinit 已生成"
    fi
else
    # 从模板生成
    sed "s|YOUR_PROJECT_PATH|$SCRIPT_DIR|g" .lldbinit.template > .lldbinit
    echo -e "${GREEN}✓${NC} .lldbinit 已生成"
fi

echo ""

# 步骤2: 配置用户级 ~/.lldbinit
echo -e "${YELLOW}[2/3]${NC} 配置用户级 ~/.lldbinit..."

USER_LLDBINIT=~/.lldbinit
NEED_UPDATE=false

if [ -f "$USER_LLDBINIT" ]; then
    # 检查是否已包含必要的配置
    if grep -q "target.load-cwd-lldbinit" "$USER_LLDBINIT"; then
        echo -e "${GREEN}✓${NC} ~/.lldbinit 已包含必要配置"
    else
        echo -e "${YELLOW}⚠️  ~/.lldbinit 存在但缺少必要配置，是否添加？ [y/N]${NC}"
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            NEED_UPDATE=true
        fi
    fi
else
    NEED_UPDATE=true
fi

if [ "$NEED_UPDATE" = true ]; then
    # 备份现有文件（如果存在）
    if [ -f "$USER_LLDBINIT" ]; then
        cp "$USER_LLDBINIT" "$USER_LLDBINIT.backup"
        echo -e "${GREEN}✓${NC} 已备份现有配置到 ~/.lldbinit.backup"
    fi
    
    # 添加或创建配置
    cat >> "$USER_LLDBINIT" << 'EOF'

# ===== Mac PDFium 项目配置 =====
# 自动加载项目目录中的 .lldbinit 文件
settings set target.load-cwd-lldbinit true

# 优化调试显示（不显示汇编代码）
settings set stop-disassembly-display never

# 确认配置已加载
script print("🔧 用户级 LLDB 配置已加载")
# ===== 配置结束 =====
EOF
    echo -e "${GREEN}✓${NC} ~/.lldbinit 配置已更新"
fi

echo ""

# 步骤3: 验证配置
echo -e "${YELLOW}[3/3]${NC} 验证配置..."

if [ -f ".lldbinit" ] && [ -f "$USER_LLDBINIT" ]; then
    # 检查路径是否正确替换
    if grep -q "YOUR_PROJECT_PATH" .lldbinit; then
        echo -e "${RED}❌ 错误: .lldbinit 中仍包含 YOUR_PROJECT_PATH 占位符${NC}"
        exit 1
    fi
    
    # 检查路径是否包含当前项目路径
    if grep -q "$SCRIPT_DIR" .lldbinit; then
        echo -e "${GREEN}✓${NC} 配置验证通过"
    else
        echo -e "${YELLOW}⚠️  警告: .lldbinit 中未找到项目路径${NC}"
    fi
else
    echo -e "${RED}❌ 配置文件不完整${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ LLDB 调试环境配置完成！${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}📝 后续步骤：${NC}"
echo ""
echo -e "  1. 如果你在使用 VS Code/Cursor，请${YELLOW}完全退出并重新打开${NC}"
echo -e "  2. 在调试配置中选择 ${BLUE}\"Debug PdfWinViewer (CodeLLDB)\"${NC}"
echo -e "  3. 设置断点后按 F5 开始调试"
echo -e "  4. 现在调试时应该能看到源代码，而不是汇编代码了！"
echo ""
echo -e "${YELLOW}🔍 故障排查：${NC}"
echo ""
echo -e "  如果调试时仍然显示汇编代码，在调试控制台中运行："
echo -e "    ${BLUE}settings show target.source-map${NC}"
echo -e "    ${BLUE}list${NC}"
echo ""
echo -e "${YELLOW}📚 更多信息：${NC}"
echo -e "  查看项目文档: ${BLUE}docs/debug_setup.md${NC}"
echo ""

