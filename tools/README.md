# tools/ — 可复用工具脚本

> 从 `.tmp/` 沉淀的可复用验证工具（2026-10-09）。引擎烟囱测试用 Python 3.12
> 运行（ctypes 直调 `core/desktop/windows/out/Release/auradsp_engine.dll`，
> 路径已内置）。**UI 验证脚本需先启动 APP 再在同一条命令里运行**（沙箱会
> 在命令结束时清杀子进程）。

## 引擎烟囱测试（ctypes，无需音频设备）

| 脚本 | 覆盖 |
|---|---|
| `smoke_viz_lowfreq.py` | 可视化低频频段：相位连续 60Hz → band5 峰值/无 DC 泄漏（4096-FFT + 每块写历史回归） |
| `smoke_liveprog.py` | Liveprog 全流程 7 项：加载/增益×2/停用直通/语法错误文案/滑块保持/回读/unload |
| `smoke_convolver.py` | 卷积 + 文件门卫 7 组：4 类恶意样本拒绝/delta 直通/44.1k 重采样/T2 守卫/直通恢复 |
| `smoke_guard_flow.py` | 守卫自动升档等效链路：音乐档拒 → 品质档放行 → 延迟 30ms → 回落 |
| `smoke_block1056.py` | 1056 帧大块压测（对齐 WASAPI pump 块长） |

运行示例：`"C:/Program Files/Python/Python312/python.exe" tools/smoke_liveprog.py`

## UI 运行时验证（DPI-aware 截图 + 像素断言）

| 脚本 | 用途 |
|---|---|
| `ui_verify2.py` | RailToggle 可见性/导航指示条落位/收起往返 + 截图 05-09 |
| `ui_verify.py` | 旧版首页布局验证（保留对照） |
| `ui_assert.py` | 对已存截图做像素断言（收起往返/hero 位置/背景模糊） |

依赖 `PIL`（`C:\Program Files\Python\Python312` 自带）。

## FFT 输出布局探针（C++，独立编译）

`fft_probe.cpp` / `emit_probe.cpp`：验证 WDL_real_fft 的 permute 读回与
emit_viz 逻辑复刻。构建参考 `.tmp/probe` 时代的 CMake（vendor fft.c + 探针
cpp，`project(fft_probe C CXX)` + `/utf-8`）。
