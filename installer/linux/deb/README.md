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

## 3. 构建步骤规划
打包工具将自动化执行：
1. 校验 Staging 目录完整性。
2. 建立临时 `pkg_root/` 目录并依照 FHS 目录结构填充文件。
3. 动态从 `pubspec.yaml` 生成 `DEBIAN/control`、`postinst`、`postrm` 脚本。
4. 调用系统命令 `dpkg-deb --build --root-owner-group pkg_root dist/auradsp_<ver>_amd64.deb` 生成最终发布包。

