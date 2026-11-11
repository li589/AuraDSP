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
| `bin/fetch_via_api.py` | `push_via_api.py` 的对偶：`github.com:443` 不通、`git fetch` 挂死时，用 Git Data API 把远端提交**逐字重建**进本地对象库（只下载真正新增的 blob/tree，重建后断言 SHA 与远端一致，对不上即中止；时区未知时按候选表试算并校验） |
| `bin/win_env_sanitize.py` | Windows 环境变量大小写重复键归一化器：宿主（沙箱/CI 包装器）会让 `PATH`/`path`/`Path` 并存、每个变量存两份，而 .NET Framework 的 `ProcessStartInfo.EnvironmentVariables` 大小写敏感 → 第二个 "path" 撞键抛 `ArgumentException('path')`，MSBuild 的 CL.exe 根本没被拉起、编译静默产出陈旧二进制。本脚本读原生块按大小写合并（PATH 取并集、其余留首次值）后启动子进程；顺带支持 PATHEXT 解析与 `.bat` 垫片转发（`flutter` 是 .bat）、`MSBUILDDISABLENODEREUSE=1`、编译日志原始字节直写 |
| `bin/verify_dll_copies.py` | DLL 三处同哈希单向校验（仅校验；**分发**已改由 `sync_artifacts.ps1` 负责） |
| `windows/sync_artifacts.ps1` | 增量产物一次性同步：把引擎 DLL / 宿主 EXE / 三个桥从真相源覆盖分发到 `test/`、`app build runner`、`dist` 三处；端点缺失或单文件覆盖失败仅告警并跳过（替代手工 cp；`-WhatIf` 预演、`-PackZip` 重打包发行 zip） |
| `windows/build_windows.ps1` | Windows 全栈构建/产物整理/资源打包流水线（根 CMake preset → 引擎/桥/Flutter → dist；根级 `tools/build_windows.ps1` 薄转发，命令不变） |
| `windows/remote_win10.ps1` | Win10 虚拟机远程命令（ssh 封装；根级同名薄转发） |
| `windows/*.bat` | 增量引擎构建与两组 smoke 快捷批处理（根级同名薄转发；内容仍为历史硬编码入口） |
| `bin/abi_consistency.py` | .def/engine.h/ffi.dart 56 符号一致性（`smoke_abi_consistency.py` 调它） |
| `bin/legacy_copy_drift.py` | 桌面 `engine/legacy` 与 Android `vendor-src/libjamesdsp` 副本差异报告（CP-03：差异是上游快照现状，工具只做可见化；`--strict` 在 vendor 侧多出文件时判红） |
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

## 5. 性能回归（Windows，需前台桌面会话）

| 工具 | 用途 |
|---|---|
| `windows/perf_regression.py` | 四场景（启动空载 / 可视化静默 / 播放态 / 最小化）内存·CPU·GPU 采集，输出 JSON + CSV + 截图，路径全部由脚本自身推导 |
| `windows/gpu_sampler.ps1` | 按 PID 采 `\GPU Engine(*)\Utilization Percentage` 与 `\GPU Process Memory(*)`（tab 分隔 CSV） |
| `perf_regression.py` | 根级薄转发，命令行不变 |

```bash
flutter build windows --release --no-tree-shake-icons   # 先出 release
python tools/perf_regression.py                        # 四场景 sysapo
python tools/perf_regression.py --mode voicemeeter_api # VB attach
python tools/perf_regression.py --scenario play --strict
# 编排入口（同样转发到 tools/windows/）：
python test/runner.py --perf --perf-strict
python test/runner.py --perf viz --perf-mode voicemeeter_api
```

**不属于 `--smoke` 常驻门禁**：会移动鼠标、最小化窗口，必须有真实桌面会话。
产物默认在 `<repo>/.tmp/perf-regression/<时间戳>/`（gitignore）：`summary.json` 是
机器可读总表，`stages.csv` 是一行一场景的对照表，`proc_<scene>.json` 是逐秒原始样本，
`stage_<scene>.png` 用来确认点击落点。阈值是“本机最终值 ≈1.3–1.5 倍”的软门禁，
不加 `--strict` 只打印 WARN；VB 的 CPU 由 8 路引擎泵送主导，阈值刻意放宽。
详见 `test/date/2026-11-06/perf-final/outputs/perf-final-report.md`。

---

## 6. 运行方式

```bash
python tools/bin/run_tests.py --smoke     # 转发 test/runner.py --smoke
python tools/bin/run_tests.py --ui        # 转发 test/runner.py --ui
# 或直接用原生入口：
python test/runner.py --smoke
python test/runner.py --ui
python test/runner.py --perf              # Windows 性能回归（四场景）
```

受限网络下推送：

```bash
python tools/bin/push_via_api.py main
```
