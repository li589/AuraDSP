# AuraDSP Windows 自研安装程序子项目 (Custom Setup Wizard)

本子项目为 AuraDSP 专门自主研发的现代安装程序向导。

## 1. 目标与定位

不同于通用的第三方 NSIS 或 Inno Setup 脚本，本项目是一个**原生的、具备专业音频领域针对性能力的桌面子工程**：
1. **视觉一致性**：完全继承 AuraDSP 主应用的界面设计语言（深色/浅色主题、极光光效、CJK 字体排版、动效与圆角风格）。
2. **深度音频配置自动化**：
   - 安装时自动以静默方式完成 `auraasio_bridge.dll` 的 COM 注册（`regsvr32 /s` 或直接调用 `DllRegisterServer`）。
   - 自动准备 AuraVAIO 虚拟声卡通信环境。
   - 检测系统中正在运行的 `auradsp_app.exe` 或宿主 DAW 进程，给出友好关闭提示。
3. **安全透明的生命周期管理**：
   - 支持普通权限（Per-User）免 UAC 快速安装与管理员系统级（All-Users）安装双模式。
   - 写入标准的 Windows 控制面板注册表项，支持一键卸载（`uninstall.exe`）。
   - 卸载时保护用户自定义的声学预设与私有卷积库，防止误删用户资产。

---

## 2. 目录规划

实施规格（2026-11-06 定稿）：`docs/20-执行/Windows安装程序与打包脚本实施设计-2026-11-06.md`。
架构为两段式——C++ 引导壳解出 Flutter 向导运行时，向导承载全部 UI 与安装引擎；
打包入口为 `installer/windows/pack.py`（全量可传参）。

```text
custom_installer/
├── README.md                      # 本文档
├── architecture.md                # 架构设计与底层实现细节（概念层）
├── bootstrapper/                  # C++ 引导壳（单文件 + vendored miniz + CMake）
└── wizard/                        # Flutter 安装向导工程（auradsp_setup）
```

---

## 3. 技术设计概要

详见 [architecture.md](architecture.md) 与实施设计（`docs/20-执行/Windows安装程序与打包脚本实施设计-2026-11-06.md`）。
最终输出目标文件：`dist/AuraDSP-Setup-x64-v<VERSION>.exe`。

