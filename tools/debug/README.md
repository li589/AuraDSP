# 调试体系与控件实测

## 启动

```powershell
# 需要先构建 Release（会同时带上引擎 DLL）
cd app\auradsp_app
flutter build windows --release --no-tree-shake-icons

# 从仓库根启动调试实例，并在终端跟随 JSONL
powershell -ExecutionPolicy Bypass -File tools\debug\run_debug.ps1 -Tail
```

自定义日志路径/可执行文件：

```powershell
powershell -File tools\debug\run_debug.ps1 -Log D:\tmp\aura_trace.jsonl -Exe D:\...\auradsp_app.exe
```

`--debug` 打开调试总线；`--debug-log=<path>` 指定 JSONL；`--debug-console`
同时写 stdout（从终端启动时可见）。默认路径
`%TEMP%\auradsp_debug_trace.jsonl`。不传 `--debug` 时调试总线完全关闭，
不产生文件、定时器或额外格式化。

## 事件流

每行一个 JSON：

| cat | action | 含义 |
|---|---|---|
| `ui` | `control.register` | 参数控件首次出现在页面上 |
| `ui` | `control` | 用户拖动滑块/切换开关/选择 chip，含参数 id、值、section |
| `ui` | `tap` | 通用 chip / segment / dropdown / choice 点击，含可读 label |
| `ui` | `pointer` | 根级指针兜底（x/y），覆盖没有语义标签的自定义控件 |
| `param` | `send` | 主 isolate 发往音频 isolate 的 `setParam`/`setParamStr` |
| `engine` | `ack` | DSP 层回执 `paramResult`：`value`（已接收值）、`rc`、`tookMs`、拒绝原因 |
| `command` | `send` | 非参数命令（bypass、getParams、音频模式、播放等） |
| `lifecycle`/`error` | `app.start`/`log` | 生命周期与异常 |

## 汇总核对

手动操作结束后：

```powershell
python tools\debug\summarize_trace.py %TEMP%\auradsp_debug_trace.jsonl
```

输出事件计数、UI/param/ack id 数，并列出 **有 ui/param 但没有 engine.ack**
的 id。`RESULT: PASS` 表示所有用户操作都收到了 DSP 回执。

## 控件实测流程

1. 用 `run_debug.ps1 -Tail` 启动，右上/右下角出现 `DEBUG TRACE` HUD；
2. 依次进入 Home / Effects / Chain / Settings / Liveprog / Visualizer；
3. 对每个滑块拖动一次、每个开关切换一次、每个 chip/dropdown 点击一次；
4. HUD 头部 `UI x/y · ACK z` 会实时增长：
   - `x` = 已出现并被记录的参数控件 id 数；
   - `y` = `ParamRegistry` 中非派生参数总数；
   - `z` = 已收到成功引擎回执的参数数；
5. 在 JSONL 中核对同一 id 的 `ui.control` → `param.send` → `engine.ack`
   是否连续出现；若只有 `ui`/`param` 没有 `engine.ack`，说明音频 isolate
   未回执或引擎未处理。

## 打印规范

- 业务代码禁止直接 `print(` / `debugPrint(`；统一走 `dbgLog`（崩溃/错误
  文件日志）或 `DebugTrace`（结构化调试事件）。
- `tools/bin/debug_log_scan.py` 与 `test/smoke/smoke_debug_policy.py`
  会拒绝新增的直接打印。
- 引擎侧继续使用编译期 `AURADSP_DBG_LOG` + 运行期 `AURADSP_LOG=0|1|2`
  （`engine/debug_log.h`），RT 路径禁止任何日志。
- 调试事件不得记录用户音频内容、完整脚本源码或密钥；`DebugTrace`
  对字符串事件截断到 240 字符。
