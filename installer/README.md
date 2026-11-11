# AuraDSP 发行与安装程序体系 (Installer & Distribution System)

欢迎来到 **AuraDSP (JamesDSP Desktop & Multiplatform)** 的安装与发行工程目录。

本项目目录汇总了 AuraDSP 面向所有支持平台的安装包制作、打包脚本、元数据管理，以及**自主研发的 Windows 安装向导子项目**。所有发行产物均遵循统一的工程标准，最终成果集中输出至根目录下的 `dist/` 目录。

> **当前状态（2026-11-06）**：**发布规范已裁定**（版本号 `vXX.XX.X`、首版 v0.1.0、仅 Win+Linux、只从 `main` 构建、门禁全绿、每平台驱动包+便携包+正式安装包三件齐备，见 `docs/01_distribution_architecture.md` 发布总则）。**双侧均已落地到「拉取即可构建发行包」**：Linux 入口 `linux/pack.sh --build`（一键：引擎→bundle→同步→deb / 驱动配置包 / AppImage / tar.gz）；Windows 入口 `windows/pack.py`（全量可传参，driver/portable/setup 三模式 + 资源自动合并），配自研两段式安装程序（C++ 引导壳 + Flutter 极光向导，见 `docs/02_windows_installer_design.md` 与 `docs/20-执行/Windows安装程序与打包脚本实施设计-2026-11-06.md`），由 `.github/workflows/windows-installer.yml` 在 windows-latest 持续验证编译与打包逻辑。资源包独立版本线（`resources-v*`，从 0.0.1 起）见 01 §2.4。未决外部项：Windows 驱动正式签名（Attestation/EV，现为测试签名，见 05 号规划风险项）。

---

## 1. 目录结构全景

```text
installer/
├── README.md                      # 本文档：发行与安装工程总纲
├── docs/                          # 详细架构与技术设计文档
│   ├── 01_distribution_architecture.md   # 发行架构总纲与跨平台分发规范
│   ├── 02_windows_installer_design.md     # 自研 Windows 安装程序设计方案
│   ├── 03_linux_packaging_spec.md        # Linux (DEB/AppImage/Flatpak/Snap) 打包规格
│   ├── 04_mobile_macos_spec.md           # Android & macOS 打包与签名规范
│   └── 05_installer设计与实施规划-2026-11-06.md  # 子项目总体设计、选型调研与阶段计划
├── shared/                        # 跨平台共享资源与元数据
│   ├── README.md                  # 共享资源说明
│   ├── assets/                    # 图标、横幅、徽标 (.ico, .png, .svg)
│   ├── license/                   # 许可协议文本 (EULA, LICENSE, 三方声明)
│   └── metadata/                  # 应用元数据 (app_info.json, 多语言描述)
├── windows/                       # Windows 发行与打包体系
│   ├── README.md                  # Windows 打包体系说明
│   ├── pack.py                    # Windows 全量可传参打包入口（三模式，见 windows/README.md）
│   ├── tests/                     # pack.py fixture 自测（CI 同跑）
│   ├── portable/                  # 便携版 (Portable Zip) 说明
│   │   └── README.md
│   └── custom_installer/          # 自研安装程序子项目 (AuraDSP Setup Wizard)
│       ├── README.md              # 自研安装程序说明
│       ├── architecture.md        # 安装程序内核、Payload、驱动注册架构详解
│       ├── bootstrapper/          # C++ 引导壳（零第三方依赖，stored-zip 解包 + SHA256 校验）
│       └── wizard/                # Flutter 安装向导 auradsp_setup（极光 UI + 安装引擎）
├── linux/                         # Linux 发行与打包体系
│   ├── README.md                  # Linux 打包说明与运行时矩阵
│   ├── deb/                       # Debian / Ubuntu (.deb) 打包工具与模板
│   │   └── README.md
│   ├── appimage/                  # AppImage 通用单文件免安装包
│   │   └── README.md
│   ├── flatpak/                   # Flatpak (Flathub 商店预留)
│   │   └── README.md
│   └── snap/                      # Snapcraft (Snap 商店预留)
│       └── README.md
├── android/                       # Android 发行套件 (APK / AAB)
│   └── README.md                  # 移动端签名、分包与产物输出规格
└── macos/                         # macOS 发行套件 (.app / DMG)
    └── README.md                  # 桌面端公证、代码签名与 DMG 制作规范
```

---

## 2. 目标发行产物矩阵 (Dist Matrix)

无论在何种平台、执行何种打包任务，**最终生成的发布包全部统一归集到根目录下的 `dist/` 目录**。

| 目标平台 | 产物形态 | 文件命名范式 | 特性与适用场景 |
| :--- | :--- | :--- | :--- |
| **Windows x64** | **绿色便携版** | `dist/AuraDSP-Windows-x64-v<ver>.zip` | 解压即用，不写注册表，配置与声学资源就地保存 |
| **Windows x64** | **自研安装版** | `dist/AuraDSP-Setup-x64-v<ver>.exe` | 自主设计现代 UI、自动注册 ASIO/VAIO 驱动桥、快捷方式、控制面板卸载 |
| **Linux x64** | **DEB 安装包** | `dist/auradsp_<ver>_amd64.deb` | 面向 Debian/Ubuntu/Mint/Deepin 等 APT 系发行版，集成系统图标与菜单 |
| **Linux x64** | **AppImage** | `dist/AuraDSP-v<ver>-x86_64.AppImage` | 通用独立单文件运行包，针对 PipeWire/PulseAudio 解耦优化，跨主流发行版免安装 |
| **Linux x64** | *Flatpak (预留)* | `dist/org.auradsp.AuraDSP.flatpak` | 沙盒化现代应用分发，Flathub 官方上架标准 |
| **Linux x64** | *Snap (预留)* | `dist/auradsp_<ver>_amd64.snap` | Canonical Ubuntu 软件商店集成分发 |
| **Android** | **Release APK** | `dist/AuraDSP-v<ver>-android-universal.apk` | 手机与车载系统侧载安装包 (也可按 ABI 切分 arm64-v8a) |
| **Android** | **App Bundle** | `dist/AuraDSP-v<ver>.aab` | Google Play 官方分发包 |
| **macOS** | **DMG 镜像** | `dist/AuraDSP-v<ver>-macOS.dmg` | 包含已签名公证的 `AuraDSP.app` 与 `/Applications` 软链接 |

---

## 3. 设计原则与工程纪律

1. **源产物独立性 (Decoupled Build)**：
   - 打包体系本身不承担复杂的 C++ 编译或 Flutter 核心业务代码编译。
   - 打包流水线严格依赖于前置阶段已生成的编译产物（例如 `core/.../out/Release` 与 `app/.../build/...` 阶段的二进制），打包工具只负责**搬运、校验、封装、压缩、生成元数据和建立安装壳**。
2. **零环境污染 (No System Pollution)**：
   - 打包脚本不修改主机全局状态。
   - Linux AppImage 严防把主机独占的显卡或底层音频驱动 `.so` 强行打包进去；Windows 便携版严禁在目标机器上留下残留注册表。
3. **单向产物汇聚 (Unified Dist)**：
   - 所有中间打包临时文件放入各平台目录下的 `.tmp/` 或 `build/` 中并被 `.gitignore` 排除。
   - 唯有经过哈希校验的最终发布文件才被拷贝或移动到 `dist/`。
4. **统一命名与版本真相源 (Single Version Source)**：
   - 应用版本号统一从 `app/auradsp_app/pubspec.yaml`（或统一的 version 配置文件）动态解析提取，杜绝各平台打包脚本内硬编码版本号导致的分歧。

---

## 4. 详细技术方案导航

深入了解各个技术环节的架构设计与实现细则，请参阅 `docs/` 目录：
- [01. 全平台发行架构与产物规范](docs/01_distribution_architecture.md)
- [02. 自研 Windows 安装程序设计方案](docs/02_windows_installer_design.md)
- [03. Linux (DEB / AppImage / Flatpak / Snap) 规格方案](docs/03_linux_packaging_spec.md)
- [04. Android 与 macOS 发行与签名规格方案](docs/04_mobile_macos_spec.md)
- [05. installer 子项目设计与实施规划](docs/05_installer设计与实施规划-2026-11-06.md)

