# AuraDSP Linux 打包与分发生态

本目录汇集 AuraDSP 面向 Linux 生态的所有打包与分发模块。
**打包实现已落地（2026-11-06）**：总入口 `pack.sh`，规格见
[03_linux_packaging_spec.md](../docs/03_linux_packaging_spec.md)，
总体设计与选型调研见
[05_installer设计与实施规划-2026-11-06.md](../docs/05_installer设计与实施规划-2026-11-06.md)。

---

## 1. 目标包格式矩阵

| 目录 | 格式 | 产物 | 状态 |
| :--- | :--- | :--- | :--- |
| `deb/` | **Debian/Ubuntu 包 (.deb)** | `dist/auradsp_<ver>_amd64.deb` | ✅ 已实现（正式安装包） |
| `driver/` | **驱动配置包 (.deb)** | `dist/auradsp-driver-loopback_<ver>_all.deb` | ✅ 已实现（snd-aloop 自启配置，03 §6） |
| `appimage/` | **通用 AppImage** | `dist/AuraDSP-v<ver>-x86_64.AppImage` | ✅ 已实现（便携包） |
| `portable/` | **便携压缩包 (.tar.gz)** | `dist/AuraDSP-Linux-x64-v<ver>.tar.gz` | ✅ 已实现（便携包补充形态） |
| `flatpak/` | *Flatpak (预留)* | `dist/org.auradsp.AuraDSP.flatpak` | 清单已备（runtime 25.08，直分发形态；不进首发） |
| `snap/` | *Snap (预留)* | `dist/auradsp_<ver>_amd64.snap` | 清单已备（base core24；不进首发） |

## 2. 用法

```bash
# 一键全量（推荐）：从干净拉取直接产出三件+便携补充形态
# （内部串联：cmake 预设构建引擎/双宿主 → Flutter bundle → sync_artifacts → 打包）
bash installer/linux/pack.sh --build
# 需 cmake/ninja/flutter 与 multilib、libgtk-3-dev 等构建依赖在位（同 CI J2/J8 口径）

# 或分步：bundle 已构建好时直接打包
flutter build linux --release --no-tree-shake-icons   # 在 app/auradsp_app/
python tools/sync_artifacts.py                        # 仓库根
bash installer/linux/pack.sh
# 可选：--bundle DIR / --out DIR / --only deb,driver,appimage,portable
# 版本自动取自 pubspec，经 shared/version_resolver.py 校验格式
```

AppImage 工具链（appimagetool + type2 runtime）在首次构建时按
`appimage/tools.pins` 的版本 + SHA256 下载到 `~/.cache/auradsp-pack-tools/`
并逐个校验，之后离线复用。

## 3. 跨平台音频关键原则
- **动态链接宿主音频后端**：无论使用何种格式，**严禁将 `libpulse.so` 或 `libasound.so` 打包在内**（AppImage 构建脚本带铁律自检，混入即中止）。
- 所有音频输出必须通过宿主机现存的 PulseAudio 套接字或 PipeWire `pipewire-pulse` 套接字进行通信，以确保音量控制、虚拟声卡重定向和声效处理能够实时生效。
- 打包载荷保持 Flutter bundle 原生布局（`usr/lib/auradsp/` 整包），
  并做权限规范化（目录 755 / ELF 755 / 其余 644）——bundle 源文件
  带构建机 umask 权限，不规范化会装出只有 root 能读的目录。

## 4. 本机实物验证记录（2026-11-06，版本 0.1.0）

在本 VM（Ubuntu 24.04）以现行 bundle（引擎/双宿主为当日重编产物）
跑通 `pack.sh` 全量：

- `auradsp_0.1.0_amd64.deb`（14.0 MB）：`dpkg-deb --info/-c` 校验
  通过——control 字段、t64 双写依赖、postinst/postrm、`/usr/bin/auradsp`
  链接、载荷权限（主程序/引擎 755）均正确；
- `auradsp-driver-loopback_0.1.0_all.deb`（2 KB）：配置三件
  （modules-load.d / modprobe.d / 自检脚本 755）在位；
- `AuraDSP-v0.1.0-x86_64.AppImage`（16.4 MB）：`--appimage-extract`
  解出完整 AppDir（AppRun/桌面文件/图标/bundle），工具与 runtime
  的 SHA256 均与钉版表一致；
- `AuraDSP-Linux-x64-v0.1.0.tar.gz`（16.9 MB）：目录结构与包内
  README 在位；
- **运行冒烟**：deb 解包出的主程序在 Xvfb + PulseAudio 下启动并
  存活 10 s 无崩溃，`ldd` 缺失库为 0（日志中的 ATK/托盘警告为
  无桌面会话的裸 X 环境已知现象，与 CI J8 同类）。

已知边界：AppImage 在目标机运行需要 fusermount 助手（type2 runtime
静态化后不再依赖 libfuse2）；`plugin_host_x86` 在无 multilib 的
目标机上不可执行（32 位插件降级，64 位不受影响）。

详细技术规约参见 [03_linux_packaging_spec.md](../docs/03_linux_packaging_spec.md)。
