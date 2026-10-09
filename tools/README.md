# tools/ — 开发辅助工具与小组件

> 职责划分说明（2026-10-10 更新）：
> - `tools/`：存放开发调试辅助工具、生成器、诊断小组件（如 API 推送、图标诊断、IR 生成等）；
> - `test/`：存放全量测试脚本（`test/smoke/` C++ 引擎烟囱测试、`test/ui/` 前置置顶 UI 自动化验证与断言）与测试数据（`test/data/`）。

## 常用工具列表

| 工具 | 用途 |
|---|---|
| `run_tests.py` | 统一测试执行入口桥接（自动调用 `test/runner.py`） |
| `push_via_api.py` | GitHub REST API 离线/受限网络直推工具（支持 blob/tree/commit 组装） |
| `gen_test_irs.py` | 生成各规格测试脉冲响应（IR）文件工具 |
| `bench_effects.py` | 各 DSP 算法 CPU/内存开销基准评测工具 |
| `diag_rail_icons.py` | Flutter Material 图标字体子集化与 tree-shake 诊断工具 |
| `fft_probe.cpp` / `emit_probe.cpp` | FFT 输出布局与 emit 采样轻量 C++ 探针 |

## 测试执行说明

运行全量测试请使用：
```bash
python tools/run_tests.py --smoke      # 运行 C++ 引擎烟囱测试
python tools/run_tests.py --ui         # 运行置顶前置 UI 自动化验证测试
# 或者直接使用 test 目录原生入口：
python test/runner.py --smoke
```
