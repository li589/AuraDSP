# tools/ — 开发辅助工具与小组件

> **职责边界（铁律）**：
> - `tools/` = 开发调试辅助工具、生成器、诊断探针、一次性取证脚本；
> - `test/` = 全量测试套件（`test/smoke/` 引擎烟囱、`test/ui/` 置顶 UI 自动化、`test/data/` 测试数据）。
>
> **二者的判据**：有断言、能无人值守跑完、用于回归门禁 → 进 `test/` 并**必须登记 `test/runner.py`**；
> 只做观测/取证/生成、需要人工参与 → 留 `tools/`。
>
> **目录**：`bin/` 可重复运行的工程工具；`probe/` 一次性诊断探针（用完即归档）；
> `calibration/`、`resource_pipeline/` 主题工具；`windows/` Windows-only 构建/同步/远程入口
> （根级同名文件是薄转发，原命令行不变）；`archive/` 过程产物（gitignored）。

---

## 1. 构建与工程（`bin/`）

| 工具 | 用途 |
|---|---|
| `bin/run_tests.py` | 统一测试执行入口桥接（转发 `test/runner.py`） |
| `bin/push_via_api.py` | GitHub REST API 离线/受限网络推送兜底（自行组装 blob/tree/commit，sha 逐字一致） |
| `bin/verify_dll_copies.py` | DLL 三处同哈希单向校验（仅校验；**分发**已改由 `sync_artifacts.ps1` 负责） |
| `windows/sync_artifacts.ps1` | 增量产物一次性同步：把引擎 DLL / 宿主 EXE / 三个桥从真相源覆盖分发到 `test/`、`app build runner`、`dist` 三处；端点缺失或单文件覆盖失败仅告警并跳过（替代手工 cp；`-WhatIf` 预演、`-PackZip` 重打包发行 zip） |
| `windows/build_windows.ps1` | Windows 全栈构建/产物整理/资源打包流水线（根 CMake preset → 引擎/桥/Flutter → dist；根级 `tools/build_windows.ps1` 薄转发，命令不变） |
| `windows/remote_win10.ps1` | Win10 虚拟机远程命令（ssh 封装；根级同名薄转发） |
| `windows/*.bat` | 增量引擎构建与两组 smoke 快捷批处理（根级同名薄转发；内容仍为历史硬编码入口） |
| `bin/abi_consistency.py` | .def/engine.h/ffi.dart 45 符号一致性（`smoke_abi_consistency.py` 调它） |
| `bin/dart_swallow_scan.py` | Dart 静默异常门禁（D4-b）：R1 空 catch 块必留痕或标记 / R2 循环体包壳必 `swallowThrottled` / R3 禁 `catch (_)` 丢弃异常 / R4 标记理由不得敷衍。词法级剥离注释与字符串，注释里的 `catch (_)` 不误判（`smoke_d4b_swallow.py` 调它，`--json` 可机器读） |
| `bin/patch_id_scan.py` | 补丁编号门禁（D6/§7-4）：每个 `PATCHED-AuraDSP` 标记必须紧跟已登记的 `P-NNN`（编号写在说明文字里、日期在编号前都判红——这两种按行 grep 都看着"有编号"）；同一专项代号别名不得映射到两个编号；登记表不得重复编号（`smoke_d6_patch_ids.py` 调它） |
| `bin/rebuild_plugin_cache.py` | 用引擎真实扫描结果重建 `%APPDATA%\AuraDSP\plugins\plugin_cache.json` |
| `bin/fix_docs_links.py` | docs 搬迁后改链（P0 沉淀，可复用） |
| `bin/scan_engine_strings.py` | 引擎内置字符串/预设数值扫描器（参数表/默认值/混响/kLat/字面量分类，缓存产 `tools/archive/_scan_cache.json`） |
| `bin/gen_report.py` | 由扫描缓存生成《引擎内置字符串与预设数值扫描汇报》（头部带 git 锚点；报告已存在须 `--force` 才覆写） |

## 2. 引擎诊断探针（`probe/`，C++ / ctypes，只读不改引擎）

| 工具 | 用途 |
|---|---|
| `probe/bench_effects.py` | 各 DSP 算法每块处理耗时 + `eq.curve` 重建耗时基准 |
| `probe/perf_probe.py` | RT 路径分段计时，多次重复取最小值压低调度噪声 |
| `probe/fft_probe.cpp` | FFT 输出布局轻量 C++ 探针 |
| `probe/emit_probe.cpp` | emit 采样时机轻量 C++ 探针 |
| `probe/probe_latency.py` | 组件延迟实测输出（需外部资源的 convolver/ddc/liveprog 如实返回不可测） |
| `probe/probe_concurrent.py` | 验证两个 `auradsp` handle 能否安全共存（延迟探测方案的前提） |
| `probe/gen_test_irs.py` | 生成各规格测试脉冲响应（IR）文件 |
| `probe/scan_external.py` | 只读扫描外部插件目录（如 `D:\myPrograms\AudioEffect`）并入缓存 |

## 3. UI 取证探针（`probe/`，需人工参与，不是测试）

> 这一族的诞生背景一致：**UI 自动化里最费时间的是「点了没反应」**。
> 硬编码坐标失效时脚本不报错，只是点落在空白处、断言拿到 0 像素差异。
> 因此一律先**实测像素**再写坐标（对应铁律「严禁盲写假坐标」）。

| 工具 | 用途 |
|---|---|
| `probe/probe_effects_geometry.py` | 从真实像素（accent 色连通域分析）推导效果页控件坐标 |
| `probe/probe_controls.py` | 鼠标慢速巡检 + 命中控件记录 |
| `probe/probe_bass_slider.py` | 取证低音卡开关 ON + 高级区展开后的滑块行坐标 |
| `probe/probe_shelf_layout.py` | 取证低频搁架滑块的可定位特征（布局随记忆状态/滚动位置变化） |
| `probe/log_clicks.py` | 人工点击的**旁路记录器**（不代点，人在前台点，它实时记） |
| `probe/shot_effects.py` | 在与 UI 测试完全相同的条件下截效果页，供肉眼比对控件 |
| `probe/diag_rail_icons.py` | 导航 rail 图标/文字像素诊断（MaterialIcons 被 tree-shake 时定位缺失图标） |
| `probe/mem_baseline.py` | 内存基线取证 + 点击切片截图（产物 `tools/mem_trace_*`，已 gitignore） |

## 4. 资源流水线

`resource_pipeline/` — 对应 [`docs/音频资产盘点与资源包构建实施方案-2026-10-11.md`](../docs/音频资产盘点与资源包构建实施方案-2026-10-11.md)：

| 工具 | 用途 |
|---|---|
| `resource_pipeline/clean_and_organize.py` | 声学资源盘点、哈希去重与清洗 |
| `resource_pipeline/build_packages.py` | 按声学功能分类的四级分发资源包构建 |

---

## 5. 运行方式

```bash
python tools/bin/run_tests.py --smoke     # 转发 test/runner.py --smoke
python tools/bin/run_tests.py --ui        # 转发 test/runner.py --ui
# 或直接用原生入口：
python test/runner.py --smoke
python test/runner.py --ui
```

受限网络下推送：

```bash
python tools/bin/push_via_api.py main
```
