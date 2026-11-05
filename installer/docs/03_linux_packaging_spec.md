# Linux (DEB / AppImage / Flatpak / Snap) 打包规格方案

本文档详细定义了 AuraDSP (JamesDSP Desktop) 面向 Linux 平台的发布包规范。涵盖面向主流发行版的 **DEB 包**、面向通用便携环境的 **AppImage**，以及面向应用商店沙盒生态的 **Flatpak** 与 **Snap** 架构预留。

---

## 1. Linux 音频子系统与兼容性基线 (Audio Subsystem Matrix)

AuraDSP 是核心音频效果器应用，与 Linux 底层音频架构（PulseAudio 与 PipeWire）有着极其紧密的集成。在打包时必须遵循以下铁律：

| 发行版生态 | 音频默认后端 | 通信协议/接口 | 打包依赖处理策略 |
| :--- | :--- | :--- | :--- |
| **Ubuntu 20.04 / 22.04 LTS** | PulseAudio | `libpulse.so.0` | 依赖系统 `libpulse0`，不得打包私有 PulseAudio 服务 |
| **Ubuntu 24.04+ / Fedora 38+ / Arch** | PipeWire | `pipewire-pulse` 兼容套接字 | 依然通过 `libpulse.so.0` 协议与 PipeWire 通信，无需改动源码 |
| **纯 ALSA / 嵌入式 Linux** | ALSA | `libasound.so.2` | 备用后端，通过系统 `libasound2` 提供 |

### 核心规避坑点 (Critical Audio Pitfalls)
1. **严禁在 AppImage 中捆绑 `libpulse.so.0` / `libasound.so.2`**：
   若将构建环境中的 `libpulse.so.0` 打包进 AppImage，会导致应用在宿主机上无法与宿主机真正的 PulseAudio / PipeWire 守护进程套接字（UNIX Domain Socket: `$XDG_RUNTIME_DIR/pulse/native`）握手，引发声卡初始化静默失败或爆音。
   **规则：AppImage 必须将 `libpulse.so` 和 `libasound.so` 列入白名单排除列表，强制动态链接宿主机底层库**。
2. **GLIBC 兼容性基线**：
   Linux 动态链接器（`ld-linux`）具有向下兼容、向上不兼容的特性。
   **规约：官方 Linux CI 构建必须在 Ubuntu 22.04 LTS (glibc 2.35) 环境下进行**，确保打包出来的 AppImage 与 DEB 能够在几乎所有现代主流 Linux 发行版（Ubuntu 22.04/24.04, Debian 12, Fedora 38+, Arch, openSUSE）上开箱即跑。

---

## 2. Debian / Ubuntu 软件包 (`.deb`) 规格

`.deb` 包用于适配所有 Debian 系生态系统（Debian, Ubuntu, Linux Mint, Pop!_OS, Deepin, Kylin 等）。

### 2.1 文件系统层级规范 (FHS Layout)
```text
auradsp_0.1.0-1_amd64/
├── DEBIAN/
│   ├── control                     # 包元数据与 APT 依赖
│   ├── postinst                    # 安装后脚本 (更新 desktop/icon 缓存)
│   └── postrm                      # 卸载后脚本 (清理图标缓存)
└── usr/
    ├── bin/
    │   └── auradsp                 # 符号链接或包装脚本 -> /usr/lib/auradsp/auradsp_app
    ├── lib/
    │   └── auradsp/                # 核心二进制与资产目录
    │       ├── auradsp_app         # Flutter Linux 主程序
    │       ├── libauradsp_engine.so# C++ 核心 DSP 引擎
    │       ├── plugin_host_x64     # 64位 VST/CLAP 进程外隔离宿主
    │       ├── data/               # Flutter Dart 内核镜像与着色器
    │       └── resources/          # 核心声学 DDC/卷积资源
    └── share/
        ├── applications/
        │   └── auradsp.desktop     # 桌面启动菜单入口
        ├── icons/
        │   └── hicolor/
        │       ├── 256x256/apps/auradsp.png
        │       └── scalable/apps/auradsp.svg
        └── doc/
            └── auradsp/
                ├── copyright
                └── changelog.Debian.gz
```

### 2.2 `DEBIAN/control` 规范示例
```ini
Package: auradsp
Version: 0.1.0-1
Section: sound
Priority: optional
Architecture: amd64
Maintainer: AuraDSP Team <support@auradsp.org>
Depends: libc6 (>= 2.35),
         libgtk-3-0 (>= 3.24),
         libstdc++6 (>= 11),
         libpulse0 | libpipewire-0.3-0,
         libasound2 (>= 1.2.0)
Recommends: pulseaudio | pipewire-pulse
Description: Advanced Audio DSP & Effect Suite for Desktop
 AuraDSP provides studio-grade parametric equalizer, dynamic range compression,
 spatial reverberation, DDC headphone correction, and VST/CLAP plugin hosting.
```

---

## 3. 通用免安装独立包 (`.AppImage`) 规格

AppImage 是 Linux 上唯一一种“下载即双击运行”的零依赖格式。

### 3.1 AppDir 结构
```text
AuraDSP.AppDir/
├── AppRun                          # 启动入口包装脚本 (设置 LD_LIBRARY_PATH, XDG 路径)
├── auradsp.desktop                 # 桌面元数据
├── auradsp.png                     # 应用图标
└── usr/
    ├── bin/
    │   ├── auradsp_app
    │   └── plugin_host_x64
    ├── lib/
    │   ├── libauradsp_engine.so
    │   ├── libflutter_linux_gtk.so
    │   └── ... (打包必要的第三方依赖，排除 glibc/pulse/mesa)
    └── share/
        └── auradsp/
            ├── data/
            └── resources/
```

### 3.2 `AppRun` 关键设计
```bash
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS}"

# 启动 AuraDSP，保留所有传入命令行参数
exec "${HERE}/usr/bin/auradsp_app" "$@"
```

### 3.3 运行时技术选型 (Type 2 Runtime)
使用具备静态链接运行时特性的最新版 `appimagetool` 或 `go-appimagetool`，**彻底解决 Ubuntu 24.04 及更新发行版因移除 `libfuse2` 导致旧式 AppImage 无法启动的问题**。

---

## 4. 应用商店预留：Flatpak 与 Snap 规范

为了未来在 Flathub 和 Canonical Snap Store 上架，提前设立预留规范：

### 4.1 Flatpak 规格 (`installer/linux/flatpak/`)
- **应用 ID**：`org.auradsp.AuraDSP`
- **运行时环境**：`org.freedesktop.Platform // 23.08`
- **沙盒权限配置 (`finish-args`)**：
  ```yaml
  finish-args:
    - --share=ipc
    - --socket=x11
    - --socket=wayland
    - --socket=pulseaudio           # 授予音频录制/播放套接字权限 (自动映射 PipeWire)
    - --filesystem=home:ro          # 允许读取用户目录下的声学脉冲 (.irs) 和预设文件
    - --filesystem=xdg-run/pipewire-0 # 兼容直接 PipeWire 原生探测
  ```

### 4.2 Snap 规格 (`installer/linux/snap/`)
- **应用名称**：`auradsp`
- **基础镜像**：`core22`
- **权限插槽 (Plugs)**：
  ```yaml
  plugs:
    - audio-playback               # 音频输出权限
    - audio-record                 # 音频输入/监测权限
    - pulseaudio                   # PulseAudio/PipeWire 连接
    - desktop                      # 桌面环境支持
    - wayland
    - x11
    - home                         # 访问用户主目录声学文件
  ```

---

## 5. 打包自动化产物落地
打包入口：`installer/linux/pack.sh`（读取 `installer/shared/version_resolver.py`
导出的版本号；输入为 Flutter Linux bundle + 引擎产物，见 `installer/linux/README.md`）。
所有打包产物统一输出到根目录 `dist/`：
- `dist/auradsp_0.1.0_amd64.deb`（正式安装包）
- `dist/auradsp-driver-loopback_0.1.0_all.deb`（驱动包，见 §6）
- `dist/AuraDSP-v0.1.0-x86_64.AppImage`（便携包）
- `dist/AuraDSP-Linux-x64-v0.1.0.tar.gz`（便携包补充形态）
- `dist/org.auradsp.AuraDSP.flatpak` (预留，manifest 已备)
- `dist/auradsp_0.1.0_amd64.snap` (预留，snapcraft.yaml 已备)

---

## 6. Linux 驱动包：`auradsp-driver-loopback`（snd-aloop 配置包）

Linux 无自研内核驱动；AuraDSP 的「驱动模式」依赖内核自带模块 **snd-aloop**
（回环声卡 `hw:Loopback`）。驱动包的职责是把该模块的自启与参数固化下来，
使驱动模式开箱可用，与 01 §2.3 的「每平台驱动包」构成对齐。

```text
auradsp-driver-loopback/
├── etc/
│   ├── modules-load.d/auradsp-loopback.conf   # 内容：snd-aloop（开机自启）
│   └── modprobe.d/auradsp-loopback.conf       # options snd-aloop enable=1（参数固化）
└── usr/
    └── lib/auradsp-driver-loopback/
        └── auradsp-loopback-check             # 自检脚本：模块在位/声卡可见性报告
```

- 架构 `all`（纯配置，无二进制）；与主包无硬依赖，可独立安装/卸载。
- `postinst` 尽力即时加载一次（`modprobe snd-aloop`，失败不中断安装——
  如容器/无权限环境，配置仍会在下次开机生效）。
- 卸载（`postrm`）只移除配置，不强制卸载正在使用的模块。
- 实现：`installer/linux/driver/`，由 `pack.sh` 一并构建。

