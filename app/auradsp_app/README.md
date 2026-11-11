# auradsp_app — AuraDSP 桌面应用（Flutter）

AuraDSP 的用户界面层：效果链与效果卡、插件机架（4 槽 × 5 级插入）、
Liveprog 脚本 IDE、预设与会话记忆、六页体系（三语 i18n：zh / en / ja）。
与引擎之间只有一层 C ABI（`engine/auradsp_engine.h`，经 `lib/engine/`
的 FFI 绑定），平台差异收口在 `lib/platform/`（业务文件零 `Platform.is`，
门禁看守）。

平台状态：Windows 为主力全功能形态；Linux 已功能对等交付（PulseAudio
三模式 + ALSA 专家模式、VST3/CLAP/VST2 插件宿主与 X11 编辑器、托盘 /
XDG 自启 / MPRIS）。工程总纲见仓库根 `AGENT.md` 与 `docs/`。

## 构建与运行

```bash
flutter pub get

# 构建（--no-tree-shake-icons 必须带，否则图标被裁剪）
flutter build windows --release --no-tree-shake-icons
flutter build linux   --release --no-tree-shake-icons

# 开发运行
flutter run -d windows
flutter run -d linux
```

Linux 构建依赖与 CI 同口径（`.github/workflows/ci.yml`）：Flutter
3.47.9、libgtk-3-dev 等桌面依赖、PulseAudio（运行时与门禁）；
引擎 `.so` 与插件宿主产物来自 `core/desktop/linux/out/Release/`，
同步用 `python tools/sync_artifacts.py`（仓库根 `tools/`）。

## 验证

```bash
flutter analyze                                   # 要求零问题
python ../../tools/bin/run_dart_tests.py          # Dart 单测：按文件串行 + 失败重试（勿全量并发）
```

Dart 单测在本目录 `test/`；引擎冒烟在仓库根 `test/runner.py`。

## 结构速览

| 目录 | 职责 |
|---|---|
| `lib/engine/` | C ABI 的 Dart FFI 绑定、音频 isolate、PA/ALSA/WASAPI 后端、桥绑定 |
| `lib/platform/` | 平台单点：`PlatformProfile`、托盘、自启、MPRIS、路径 |
| `lib/core/` | 状态（AppModel）、参数 schema（与引擎参数表单一真源对账）、预设/文档存储 |
| `lib/features/` | 六页功能：链、效果卡、插件、脚本 IDE、设置、可视化 |
| `lib/l10n/` | 三语 arb 源 + 生成产物（`gen/`，勿手改） |
