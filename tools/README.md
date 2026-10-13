# tools/ — 开发辅助工具与小组件

> **职责边界（铁律）**：
> - `tools/` = 开发调试辅助工具、生成器、诊断探针、一次性取证脚本；
> - `test/` = 全量测试套件（`test/smoke/` 引擎烟囱、`test/ui/` 置顶 UI 自动化、`test/data/` 测试数据）。
>
> **二者的判据**：有断言、能无人值守跑完、用于回归门禁 → 进 `test/` 并**必须登记 `test/runner.py`**；
> 只做观测/取证/生成、需要人工参与 → 留 `tools/`。
>
> **目录**：`bin/` 可重复运行的工程工具；`probe/` 一次性诊断探针（用完即归档）；
> `calibration/`、`resource_pipeline/` 主题工具；`archive/` 过程产物（gitignored）。

---

## 1. 构建与工程（`bin/`）

| 工具 | 用途 |
|---|---|
| `bin/run_tests.py` | 统一测试执行入口桥接（转发 `test/runner.py`） |
| `bin/push_via_api.py` | GitHub REST API 离线/受限网络推送兜底（自行组装 blob/tree/commit，sha 逐字一致） |
| `bin/verify_dll_copies.py` | DLL 三处同哈希单向分发+校验 |
| `bin/abi_consistency.py` | .def/engine.h/ffi.dart 45 符号一致性（`smoke_abi_consistency.py` 调它） |
| `bin/rebuild_plugin_cache.py` | 用引擎真实扫描结果重建 `%APPDATA%\AuraDSP\plugins\plugin_cache.json` |
| `bin/fix_docs_links.py` | docs 搬迁后改链（P0 沉淀，可复用） |

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
