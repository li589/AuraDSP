# AGENT.md — AuraDSP 智能体协作总纲与工程指南

> 本文档专为 AI 编码智能体（Antigravity、Codex、Cursor、Claude、AutoDev 等）编写，旨在帮助智能体秒级熟悉项目全貌、架构铁律、目录规范与工作流。

---

## 1. 项目定位与架构总览

**AuraDSP** 是一款面向跨平台（Windows 11 / Android）的下一代高品质音频 DSP 引擎与现代控制台套件。

### 技术栈与分层

| 层次 | 路径 | 核心技术 | 职责与契约 |
|---|---|---|---|
| **核心引擎** | `core/desktop/` | C++20, MSVC/CMake, libjamesdsp | 移植与扩展的底层 DSP 管道；WASAPI 独占音频泵；严格遵循 **RT-Safe（音频线程零锁、零内存分配、零系统调用）** |
| **应用前端** | `app/auradsp_app/` | Flutter 3.47.7+, Dart FFI | 现代暗黑精致音频工作站 UI；6 页导航体系（主页/效果/脚本/插件/处理链/可视化）；高频可视化与状态隔离 |
| **无锁桥接** | `auradsp_engine.h/cpp` | SPSC 无锁环形缓冲区 | 引擎以 30fps 向 UI 单向推送 280 字节定长 `VizFrame`（含 32 带 FFT、总峰值及 16 节点 per-stage 电平表） |
| **参考源码** | `source/` | C/C++/Java/Kotlin | 第三方参考代码库（只读，严禁嵌套 `.git`，严禁在此写代码） |

---

## 2. 目录规范与职责划分

| 目录 | 职责范围 | 规则与约束 |
|---|---|---|
| `core/` | 引擎动态库源码、ABI 接口定义、CMake 构建脚本 | 修改任何音频路径必须保证 RT-Safe |
| `app/` | Flutter 前端工程、L10n、各功能页、FFI 绑定 | 构建命令必须带 `--no-tree-shake-icons` |
| `test/` | **全量测试套件**：`test/smoke/`（C++ 引擎单测）、`test/ui/`（UI 自动化置顶测试）、`test/data/`（测试数据） | 测试统一入口 `python test/runner.py` |
| `tools/` | **开发辅助工具与小组件**：`push_via_api.py`、`gen_test_irs.py`、`diag_rail_icons.py`、`bench_effects.py` 等 | 纯工具性质，不包含测试用例 |
| `docs/` | 架构方案、UI 设计规范、决策记录 (ADR)、阶段报告 | 方案先行，设计更新后必须同步文档 |
| `.ai/` | **AI 自治沉淀区**：包含 `.ai/memory/`（历史上下文与每日备忘）、`.ai/guidelines/`（经验教训） | 各类智能体共享知识，无需人工介入 |

---

## 3. 智能体工程开发铁律

### 3.1 引擎与音频契约（RT-Safe）
1. **音频主线程绝对禁区**：禁止 `malloc/free/new/delete`，禁止 `std::mutex/jdsp_lock` 竞态，禁止 IO/打印/系统调用。
2. **表驱动处理链（P-004）**：12 效果节点顺序经由 `graph.order` 完整重排序，非法集合必须白名单全拒；每个 stage 的峰值采样必须是 $O(1)$ 常数时间。
3. **文件门卫（FileGate）**：加载 IR 脉冲文件或 VDC 文件必须经由六道门卫校验（magic、尺寸、NaN/Inf 检测、重采样），防崩溃与内存溢出。

### 3.2 UI 与交互规范
1. **高频渲染与状态隔离**：30fps 的电平与频谱可视化通过独立 `ValueNotifier` 驱动局部重绘，严禁触发根级 `notifyListeners`。
2. **双击出厂归位**：所有参数滑块均支持整行双击恢复 `ParamDefaults` 出厂默认值；声场展宽双击归位时联动清空 5 个子带。
3. **构建必带参数**：`flutter build windows --release --no-tree-shake-icons`，严禁遗漏 `--no-tree-shake-icons`（避免 Material 图标子集化静默丢失）。

### 3.3 自动化测试铁律（血泪教训）
1. **测试与开发工具严格分流**：测试脚本一律放在 `test/smoke/` 或 `test/ui/`，开发小工具放在 `tools/`。
2. **新测试必须挂载 `test/runner.py`**：新增 `test/smoke/*.py` 须登记进 `smoke_files` 列表，新增 `test/ui/*.py` 须登记进 UI 默认列表——未挂载的测试不会被 `--smoke`/`--ui` 执行，等同废测。
3. **UI 自动化测试三要素**：
   - **强制前置置顶**：必须调用 `HWND_TOPMOST` + `SetForegroundWindow`，并在 `WinSta0\Default` 物理活动桌面上交互。
   - **状态先行保障**：在拖动任何滑块前，**必须先检测并确保卡片主开关处于打开激活状态**；开关关闭时滑块处于 disabled 状态，任何点击拖拽均为无效操作！
   - **像素级几何命中**：通过窗口矩形归一化与实际组件像素推导 Thumb 圆心位置，严禁盲目写死假坐标。
   - **视觉差分闭环断言**：每步操作前后必须比对截图区域像素差异（`assert_images_differ`），确保动作真正生效，杜绝假测试。

### 3.4 文档纪律
- **真相源**：`docs/项目架构与开发规范.md`（工程）与 `docs/产品架构总览.md`（产品/品牌）；导航入口 `docs/README.md`。
- **不可逆取舍开 ADR**：编号顺延（现行 ADR-001 ~ ADR-004），写明背景/决策/后果/回退条件；已冻结的 ADR 不得原地改写，回退须新增编号。
- **方案回写实施状态**：能力落地后必须回写对应方案的里程碑小节，并同步真相源的目录/决策表/路线图。
- **只读证据不动**：`docs/forensics/` 为审计原始证据，禁止删改。

---

## 4. 常用命令速查

```powershell
# 1. 运行底层 C++ 引擎全量单测 (100% PASS 门禁)
python test/runner.py --smoke

# 2. 运行 UI 自动化前置置顶测试
python test/runner.py --ui

# 3. 前端静态代码分析
cd app/auradsp_app; flutter analyze

# 4. 构建 Release 版本应用
cd app/auradsp_app; flutter build windows --release --no-tree-shake-icons

# 5. 受限网络或 API 推送代码到远端
python tools/push_via_api.py main
```
