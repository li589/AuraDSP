# AuraDSP Linux 打包与分发生态

本目录汇集 AuraDSP 面向 Linux 生态的所有打包与分发模块。

---

## 1. 目标包格式矩阵

AuraDSP 在 Linux 平台采取“**原生 APT + 通用免安装 + 应用商店预留**”的三层覆盖策略：

| 目录 | 格式 | 产物目标路径 | 适用场景 |
| :--- | :--- | :--- | :--- |
| `deb/` | **Debian/Ubuntu 包 (.deb)** | `dist/auradsp_<ver>_amd64.deb` | APT 生态（Ubuntu, Debian, Mint, Deepin）深度系统集成 |
| `appimage/` | **通用 AppImage** | `dist/AuraDSP-v<ver>-x86_64.AppImage` | 任何 64 位 Linux 发行版，免安装即双击运行 |
| `flatpak/` | *Flatpak (Flathub 预留)* | `dist/org.auradsp.AuraDSP.flatpak` | 现代化沙盒分发，面向 Steam Deck, Fedora, Flathub |
| `snap/` | *Snap (Ubuntu 商店预留)* | `dist/auradsp_<ver>_amd64.snap` | Canonical Ubuntu 软件中心直接安装 |

---

## 2. 跨平台音频关键原则
- **动态链接宿主音频后端**：无论使用何种格式，**严禁将 `libpulse.so` 或 `libasound.so` 打包在沙盒内部**。
- 所有音频输出必须通过宿主机现存的 PulseAudio 套接字或 PipeWire `pipewire-pulse` 套接字进行通信，以确保音量控制、虚拟声卡重定向和声效处理能够实时生效。

详细技术规约参见 [03_linux_packaging_spec.md](file:///d:/temp_desktop/Proj/JamesDSP/installer/docs/03_linux_packaging_spec.md)。

