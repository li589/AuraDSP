# source/ 参考项目审理报告

> 版本：v1.0（2026-10-09）
> 范围：`source/` 下全部 10 个第三方参考克隆。依据：各仓库 README/LICENSE/目录结构/体积实测。
> 定位：只读参考区（.gitignore 排除，不入主库）；本报告为 M1 插件宿主 / Phase 6~7 / M5 细化选型提供依据。

---

## 1. 总表

| # | 项目 | 功能一句话 | 平台 | 许可证 | 体积 | 对 AuraDSP 的参考价值 |
|---|---|---|---|---|---|---|
| 1 | **JamesDSPManager** | JamesDSP 引擎上游（Android 变体 + 跨平台 DSP 库） | Android 5–10 | GPL-3 | — | ★★★ 引擎语义真相源（vendor 来源），效果全清单 |
| 2 | **JDSP4Linux** | PipeWire/PulseAudio 系统级 JamesDSP | Linux | GPL-3 | — | ★★★ Phase 7 Linux 形态（filter-chain 接入） |
| 3 | **RootJamesDSP** | Root 系统级 JamesDSP（KSU/Magisk） | Android | GPL-3 | — | ★★ 与我们 Android (Root) 形态直接同源 |
| 4 | **RootlessJamesDSP** | 免 root 系统级（AudioEffect + 前台服务） | Android | GPL-3 | — | ★★★ Phase 6 Rootless 形态蓝本 |
| 5 | **ViPER4Android-FX** | V4A 2.7 Magisk 模块（下载器 + profile 转换 + VDC 合集） | Android 6+ (SELinux enforcing) | 见仓库 | — | ★★ DDC 格式与音频兼容策略 |
| 6 | **ViPERFX_RE** | V4A 逆向重实现（float32、现代库） | Android (NDK/CMake) | 见仓库 | — | ★★ 算法对照（DDC/卷积/float 化先例） |
| 7 | **element** | 模块化 **AU/LV2/VST/VST3/CLAP 插件宿主** + 节点连线 | Win/Linux/macOS | Apache-2.0 | 23M | ★★★ **M1/M6 插件宿主与图视图 UI 的第一参考** |
| 8 | **equalizerAPO64** | Windows 系统级 EQ/APO（**双精度 64bit 引擎 + AVX2/512**） | Windows（含 ARM 原生构建） | GPL-2 系（上游） | **130M** | ★★★ Phase 7b APO：注册/参数序列化/配置解析 |
| 9 | **lsp-plugins**（新） | **多格式插件集**：CLAP/LADSPA/LV2/VST2/VST3/standalone | Linux/FreeBSD/Windows/macOS，aarch64~x586 全矩阵（LGPLv3） | **112M** | ★★★ M5 细化算法对照（bass enhancer/loudness 等）+ 多格式插件构建体系 |
| 10 | **pulseeffects** | PulseAudio/PipeWire 应用级效果链 | Linux | GPL-3 | 32M | ★★ 效果链管理/开关/排序的 UI 心智（EasyEffects 前身） |

## 2. lsp-plugins 专节（本轮新增）

- **格式覆盖是全部参考项目中最广的**（CLAP/LADSPA/LV2/VST2/VST3/standalone），且官方维护 **Windows 构建**——对 M1 插件宿主的对拍测试（宿主 vs 多格式插件）直接可用。
- **平台矩阵**（README 实测）：aarch64/i586/x86_64 在 Linux/Windows 为 F（full）级，armv7 E 级——**CLAP-on-Android 创新路径的算法参考可行性加分**。
- 效果器内容：以其文档为准的代表性插件包括 **bass enhancer / bass loudness / loudness compensator / parametric equalizer / compressor / limiter / gate** 等——正是 M5 细化第二批点名要对照的算法（`bass_enhancer`+`bass_loudness` 组合即"低音两轴"的成熟实现）。
- **问题**：目录结构与常规仓库不同（`src/` 下未见预期插件子目录，源码组织疑似经 Makefile 聚合），**算法源码定位需一轮专门核验**；体积 112M（含 .git 历史）。

## 3. 问题清单（需处理/核实）

| # | 级别 | 问题 | 建议 |
|---|---|---|---|
| P-1 | 中 | **全部 10 个项目都携带嵌套 `.git`**（实测）。铁律对 vendor-src 明确禁嵌套；source/ 虽只约定"不入库"（.gitignore 已排除），但嵌套仓库会诱导误升级/产生大量重复对象 | 统一执行 `rm -rf source/*/.git` 并在 `source/ORIGIN.md` 逐项登记（URL/commit/日期）；或保留 .git 但写入只读约定。**待你拍板** |
| P-2 | 中 | **RootJamesDSP 的 README 与 RootlessJamesDSP 逐字相同**（均为 Rootless 标题与 Play 徽标）——克隆目标可能配错，或上游 README 复用未区分 | 人工核实 `git log` 与远端 URL；若克隆错仓则重克隆 |
| P-3 | 低 | equalizerAPO64（130M）/ lsp-plugins（112M）体积偏大（主因 .git 历史） | 若采纳 P-1 建议剥 .git 后体积将大幅下降；或改浅克隆（`--depth 1`） |
| P-4 | 低 | element 含 `CLAUDE.md`（上游 AI 助手说明文件） | 无害，仅登记 |
| P-5 | 低 | lsp-plugins 源码组织待核验（§2） | 需要 `bass_enhancer` 算法对照时专项定位 |

## 4. 结论

- 参考价值最高的三份：**element**（插件宿主 + 图视图，M1/M6 直接蓝本）、**equalizerAPO64**（Windows APO，Phase 7b）、**RootlessJamesDSP**（Phase 6）。
- lsp-plugins 的加入补齐了 **M5 细化的算法对照源**（LGPLv3，只读参考不链接无许可冲突）。
- 建议动作顺序：先处理 P-2（可能克隆错仓）→ P-1（统一剥 .git + ORIGIN 登记）→ P-3 浅克隆策略。
