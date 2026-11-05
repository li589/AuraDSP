# AuraDSP Windows 打包与安装体系

本目录管理 AuraDSP 在 Windows x64 平台上的全部发布与安装工具链。

## 1. 产物双轨制 (Two Release Tracks)

Windows 平台支持两种平行的分发模式：

1. **便携版 (Portable Edition)**：
   - 目录：`installer/windows/portable/`
   - 目标产物：`dist/AuraDSP-Windows-x64-v<ver>.zip`
   - 特点：绿色解压即用，支持便携模式（配置文件位于本地运行目录，不写系统注册表）。
2. **自研安装程序版 (Custom Installer Edition)**：
   - 目录：`installer/windows/custom_installer/`
   - 目标产物：`dist/AuraDSP-Setup-x64-v<ver>.exe`
   - 特点：拥有现代暗黑美学向导、自动关闭占用进程、集成 AuraASIO COM 注册、AuraVAIO 驱动配置、开始菜单/桌面快捷方式与 Windows 设置卸载支持。

---

## 2. 目录结构

- `portable/`：便携版归档脚本、排除规则（如排除开发临时符号、调试 pdb）、目录规整逻辑。
- `custom_installer/`：自研安装程序独立子项目源码与打包配置。
- `build_windows_dist.ps1`（规划中）：一键触发“便携版压缩 + 自研安装程序编译 + 产物移至 dist/”的总入口脚本。

