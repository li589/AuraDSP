# test/ — 测试套件与自动化验证

> 本目录集中管理 AuraDSP 的所有自动化测试用例与基建。

## 目录结构

- `smoke/`：C++ 音频引擎烟囱测试（通过 Python `ctypes` 直接加载 `auradsp_engine.dll`，RT 契约、内存无泄漏、锁安全、参数状态机验证）。
- `ui/`：Win11 活动桌面严格前置置顶（HWND_TOPMOST + SetForegroundWindow）UI 自动化交互与像素断言回归。
- `data/`：测试输入数据与音频基准样本（IR 脉冲、DDC 空间校正文件等）。
- `runner.py`：全量测试执行器。

## 运行方式

```bash
# 1. 运行底层 C++ 引擎全量单测 (100% 自动化，无需 GUI)
python test/runner.py --smoke

# 2. 运行 UI 前置置顶交互自动化验证 (需启动 AuraDSP 窗口并在物理桌面运行)
python test/runner.py --ui
```
