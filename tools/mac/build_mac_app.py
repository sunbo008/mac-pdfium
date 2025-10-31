#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mac PDF Viewer 构建脚本
自动下载和配置 depot_tools，构建 Mac 应用

使用方法:
  python3 tools/mac/build_mac_app.py                    # 交互式构建
  python3 tools/mac/build_mac_app.py --auto             # 自动构建（默认配置）
  python3 tools/mac/build_mac_app.py --setup-depot-tools # 仅设置 depot_tools
  python3 tools/mac/build_mac_app.py --update-depot-tools # 仅更新 depot_tools
"""

import os
import sys
import subprocess
import platform
import shutil
from pathlib import Path
from typing import Optional
import argparse

# 将项目根目录添加到路径
SCRIPT_DIR = Path(__file__).parent.absolute()
PROJECT_ROOT = SCRIPT_DIR.parent.parent

# 颜色输出类
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'
    
    @classmethod
    def colored(cls, text: str, color: str) -> str:
        return f"{color}{text}{cls.NC}"

class Logger:
    @staticmethod
    def info(message: str):
        print(Colors.colored(f"ℹ️  {message}", Colors.BLUE))
    
    @staticmethod
    def success(message: str):
        print(Colors.colored(f"✅ {message}", Colors.GREEN))
    
    @staticmethod
    def warning(message: str):
        print(Colors.colored(f"⚠️  {message}", Colors.YELLOW))
    
    @staticmethod
    def error(message: str):
        print(Colors.colored(f"❌ {message}", Colors.RED))

# depot_tools 管理类
class DepotToolsManager:
    def __init__(self):
        # 脚本在 tools/mac/，depot_tools 在 tools/depot_tools/
        self.script_dir = SCRIPT_DIR
        self.depot_tools_dir = self.script_dir.parent / "depot_tools"
        self.depot_tools_git_url = "https://github.com/sunbo008/depot_tools.git"
    
    def is_depot_tools_available(self) -> bool:
        """检查 depot_tools 是否可用"""
        try:
            # 检查 PATH 中是否有 gn/ninja
            subprocess.run(["gn", "--version"], capture_output=True, check=True)
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            # 检查本地 depot_tools 目录
            if self.depot_tools_dir.exists():
                gn_path = self.depot_tools_dir / "gn"
                if platform.system().lower() == "windows":
                    gn_path = self.depot_tools_dir / "gn.bat"
                if gn_path.exists():
                    return True
        return False
    
    def download_depot_tools(self):
        """通过 git 克隆 depot_tools"""
        Logger.info("开始克隆 depot_tools...")
        
        if not shutil.which("git"):
            Logger.error("Git 未安装，请先安装 Git")
            Logger.info("macOS: brew install git")
            sys.exit(1)
        
        if self.depot_tools_dir.exists():
            Logger.info(f"删除已存在的目录: {self.depot_tools_dir}")
            shutil.rmtree(self.depot_tools_dir)
        
        Logger.info(f"从 {self.depot_tools_git_url} 克隆...")
        try:
            subprocess.run([
                "git", "clone", "--depth", "1",
                self.depot_tools_git_url,
                str(self.depot_tools_dir)
            ], check=True)
            Logger.success("克隆完成")
        except subprocess.CalledProcessError as e:
            Logger.error(f"Git 克隆失败: {e}")
            Logger.error("请检查网络连接和仓库 URL")
            sys.exit(1)
        
        # 设置可执行权限（Unix 系统）
        if platform.system().lower() != "windows":
            self._set_executable_permissions()
        
        Logger.success(f"depot_tools 已克隆到: {self.depot_tools_dir}")
        
        # 初始化 depot_tools
        Logger.info("初始化 depot_tools...")
        self._initialize_depot_tools()
    
    def _set_executable_permissions(self):
        """设置可执行权限"""
        try:
            for file in self.depot_tools_dir.glob("*"):
                if file.is_file() and not file.suffix:
                    file.chmod(0o755)
        except Exception as e:
            Logger.warning(f"设置权限时出现问题: {e}")
    
    def _is_depot_tools_initialized(self) -> bool:
        """检查 depot_tools 是否已初始化"""
        python3_bin = self.depot_tools_dir / "python-bin" / "python3"
        return python3_bin.exists()
    
    def _initialize_depot_tools(self):
        """初始化 depot_tools"""
        # 检查是否已经初始化
        if self._is_depot_tools_initialized():
            Logger.info("depot_tools 已初始化，跳过初始化步骤")
            return
        
        ensure_bootstrap = self.depot_tools_dir / "ensure_bootstrap"
        if ensure_bootstrap.exists():
            Logger.info("正在初始化 depot_tools（这可能需要几分钟，请耐心等待）...")
            Logger.info("提示：首次初始化会下载 Python 和其他工具，请保持网络连接")
            try:
                # 运行 ensure_bootstrap 来初始化，不捕获输出以便用户看到进度
                subprocess.run([str(ensure_bootstrap)], cwd=self.depot_tools_dir, check=True)
                Logger.success("depot_tools 初始化完成")
            except subprocess.CalledProcessError as e:
                Logger.warning(f"depot_tools 初始化可能失败: {e}")
                Logger.info("尝试继续...")
        else:
            Logger.warning("ensure_bootstrap 脚本未找到，跳过初始化")
    
    def update_depot_tools(self):
        """更新 depot_tools"""
        if not self.depot_tools_dir.exists():
            Logger.warning("depot_tools 目录不存在，无法更新")
            return False
        
        Logger.info("更新 depot_tools 到最新版本...")
        try:
            subprocess.run([
                "git", "pull", "origin", "main"
            ], cwd=self.depot_tools_dir, check=True)
            Logger.success("depot_tools 更新完成")
            return True
        except subprocess.CalledProcessError as e:
            Logger.error(f"更新失败: {e}")
            return False
    
    def add_to_path_now(self):
        """将 depot_tools 添加到当前进程 PATH"""
        depot = str(self.depot_tools_dir)
        cur = os.environ.get("PATH", "")
        if depot not in cur.split(os.pathsep):
            os.environ["PATH"] = depot + os.pathsep + cur
            Logger.info(f"已将 {depot} 添加到当前进程 PATH")
    
    def setup_depot_tools(self, interactive=True):
        """设置 depot_tools"""
        if self.is_depot_tools_available():
            Logger.success("depot_tools 已可用")
            self.add_to_path_now()
            # 确保已初始化（如果还未初始化）
            if self.depot_tools_dir.exists() and not self._is_depot_tools_initialized():
                Logger.info("检测到 depot_tools 未完全初始化，尝试初始化...")
                self._initialize_depot_tools()
            return True
        
        Logger.warning("depot_tools 未安装或未添加到 PATH")
        
        if interactive:
            choice = input("是否自动克隆并配置 depot_tools? (y/n) [默认: y]: ").strip().lower()
            if choice and choice not in ["y", "yes"]:
                Logger.info("请手动安装 depot_tools")
                return False
        
        self.download_depot_tools()
        self.add_to_path_now()
        
        if self.is_depot_tools_available():
            Logger.success("depot_tools 设置完成!")
            return True
        else:
            Logger.warning("depot_tools 设置完成，但可能需要重新打开终端")
            return False

# Mac 应用构建器
class MacAppBuilder:
    def __init__(self):
        self.project_root = PROJECT_ROOT
        self.depot_manager = DepotToolsManager()
    
    def is_first_time_build(self) -> bool:
        """检测是否为首次构建"""
        # 检查关键指标
        buildtools_exists = (self.project_root / "buildtools").exists()
        build_exists = (self.project_root / "build").exists()
        gclient_exists = (self.project_root / ".gclient").exists()
        gclient_entries_exists = (self.project_root / ".gclient_entries").exists()
        
        # 如果 buildtools 和 build 都不存在，基本可以确定是首次构建
        # 或者缺少 gclient 配置文件
        if not buildtools_exists and not build_exists:
            return True
        
        # 如果 buildtools 存在但 build 目录不存在，可能是首次生成构建文件
        # 但这不是首次构建，因为依赖已经下载了
        if not buildtools_exists:
            return True
        
        # 如果缺少 gclient 配置，也可能是首次构建
        if not gclient_exists and not gclient_entries_exists:
            return True
        
        return False
    
    def ensure_dependencies(self):
        """确保依赖已下载（buildtools 等）"""
        # 检测是否为首次构建
        is_first_build = self.is_first_time_build()
        
        if is_first_build:
            Logger.info("🔍 检测到首次构建环境")
            Logger.info("   将自动运行 gclient sync 下载必要的构建工具和依赖项")
            Logger.info("   这可能需要几分钟时间，请保持网络连接...")
        
        # 检查 buildtools 目录
        buildtools_path = self.project_root / "buildtools"
        if not buildtools_path.exists():
            Logger.warning("buildtools 目录不存在")
            Logger.info("depot_tools 的 gn 脚本需要 buildtools 目录")
            Logger.info("正在运行 gclient sync 来下载依赖...")
            
            # 确保 depot_tools 在 PATH 中
            self.depot_manager.add_to_path_now()
            
            try:
                # 运行 gclient sync（只同步 buildtools，不下载所有依赖）
                Logger.info("运行命令: gclient sync --no-history --shallow")
                Logger.info("正在下载依赖（这可能需要几分钟）...")
                subprocess.run([
                    "gclient", "sync", "--no-history", "--shallow"
                ], cwd=self.project_root, check=True)
                Logger.success("✅ 依赖同步完成")
                
                # 验证 buildtools 是否已下载
                if buildtools_path.exists():
                    Logger.success(f"✅ buildtools 已成功下载到: {buildtools_path}")
                else:
                    Logger.warning("⚠️  buildtools 目录仍未创建，可能需要手动运行 gclient sync")
            except subprocess.CalledProcessError as e:
                Logger.error(f"❌ gclient sync 失败: {e}")
                Logger.info("请尝试手动运行: gclient sync --no-history --shallow")
                Logger.info("或者如果已有 buildtools，请确保它在项目根目录下")
                return False
            except FileNotFoundError:
                Logger.error("❌ gclient 命令未找到")
                Logger.info("请确保 depot_tools 已正确设置")
                return False
        else:
            if is_first_build:
                Logger.info("✅ buildtools 目录已存在，跳过依赖下载")
            else:
                Logger.info("✅ 依赖检查通过，buildtools 已就绪")
        
        return True
    
    def get_gn_path(self) -> Path:
        """获取 gn 工具路径"""
        # 优先使用项目 buildtools 中的 gn（如果存在）
        buildtools_gn = self.project_root / "buildtools" / "mac" / "gn"
        if buildtools_gn.exists():
            Logger.info(f"使用项目 buildtools 中的 gn: {buildtools_gn}")
            return buildtools_gn
        
        # 其次使用 depot_tools 中的 gn
        if self.depot_manager.depot_tools_dir.exists():
            gn_path = self.depot_manager.depot_tools_dir / "gn"
            if platform.system().lower() == "windows":
                gn_path = self.depot_manager.depot_tools_dir / "gn.bat"
            if gn_path.exists():
                return gn_path
        
        # 检查系统 PATH 中的 gn
        gn_path = shutil.which("gn")
        if gn_path:
            return Path(gn_path)
        
        Logger.error("未找到 gn 工具，请先设置 depot_tools")
        Logger.info("提示：PDFium 项目需要运行 'gclient sync' 来下载 buildtools")
        sys.exit(1)
    
    def get_ninja_path(self) -> Path:
        """获取 ninja 工具路径"""
        if self.depot_manager.depot_tools_dir.exists():
            ninja_path = self.depot_manager.depot_tools_dir / "ninja"
            if platform.system().lower() == "windows":
                ninja_path = self.depot_manager.depot_tools_dir / "ninja.exe"
            if ninja_path.exists():
                return ninja_path
        
        ninja_path = shutil.which("ninja")
        if ninja_path:
            return Path(ninja_path)
        
        Logger.error("未找到 ninja 工具，请先设置 depot_tools")
        sys.exit(1)
    
    def _detect_cpu(self) -> str:
        """自动检测CPU架构"""
        machine = platform.machine().lower()
        if machine in ["x86_64", "amd64"]:
            return "x64"
        elif machine in ["arm64", "aarch64"]:
            return "arm64"
        else:
            Logger.warning(f"未知架构 {machine}，默认使用 x64")
            return "x64"
    
    def setup_build_config(self, build_dir: Path, is_debug: bool = True):
        """设置构建配置"""
        Logger.info("配置构建参数...")
        
        cpu = self._detect_cpu()
        config_content = f"""# Mac PDF Viewer 构建配置
is_debug = {str(is_debug).lower()}
symbol_level = 2
pdf_enable_fontations = false

# PDFium 配置
pdf_enable_xfa = false
pdf_enable_v8 = false
pdf_is_standalone = true
is_component_build = false
pdf_use_skia = false


# 平台配置
target_os = "mac"
target_cpu = "{cpu}"
mac_sdk_min = "15"

# 编译器配置 - 解决 SDK 兼容性问题
clang_use_chrome_plugins = false
treat_warnings_as_errors = false
use_custom_libcxx = false

# 禁用 Clang 模块以避免 DarwinFoundation1.modulemap 问题
use_clang_modules = false
"""
        
        args_file = build_dir / "args.gn"
        args_file.parent.mkdir(parents=True, exist_ok=True)
        args_file.write_text(config_content, encoding='utf-8')
        Logger.success(f"构建配置已创建: {args_file}")
    
    def build(self, build_type: str = "Debug"):
        """构建 Mac 应用"""
        Logger.info("开始构建 Mac PDF Viewer...")
        
        # 设置 depot_tools
        if not self.depot_manager.setup_depot_tools(interactive=False):
            Logger.error("depot_tools 设置失败")
            sys.exit(1)
        
        # 确保依赖已下载
        if not self.ensure_dependencies():
            Logger.error("依赖检查失败，无法继续构建")
            sys.exit(1)
        
        # 获取工具路径
        gn_path = self.get_gn_path()
        ninja_path = self.get_ninja_path()
        
        # 创建构建目录
        build_dir = self.project_root / "out" / build_type
        build_dir.mkdir(parents=True, exist_ok=True)
        
        # 设置构建配置
        is_debug = (build_type == "Debug")
        self.setup_build_config(build_dir, is_debug)
        
        # 生成构建文件
        Logger.info("生成构建文件...")
        try:
            # 设置 GCLIENT_ROOT 环境变量，让 depot_tools 的 gn 脚本能找到项目根目录
            env = os.environ.copy()
            env["GCLIENT_ROOT"] = str(self.project_root)
            
            subprocess.run([
                str(gn_path), "gen", str(build_dir)
            ], cwd=self.project_root, check=True, env=env)
            Logger.success("构建文件生成成功")
        except subprocess.CalledProcessError as e:
            Logger.error(f"❌ GN 生成失败: {e}")
            Logger.error("请检查构建配置和依赖")
            
            # 检查是否为首次构建相关的问题
            if self.is_first_time_build() or not (self.project_root / "buildtools").exists():
                Logger.warning("⚠️  这可能是因为依赖未完全下载")
                Logger.info("请尝试手动运行: gclient sync --no-history --shallow")
            else:
                Logger.info("请检查构建配置和依赖项是否正确")
            sys.exit(1)
        
        # 构建应用
        Logger.info("开始编译（预计需要 10-30 分钟）...")
        try:
            subprocess.run([
                str(ninja_path), "-C", str(build_dir), "mac_pdf_viewer"
            ], cwd=self.project_root, check=True)
            Logger.success("编译完成")
        except subprocess.CalledProcessError as e:
            Logger.error(f"编译失败: {e}")
            Logger.error("请检查错误信息并修复问题")
            sys.exit(1)
        
        # 验证结果
        app_binary = build_dir / "mac_pdf_viewer"
        if app_binary.exists():
            file_size = app_binary.stat().st_size
            size_mb = file_size // (1024 * 1024)
            Logger.success("编译完成")
            
            # 打包为 .app bundle
            Logger.info("正在打包为 .app bundle...")
            app_bundle = self.package_app_bundle(build_dir, app_binary)
            Logger.success("Mac PDF Viewer 构建成功!")
            Logger.info(f"应用位置: {app_bundle}")
            Logger.info(f"文件大小: {size_mb}MB")
        else:
            Logger.error("构建失败，应用未生成")
            sys.exit(1)
    
    def package_app_bundle(self, build_dir: Path, app_binary: Path) -> Path:
        """将可执行文件打包为 .app bundle"""
        app_name = "PdfWinViewer.app"
        app_bundle = build_dir / app_name
        contents_dir = app_bundle / "Contents"
        macos_dir = contents_dir / "MacOS"
        resources_dir = contents_dir / "Resources"
        
        # 创建目录结构
        macos_dir.mkdir(parents=True, exist_ok=True)
        resources_dir.mkdir(parents=True, exist_ok=True)
        
        # 复制可执行文件
        app_executable = macos_dir / "PdfWinViewer"
        shutil.copy2(app_binary, app_executable)
        
        # 设置可执行权限
        os.chmod(app_executable, 0o755)
        
        # 复制 Info.plist
        info_plist_src = self.project_root / "platform" / "mac" / "Info.plist"
        if info_plist_src.exists():
            info_plist_dst = contents_dir / "Info.plist"
            shutil.copy2(info_plist_src, info_plist_dst)
        else:
            # 如果 Info.plist 不存在，创建一个基本的
            self.create_info_plist(contents_dir)
        
        return app_bundle
    
    def create_info_plist(self, contents_dir: Path):
        """创建基本的 Info.plist 文件"""
        info_plist = contents_dir / "Info.plist"
        plist_content = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PdfWinViewer</string>
    <key>CFBundleDisplayName</key>
    <string>PdfWinViewer</string>
    <key>CFBundleIdentifier</key>
    <string>com.zfleng.PdfWinViewer</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>PdfWinViewer</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>"""
        info_plist.write_text(plist_content, encoding='utf-8')

def main():
    parser = argparse.ArgumentParser(description="Mac PDF Viewer 构建脚本")
    parser.add_argument("--auto", action="store_true", help="自动构建（使用默认配置）")
    parser.add_argument("--setup-depot-tools", action="store_true", help="仅设置 depot_tools")
    parser.add_argument("--update-depot-tools", action="store_true", help="仅更新 depot_tools")
    parser.add_argument("--build-type", choices=["Debug", "Release"], default="Debug", help="构建类型")
    
    args = parser.parse_args()
    
    builder = MacAppBuilder()
    
    if args.setup_depot_tools:
        builder.depot_manager.setup_depot_tools()
        return
    
    if args.update_depot_tools:
        builder.depot_manager.update_depot_tools()
        return
    
    # 构建应用
    builder.build(args.build_type)

if __name__ == "__main__":
    main()

