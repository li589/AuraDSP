# ADR-013 — VST2 支持与净室头文件合规

> **状态**：已接受（2026-11-03，owner 裁定）
> **关联**：[插件双宿主架构与跨格式扩展方案-2026-11-02](../10-架构/插件双宿主架构与跨格式扩展方案-2026-11-02.md) ·
> [VST2 插件适配实施计划-2026-11-03](../20-执行/VST2插件适配实施计划-2026-11-03.md) ·
> [source-参考项目审理报告](../10-架构/source-参考项目审理报告.md) §2.11

---

## 背景

1. Windows 存在大量只有 VST2 版本的历史效果器，其中 32 位存量尤其多；AuraDSP 当前只支持 VST3 / CLAP。
2. Steinberg 已于 2018 年终止 VST2 授权，官方 `aeffect.h` / `aeffectx.h` 不得随项目分发。
3. 仓库内 `vendor/plugin-api/steinberg/vst2.h` 的注释与官方 `aeffect.h` 逐字相同（仅版权头被替换为 LSP 的 ISC 声明），**不是净室重建**，存在许可瑕疵，且当前无任何代码引用。
4. 32 位位桥宿主 `plugin_host_x86` 与 64 位宿主路由已于 2026-11-02 全链跑通，具备承载 32 位 VST2 的基础设施。

## 决策

### D-1 编译头

- 以 `source/vst2sdk/vst2sdk/include/vst.h`（Xaymar，BSD-3-Clause）为**唯一编译源**，收编至 `vendor/plugin-api/vst2/vst.h`，`LICENSE` 随附；
- **删除** `vendor/plugin-api/steinberg/vst2.h`、`vst2main.h`、`vst2_keytable.h`，消除误用与许可风险；
- Steinberg 官方 2.4 归档继续只读隔离在 `source/vst2sdk/vstsdk2.4/`，仅作 Dispatcher 语义与对齐排错参考，**不进 `vendor/`、不进 git、不进 Release**；
- 禁止在 `engine/` 内另行定义 VST2 结构体；需要熟悉命名时用 `using` 别名映射，结构体布局只认 `vst.h`。

### D-1a 32 位回调 ABI

Xaymar 的 `vst_host_callback_t` 把 `p_int2` 声明为 `int64_t`，而 VST2 的 `VstIntPtr` 在 32 位下是 4 字节。宿主侧必须自定义回调：

```c
static intptr_t VST_FUNCTION_INTERFACE hostCallback(
    vst_effect_t* effect, int32_t opcode, int32_t index,
    intptr_t value, void* ptr, float opt);
```

传给 `VSTPluginMain` 时再转换为 `vst_host_callback_t`。直接照抄 `vst_host_callback_t` 实现会在 32 位插件调用时造成参数错位。

### D-2 宿主路由

- 64 位 VST2：默认**进程内**加载；`AURA_PLUGIN_HOST_MODE=process` 时转 `plugin_host_x64`；
- 32 位 VST2：**强制**经 `plugin_host_x86` 位桥（x64 进程无法 `LoadLibrary` 32 位 DLL）。

### D-3 扫描

- VST2 无 bundle，`.dll` 需先用 PE 导出表判定（`VSTPluginMain` 或 `main`），不加载非插件 DLL；
- **64 位 VST2 在引擎进程内只做 PE 快扫**：实测真实插件（Blue Cat PatchWork / FabFilter）在 `VSTPluginMain`/`effOpen` 阶段会直接 `0xC0000005`，扫描期 `LoadLibrary` 未知厂商 VST2 不可接受。真实元数据由加载路补齐；
- 32 位深扫经 IPC `Op::QueryMetadata` 由 x86 宿主临时加载查询，失败回退快扫元数据；进程外模式（整轮扫描在 `plugin_host_x64` 内）允许 64 位深扫、崩溃只杀宿主，但宿主没有 x86 桥，32 位条目在该模式下退化为快扫元数据（加载/音频/界面/预设不受影响）。

### D-4 平台范围

本期**仅 Windows**注册 VST2 驱动；Linux 继续只支持 VST3 / CLAP。`PluginFormat::VST2` 枚举全平台可见，序列化字符串固定为 `VST2`。

### D-5 预设

写 `AUR2` 自描述头 + 原始 chunk；读兼容 `AUR2` 与标准 `.fxp`（`CcnK`）。无 chunk 插件退化为参数数组。

### D-6 分支

owner 裁定：VST2 改动随 `feature/linux` 一并合入 `dev`，不另切 `feature/vst2`。这是对 ADR-012 分支策略的一次显式例外，理由是 Linux 分支本就要合 `dev`，无需为 Windows 专属改动单独建分支。

## 后果

- **正面**：VST2 64/32 位可扫描、可挂载、可出声、可开界面、可存取预设；编译依赖为 BSD-3-Clause 净室头，合规风险闭环。
- **负面**：VST2 无参数模型，UI 不暴露插件参数自动化；64 位 VST2 列表初期只有 PE 快扫信息（真实名称/厂商在挂载后补齐）；32 位深扫依赖 IPC，首次扫描比 64 位慢；`vst.h` 的命名与官方 SDK 不同，阅读代码需对照别名。
- **回退**：移除 VST2 驱动注册与 UI 药丸即可关闭；`PluginFormat::VST2` 枚举可保留。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| 继续使用 `vendor/plugin-api/steinberg/vst2.h` | 注释与官方头逐字相同，非净室；许可声明不可信 |
| 引入 Xaymar 头但保留 LSP 头作对照 | 两套 ABI 定义并存，必然漂移；对照应放在 `source/` |
| 32 位只做快扫元数据 | owner 要求本期补齐真实名称/厂商，IPC 复用 `RemotePluginInfo` 成本可控 |
| 64 位 VST2 默认进程外 | 与 VST3/CLAP 默认策略不一致，增加共享内存环延迟 |
