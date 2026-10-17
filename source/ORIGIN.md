# source/ 参考仓库登记（ORIGIN）

> 统一剥除嵌套 .git（铁律风格：参考区只读快照，禁止就地升级/推送）。
> 更新来源需重新克隆后再次登记。depth/commit 以登记为准。
> 详尽审理分析与算法对照见 `docs/10-架构/source-参考项目审理报告.md` (v2.5)。

| 目录 | origin | HEAD（剥离时） | 许可证 | 实测占用 | 状态 / 备注 |
|---|---|---|---|---|---|
| **JDSP4Linux** | https://github.com/Audio4Linux/JDSP4Linux.git | master@3ea7d73 | GPL-3.0 | 39.2 MB | stripped；Linux PipeWire/Pulse 参考 |
| **JamesDSPManager** | https://github.com/james34602/JamesDSPManager.git | master@5aed6a4 | GPL-3.0 | 21.1 MB | stripped；libjamesdsp 算法真相源（已提取至 `engine/legacy/`，2026-10-16 由 `vendor/libjamesdsp/` 迁入） |
| **RootJamesDSP** | https://github.com/ShadoV90/RootJamesDSP.git | master@58e6b1b | GPL-3.0 | 14.8 MB | stripped；RootlessJamesDSP 的 root fork（含 BUILD_ROOT.md） |
| **RootlessJamesDSP** | https://github.com/timschneeb/RootlessJamesDSP.git | master@60d25ae | GPL-3.0 | 15.0 MB | stripped；Phase 6 Android 免 root 蓝本 |
| **ViPER4Android-FX** | https://github.com/Magisk-Modules-Repo/ViPER4Android-FX.git | master@507b93e | 见仓库 | 3.3 MB | stripped；Magisk 模块结构、sepolicy 与 VDC/IRS 资源 |
| **ViPERFX_RE** | https://github.com/AndroidAudioMods/ViPERFX_RE.git | rewrite-continued@eb65772 | GPL-3.0 | 1.1 MB | stripped；现代 C++20 float32 重写参考 |
| **ViPER4Windows** | https://github.com/likelikeslike/ViPER4Windows.git | main@ccc3f61 | 未见 LICENSE 文件（Copyright ViPER520，仅 Inter 字体 MIT） | 3.1 MB | stripped；v2.0.1，Windows APO 全局注入 + Fluent UI 重写版。子模块位 ViPERDSP 已补齐克隆（main@6fc1f1b，见下行） |
| **ViPERDSP** | https://github.com/likelikeslike/ViPERDSP.git | main@6fc1f1b | **All Rights Reserved（仅限个人使用，禁商用；逆向代码）** | 1.4 MB | stripped；ViPER4Windows 的引擎 submodule 位补齐（ViPER4Windows 钉住 db1c11c，本克隆为其后继 main），23 效果 + 21,278 行 C/C++ |
| **element** | https://github.com/kushview/element.git | main@7a415269 | Apache-2.0 | 6.9 MB | stripped；M1 插件宿主（CLAP/VST3）与 M6 节点图 UI 参考 |
| **equalizerAPO64** | https://github.com/TheFireKahuna/equalizerAPO64.git | main@7156020 | GPL-2.0 / LGPL | 90.3 MB | stripped；Phase 7b Windows APO 蓝本（含 Qt6 预编译 DLL ~70MB） |
| **lsp-plugins** | https://github.com/lsp-plugins/lsp-plugins.git | master@2df6eea0 | LGPL-3.0+ | 560.0 MB | stripped；66 个子模块已全量展开于 modules/，含 release 归档 |
| **pulseeffects** | https://github.com/mikhailnov/pulseeffects.git | master@b9ec88ed | GPL-3.0 | 7.5 MB | stripped；mikhailnov fork，机架式效果链参考（bass_enhancer 实调 Calf） |
| **clap** | https://github.com/free-audio/clap.git | main@a47f6ba (v1.2.10) | MIT | 3.7 MB | stripped；CLAP 标准头文件正典上游。引擎内置 `vendor/plugin-api/clap` 现为 1.2.6（自 lsp-plugins 副本提取），本仓为其可升级来源 |
| **tympan-apo** | https://github.com/penta2himajin/tympan-apo.git | main@e85f7a4 | MIT OR Apache-2.0 | 654 KB | stripped；Rust Windows APO 框架（IUnknown/IClassFactory/IAudioProcessingObject/IAudioSystemEffects v1-v3，SFX/MFX/EFX 类；含 Win11 AEC APO 与 lock-free ring）；Windows APO 模式（sysapo/VAIO）研发参考。含 CLAUDE.md 与 docs/* 研发手记 |
| **virtual-surround-sound** | https://github.com/nnyj/virtual-surround-sound.git | main@b67d037 | GPL-3.0（含 NIRSOFT SoundVolumeView.exe 专有工具，注意） | 410 KB | stripped；C++ APO 转发器（VB-Cable 7.1→HeSuVi binaural→WASAPI 物理设备，~10ms 延迟）；lock-free SPSC ring + 注册表监听设备切换；Windows APO RT 线程转发范式 + COM 聚合陷阱实录参考 |

