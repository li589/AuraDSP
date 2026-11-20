# AuraDSP Linux 打包与分发生态

本目录汇集 AuraDSP 面向 Linux 生态的所有打包与分发模块与静态资源。

**实现位置（2026-11-20 起）**：打包逻辑已收进
[`../packkit/linux/`](../packkit/linux/)，与 Windows 侧共用同一个
`packkit` 内核（版本、命名、哈希、资源档位、默认层、交付归集）。

| 文件 | 角色 |
| :--- | :--- |
| `pack.sh` | **转发壳**：把命令行原样交给 `pack.py`。老命令 `bash installer/linux/pack.sh --build` 不变 |
| `pack.py` | **薄壳**：注入 `sys.path` 后转发 `packkit.linux.cli.main` |
| `shared/` `appimage/` `portable/` | 静态资源（desktop 文件、AppRun、工具钉版表、便携包 README） |
| `deb/` `driver/` `appimage/` `portable/` | 各自的 README（说明「这个包为什么长这样」） |
| `flatpak/` `snap/` | 预留清单，不产出商店包 |

规格见 [03_linux_packaging_spec.md](../docs/03_linux_packaging_spec.md)，
分层与收编决策见
[07_打包工具链分层与发布编排](../docs/07_打包工具链分层与发布编排-2026-11-20.md) §7，
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
#       --resources core|full|light|addons|none / --what-if / --version vXX.XX.X
# 版本自动取自 pubspec，经 shared/version_resolver.py 校验格式
```

**一次只能一个资源档位**：产物名不含档位后缀（03 §5），`light` 与 `full`
会产出同名文件。要出两档请分两次发布。

发布编排（推荐用于正式发行）：

```bash
python installer/release.py --platform linux --plan          # 只读门禁表
python installer/release.py --platform linux --round 60     # 四件 + deliver-r60
python installer/release.py --platform linux --resources-tiers core   # 轻档
```

AppImage 工具链（appimagetool + type2 runtime）在首次构建时按
`appimage/tools.pins` 的版本 + SHA256 下载到 `~/.cache/auradsp-pack-tools/`
并逐个校验，之后离线复用。

## 3. 跨平台音频关键原则
- **动态链接宿主音频后端**：无论使用何种格式，**严禁将 `libpulse.so` 或 `libasound.so` 打包在内**（`packkit/linux/appimage.py` 的 `check_no_host_audio_libs` 带铁律自检，混入即中止）。
- 所有音频输出必须通过宿主机现存的 PulseAudio 套接字或 PipeWire `pipewire-pulse` 套接字进行通信，以确保音量控制、虚拟声卡重定向和声效处理能够实时生效。
- 打包载荷保持 Flutter bundle 原生布局（`usr/lib/auradsp/` 整包），
  并做权限规范化（目录 755 / ELF 755 / 其余 644）——bundle 源文件
  带构建机 umask 权限，不规范化会装出只有 root 能读的目录。

  规范化由 `packkit/linux/perms.py` 按 **ELF magic** 判定，不调 `file`
  命令：2026-11-20 实测，最小化 WSL/容器缺 `file` 时旧实现会把全部二进制
  chmod 644 且**退出码仍为 0**——等于发出一个装完点不开的包。但
  `appimagetool` 自身仍依赖 `file`，故 AppImage 预检会显式检查它。

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

## 5. 收编后复验记录（2026-11-20，Debian WSL / dpkg 1.22）

用 `/bin/true` 充当载荷的合成 bundle（免去 Flutter 构建）跑通全链路：

- **新旧对拍**：`auradsp_0.1.0_amd64.deb` 61 条目、驱动 deb 15 条目、
  tar 22 条目，**内容与权限逐条一致**；`control`/`postinst`/`postrm`
  正文逐字一致。
- **权限**：主程序与引擎/双宿主均为 `-rwxr-xr-x`，文本 `-rw-r--r--`，
  `/usr/bin/auradsp` 保持符号链接。
- **AppImage**：按 pins 下载的 appimagetool 1.9.1 与 type2-runtime
  20251108 哈希均与钉版表一致；产物 997,880 B，可 `--appimage-extract`
  解出 `AppRun/auradsp.desktop/auradsp.png/usr`，无 `libpulse*`/`libasound*`。
- **发布编排**：`release.py --platform linux --round 1` 产出四件到
  `deliver-r1/`，`sha256sum -c SHA256SUMS-r1.txt` 四行全 OK；
  多档位请求被正确拒绝（退出码 1）。

本次未覆盖：真 Flutter bundle 的完整体积（合成载荷仅 43 KB）、
`--build` 链路（WSL 内 flutter 解析到 Windows 版，rc=127 已按警告降级）、
以及 flatpak/snap 的实际产出（仍是预留）。

详细技术规约参见 [03_linux_packaging_spec.md](../docs/03_linux_packaging_spec.md)。
