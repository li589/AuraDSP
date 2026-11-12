# test/ — 测试套件与自动化验证

> 本目录集中管理 AuraDSP 的所有自动化测试用例与基建。

## 目录结构

- `smoke/`：C++ 音频引擎冒烟测试（通过 Python `ctypes` 直接加载引擎库——Windows `auradsp_engine.dll` / Linux `libauradsp_engine.so`，RT 契约、内存无泄漏、锁安全、参数状态机验证）；含 Linux 专属门禁（PA/ALSA 后端、虚拟 sink、XDG、插件宿主与 32 位桥、X11 编辑器）。全量 143 项登记，Linux 口径 PASS 14 / SKIP 129（Windows 专属）/ FAIL 0（2026-11-05 基线）。
- Dart 单测在 `app/auradsp_app/test/`（CI J6 口径 70 文件 PASS / 4 平台跳过），入口 `tools/bin/run_dart_tests.py`。
- `ui/`：Win11 活动桌面严格前置置顶（HWND_TOPMOST + SetForegroundWindow）UI 自动化交互与像素断言回归。
- `data/`：测试输入数据与音频基准样本（IR 脉冲、DDC 空间校正文件等）。
- `fixtures/`：手工维护的微型测试插件源码（如 `vst2_gain`），供插件宿主类冒烟现场编译。
- `vm/`：虚拟机内运行的验证执行器（APO 联调、ABI 校验），由宿主机侧脚本拷入 guest 后运行。
- `date/<YYYY-MM-DD>/<task>/`：日期任务的过程目录——`work/` 放原始采样/临时构建/对照截图（已忽略不入库），结论文档正常入库。
- `build/<name>/`：**编译验证子项目的唯一合法落点**（见下「构建树与临时产物规范」）。
- `runner.py`：全量测试执行器。
- `engine_artifact.py`：引擎构建产物的单一路径解析器——smoke/工具一律经它定位引擎库，禁止再拼字面路径。

## 构建树与临时产物规范（2026-11-12 定）

- **编译验证用的独立 CMake 构建树**（如 APO-only 配置 `test/build/apo-windows/`）一律放在
  `test/build/<name>/` 下：该目录被 `.gitignore` 的 `**/build/` 规则覆盖，天然不污染
  `git status`。**禁止在仓库根目录或源码目录随手创建 `build_*` 临时树**——第十七轮的
  根目录 `build_apo_r17/` 曾一次冒出 283 个未跟踪文件，即为此规之由。
- `test/` 根的 `libauradsp_engine.so`、`plugin_host_x64`、`plugin_host_x86` 是测试运行
  同步过来的引擎工件（已忽略），勿入库、勿手改；需要时由构建/同步流程重新生成。
- 一次性探针/取证程序若有留存价值，归位到对应源码目录的 `tools/`（如
  `core/desktop/windows-drivers/tools/`）并登记其 README，不要留在 `test/` 根或系统临时目录。

## 运行方式

```bash
# 1. 运行底层 C++ 引擎全量单测 (100% 自动化，无需 GUI)
python test/runner.py --smoke

# 2. 运行 UI 前置置顶交互自动化验证 (需启动 AuraDSP 窗口并在物理桌面运行)
python test/runner.py --ui
```

## 值守型脚本（刻意不挂载 runner）

铁律是「新测试必须登记 `test/runner.py`，未挂载等于废测」，但以下脚本**会弹真实窗口或依赖本机特定商业插件**，
无法在无人值守环境中运行，因此刻意不从 runner 挂载——这不是遗漏，是有意豁免：

| 脚本 | 豁免原因 | 门禁替代者 |
|---|---|---|
| `smoke/smoke_three_key_plugins.py` | 弹插件原生 GUI；依赖本机 FabFilter / iZotope / Element 已安装 | `smoke_plugin_host.py`、`smoke_multislot_and_stages.py` |
| `engine/plugins/tests/plugin_host_direct.cpp` | C++ 侧 GUI 批量验证，需编译后手动执行 | 同上 |

新增测试时先自问「能否无人值守跑完」：能 → **必须登记 runner**；不能 → 在本表登记豁免原因。
