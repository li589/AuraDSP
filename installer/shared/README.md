# Installer Shared Resources (跨平台共享资源)

本目录汇集所有平台在安装与打包时复用的通用非代码资产。

## 子目录划分

- `assets/`：
  - 应用主图标：`app_icon.ico` (Windows 多尺寸内嵌), `app_icon.png` (Linux 256x256/512x512), `app_icon.svg` (矢量图标), `app_icon.icns` (macOS 图标)。
  - 安装向导横幅 (Banner) 与品牌水印背景图。
- `license/`：
  - `LICENSE`：GPL-3.0 / LGPL 开源许可主文本。
  - `EULA.txt`：终端用户许可协议（供 Windows 安装向导欢迎页展示）。
  - `THIRD_PARTY_NOTICES.txt`：所有内嵌第三方库（FFmpeg, Steinberg VST3 SDK, RDKit/DSP/JUCE 等）的版权声明声明汇编。
- `metadata/`：
  - `app_info.json`：应用多语言显示名称、官方主页、更新服务器、技术支持邮箱等。
  - `version_resolver.py`：从 `pubspec.yaml` 提取版本号并向各平台打包器提供环境变量的标准化脚本。

