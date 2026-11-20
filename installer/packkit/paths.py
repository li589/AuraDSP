"""仓库内所有输入/输出路径的唯一解析点。

`packkit/paths.py` 位于 `installer/packkit/`，`parents[2]` 即仓库根——与
原 `installer/windows/pack.py` 的 `parents[2]` 同值，因此路径口径在拆分
前后完全一致（这是 fixture 测试能原样通过的前提之一）。
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

INSTALLER_DIR = ROOT / "installer"
WINDOWS_DIR = INSTALLER_DIR / "windows"
LINUX_DIR = INSTALLER_DIR / "linux"
PACKKIT_DIR = INSTALLER_DIR / "packkit"
DOCS_DIR = INSTALLER_DIR / "docs"

DIST_DIR = ROOT / "dist"
STAGING_DIR = DIST_DIR / "AuraDSP-Windows-x64"
PACKS_DIR = DIST_DIR / "resources"

BUILD_DIR = ROOT / "build"
REPORTS_DIR = BUILD_DIR / "reports"

# 原生构建产物
DRIVERS_ROOT = ROOT / "core" / "desktop" / "windows-drivers"
DRIVER_SRC_ROOT = DRIVERS_ROOT / "01_vaio_driver"
BRIDGES_OUT = DRIVERS_ROOT / "out"
ENGINE_OUT = ROOT / "core" / "desktop" / "windows" / "out"

INSTALL_DRIVER_PS1 = DRIVER_SRC_ROOT / "install_driver.ps1"

# 安装器子项目
CUSTOM_INSTALLER_DIR = WINDOWS_DIR / "custom_installer"
BOOTSTRAPPER_SRC = CUSTOM_INSTALLER_DIR / "bootstrapper"
WIZARD_DIR = CUSTOM_INSTALLER_DIR / "wizard"
DRIVER_TEMPLATE_DIR = CUSTOM_INSTALLER_DIR / "driver"
INSTALLER_BUILD_DIR = BUILD_DIR / "installer" / "dist"

# 工具
BUILD_WINDOWS_PS1 = ROOT / "tools" / "windows" / "build_windows.ps1"
RESOURCE_PIPELINE = ROOT / "tools" / "resource_pipeline" / "build_packages.py"
DIST_MANIFEST = ROOT / "tools" / "bin" / "dist_manifest.py"
ENV_SANITIZER = ROOT / "tools" / "bin" / "win_env_sanitize.py"
VERSION_RESOLVER = INSTALLER_DIR / "shared" / "version_resolver.py"

# ---- Linux 平台（packkit/linux 的输入） ----
LINUX_BUNDLE = ROOT / "app" / "auradsp_app" / "build" / "linux" / "x64" / "release" / "bundle"
LINUX_SHARED = LINUX_DIR / "shared"
LINUX_APPRUN = LINUX_DIR / "appimage" / "AppRun"
LINUX_TOOLS_PINS = LINUX_DIR / "appimage" / "tools.pins"
LINUX_PORTABLE_README = LINUX_DIR / "portable" / "README.portable.md"
LINUX_RESERVED_MANIFESTS = (
    LINUX_DIR / "flatpak" / "org.auradsp.AuraDSP.yml",
    LINUX_DIR / "snap" / "snapcraft.yaml",
)
ICONS_DIR = ROOT / "app" / "auradsp_app" / "design" / "logo" / "icons"
ICON_SVG = ROOT / "app" / "auradsp_app" / "design" / "logo" / "auradsp-app-icon.svg"
SYNC_ARTIFACTS = ROOT / "tools" / "sync_artifacts.py"

# bundle 里必须存在的宿主侧载荷（缺一件即拒打包，2026-11-10 口径）
LINUX_BUNDLE_REQUIRED = (
    "auradsp_app",
    "lib/libauradsp_engine.so",
    "lib/plugin_host_x64",
    "lib/plugin_host_x86",
)

# App 源码
APP_DIR = ROOT / "app" / "auradsp_app"
