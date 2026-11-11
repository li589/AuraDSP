# Linux DEB 打包方案与规范 (Debian / Ubuntu / Mint)

本模块负责从 Linux Staging 目录（`dist/AuraDSP-Linux-x64/`）生成符合 Debian 文件系统层级标准（FHS）的标准 `.deb` 安装包。

---

## 1. 结构与文件映射

`.deb` 安装后，各文件的实际安装位置如下：

- `/usr/bin/auradsp`：启动器脚本（链接到实际二进制）
- `/usr/lib/auradsp/`：
  - `auradsp_app`（主程序）
  - `libauradsp_engine.so`（C++ 音频核心引擎）
  - `plugin_host_x64`（插件隔离宿主）
  - `data/`（Flutter 资源、着色器、字体）
  - `resources/`（DDC 耳机校准曲线、卷积脉冲、Liveprog 脚本）
- `/usr/share/applications/auradsp.desktop`：XDG 桌面启动入口
- `/usr/share/icons/hicolor/256x256/apps/auradsp.png`：系统图标

---

## 2. 关键依赖声明 (`DEBIAN/control`)

- 依赖库：`libc6 (>= 2.35)`, `libgtk-3-0 (>= 3.24)`, `libstdc++6 (>= 11)`, `libpulse0 | libpipewire-0.3-0`, `libasound2`
- 推荐安装：`pulseaudio | pipewire-pulse`

---

## 3. 构建（已实现）

实现：`build_deb.sh`（由 `../pack.sh` 调用，版本经
`installer/shared/version_resolver.py` 从 `pubspec.yaml` 注入）：
1. 校验 bundle 完整性（主程序 + 引擎 .so 在位）。
2. 临时 staging 按 FHS 填充：bundle 原样进 `/usr/lib/auradsp/`
   （保持 runner 要求的相对布局，引擎/宿主在 `lib/` 子目录内）、
   `/usr/bin/auradsp` 符号链接、桌面入口与全尺寸图标、doc 文档。
3. 生成 `DEBIAN/control`（依赖含 24.04 的 `libgtk-3-0t64 | libgtk-3-0`
   与 `libasound2t64 | libasound2` 双写）、`postinst`/`postrm`。
4. `dpkg-deb --build --root-owner-group` 产出
   `dist/auradsp_<ver>_amd64.deb`。

