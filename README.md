# AuraDSP

> 跨平台全局音频效果系统 · Cross-platform Global Audio Effects
> Flutter 统一界面 + AuraDSP Engines 引擎族（DSP 核心 + 平台音频适配驱动）

**AuraDSP** 是一个从零设计的跨平台音效项目：一套 Flutter UI 跑遍 Android / Windows / Linux，一套 DSP 核心适配不同系统的音频链路。Android 路线已验证并落地——以 AIDL effects HAL 形式注入系统音频链路，Enforcing 模式下端到端跑通并通过 root 级模块实现重启持久化。

## 产品结构

```
AuraDSP APP（各平台统一名）
├── AuraDSP UI          —— Flutter 主体框架：多语言 / 多声道 / 可视化
└── AuraDSP Engines     —— DSP 算法核心 + 硬件与系统适配驱动
    ├── (Root)          —— Android KSU/Magisk 模块，AIDL effects HAL 注入，系统级全局 ✅
    ├── (Rootless)      —— Android APK 内置引擎，会话级处理（设计中）
    └── (Desktop)       —— Windows APO/WASAPI · Linux PipeWire（规划中）
```

APP 与引擎通过统一控制协议解耦：Root 场景下 APP 走标准 `android.media.audiofx.AudioEffect` 通道 attach 全局引擎；Rootless 场景进程内 FFI 直调。

## 当前进度

- ✅ **Android（Root）端到端**：libjamesdsp 整合为效果库 → Enforcing 下 SELinux → FMQ → DSP → 扬声器全链路打通，真实音乐听感确认
- ✅ **参数接线**：标准 AIDL 参数（bassBoost / presetReverb / equalizer）→ 引擎参数路由实测通过
- ✅ **持久化**：KSU 模块 `AuraDSP Engines (Root)` v0.4.0 —— 重启后自动恢复挂载链、策略注入与音效，无需任何手动操作
- ⬜ Phase 5（当前）：Flutter 控制端 APP

## 仓库结构

| 目录 | 内容 |
|---|---|
| `core/android/registrar/` | EffectRegistrar 效果库框架（AIDL/FMQ/状态机）+ JamesDSP 引擎适配（examples/jamesdsp_engine） |
| `core/android/registrar/examples/jamesdsp_engine/deploy/` | 设备部署与 KSU 模块打包（`ksu_module/`、`build_ksu_module.sh`） |
| `docs/` | 产品架构总览、工程规范、立项初衷、调研与验证报告（中文） |
| `test/` `tools/` | 设备端测试资产与独立工具 |
| `source/` | 第三方上游只读克隆区（不入库） |

## 文档索引

- [`docs/产品架构总览.md`](docs/产品架构总览.md) — 品牌/产品矩阵/引擎族拆分/UI 规范（产品真相源）
- [`docs/项目架构与开发规范.md`](docs/项目架构与开发规范.md) — 目录约定/分层架构/构建规范（工程真相源）
- [`docs/项目初衷.md`](docs/项目初衷.md) — 立项动机与现有方案痛点实测
- [`docs/M0-Android音频政策专项调研.md`](docs/M0-Android音频政策专项调研.md)、[`docs/Spike2-AIDL效果库验证报告.md`](docs/Spike2-AIDL效果库验证报告.md) — 关键调研与验证

## 构建（Android 引擎侧）

- 工具链：Android NDK 30（clang++ 直调，aarch64-linux-android34）
- 引擎构建：`core/android/registrar/examples/jamesdsp_engine/build_jdsp.sh`（Git Bash）
- KSU 模块打包：`deploy/build_ksu_module.sh` → 安装 `adb push` + `ksud module install`
- 关键约束：C++20（libfmq 依赖）、16KB page 对齐链接、符号白名单三导出（详见工程规范 §5）

## 许可证与致谢

- 引擎核心衍生自 [JamesDSP](https://github.com/james34602/JamesDSPManager)（libjamesdsp），遵循其上游 GPL 系许可证；本项目自有组件（EffectRegistrar 框架、部署套件、文档）同仓发布。
- 第三方参照项目一律在 `source/` 本地克隆（不入库），提取整合以 `ORIGIN.md` 溯源。
