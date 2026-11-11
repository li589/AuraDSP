# VAIO 模式安装版误报诊断结论（2026-11-09）

> 触发：owner 在 vm-win10 用 Setup **正常流程安装**后选择 VAIO 模式，UI 显示
> 「未检测到 AuraVAIO 虚拟声卡驱动」+ 「未找到 install_driver.ps1 安装脚本」，
> 而设备管理器里 `AuraVAIO Virtual Audio Device` 与「麦克风/扬声器 (AuraVAIO …)」
> 端点都在。owner 归因两点：①驱动已装却报未检测到；②脚本没解压到可识别位置或命令有误。
>
> 结论：**②完全成立（且比 owner 估计的更严重，路径与命令双重不匹配）；
> ①不成立为「驱动/权限问题」，真实原因是 UI 检测状态机从未被触发**。
> 本轮为只读诊断，未改动任何产品代码、脚本或构建产物。

## 一、真机事实基线

安装目录（注册表 `HKLM/HKCU Uninstall` + 进程路径双重确认）：
`C:\Users\li\AppData\Local\Programs\AuraDSP`（`asInvoker`，非提权）。

| 检查项 | 结果 |
|---|---|
| MEDIA 节点 | `ROOT\MEDIA\0000`，Status **OK**，1 个（上一轮清理后） |
| 音频端点 | 麦克风 / 扬声器各 1 个 AuraVAIO，均 OK（幽灵端点已清） |
| `auravaio_bridge.dll` | 安装目录根，**存在** 82944 B |
| `auradsp_app.exe` manifest | `requestedExecutionLevel level="asInvoker"`（不提权） |
| 随包 `driver/` | `install_vaio.ps1`、`install_driver.ps1`、`AuraVaioDriver.{sys,inf,cat}`、`devcon.exe`、ASIO DLL 等 **10 项齐全** |
| 源码树相对路径 `core/desktop/windows-drivers/…` | **不存在**（`SRC|False`） |

## 二、检测链路实测（直接调用随包桥的 `ab_detect`）

`app/auradsp_app/lib/engine/bridge_manager.dart:100` 查的导出是 **`ab_detect`**
（2026-10-30 公共导出面收敛，旧名 `vaio_detect` 已不导出）。
`ab_detect` 把「能否 `CreateFileW(\\.\AuraVaioControl)`」作为 `found` 的唯一判据
（`VaioBridge.cpp:761-784`）。

| 令牌 | `IsUserAnAdmin` | CreateFileW RW/RO/NONE | `ab_detect` |
|---|---|---|---|
| SSH 提权会话 | True | 全 ok | **found=true**（modern 1.0.0） |
| explorer 未提升交互令牌（**等价 asInvoker app**） | False | 全 ok，err=0 | **found=true** |
| `runas /trustlevel:0x20000` 基本用户受限令牌 | False | **全 err=5 ACCESS_DENIED** | found=false |

原始输出：`probe-admin.out` / `probe-explorer.out` / `probe-nonadmin.out`；
探针源码 `probe_vaio.py`（同目录，可复现）。

**因此排除「驱动没装 / 权限不够 / 桥 DLL 缺失」作为本次截图的原因。**
`runas` 基本用户令牌比 UAC 未提升令牌更受限（IU 组被 deny-only），
只能说明 `ab_detect` 的检测口径不够健壮，不能解释正常桌面启动的 app。

## 三、根因 A：UI 检测状态机从未触发（截图「未检测到」的真实原因）

1. `state.dart:283` → `vaioDetectInfo = {}` 初值为**空 map**；
   `hardware_drivers.dart:304` → `final found = det['found'] == true` → 空 map 恒为 `false`。
2. `vaiodetect` 事件只在 isolate 收到 `{'cmd':'vaiodetect'}` 时发出
   （`audio_isolate.dart:1322` → `detectVaio()`）；全仓 `refreshVaioDetect()` 的调用点只有：
   - 3 个「重新检测」按钮（`hardware_drivers.dart:378`、`hardware_io_output.dart:366`、`sections.dart:515`）
   - `refreshAudioDevices()` 首行（`state_audio_modes.dart:239`），而后者也只挂在 3 个
     「刷新端点」按钮与 install/uninstall 成功路径上。
   - **无任何启动时 / 页面 `initState` 自动检测**（`hardware_drivers.dart` 无 StatefulWidget/initState）。
3. 更关键：`installVaioDriver()`（`state_audio_modes.dart:306-336`）在
   `script == null` 时于 **310-314 行提前 return**，而 `refreshVaioDetect()` 在 **320 行**。
   所以 owner 点「UAC提权安装驱动」→ 脚本找不到 → 立即返回 → **检测依旧没跑**。
   这正是截图里「驱动已装 + 未检测到 + 未找到脚本」三态同时出现的必然路径。

推论：只要点一次「重新检测」或任一「刷新端点」按钮，`found` 就会变为 true。
（未启动 GUI 实测，属代码路径推断；可由 owner 一键复核。）

## 四、根因 B：脚本路径与命令**双重**不匹配（owner 第 ② 点成立）

### B-1 路径
`state_audio_modes.dart:298-301`

```dart
String? _findVaioInstallScript() =>
    windowsSystem.findRepoFile(const [
      'core/desktop/windows-drivers/01_vaio_driver/install_driver.ps1',
    ]);
```

`windows_system_tools.dart:19-36` 的 `findRepoFile` 从 `Directory.current` 逐级上溯 4 层，
找的是**源码树相对路径**。安装版是扁平布局，脚本在 `driver/` 子目录 → 必然返回 `null`
→ `lastVaioError = '未找到 install_driver.ps1 安装脚本'`。

### B-2 命令
即便把路径改对，`windows_system_tools.dart:44-67` 的 `vaioDriver()` 拼的是：

```
powershell -ExecutionPolicy Bypass -File <script> -Action install -Config Release
```

- 随包自包含脚本 `driver/install_vaio.ps1` **没有 `-Config` 参数**（只有 `-Action`、
  `-SkipSignCheck`、`-RemoveTestCert`）→ 参数绑定失败。
- 随包另有 `driver/install_driver.ps1`，但那是**开发期体检脚本**，按源码树
  `modern/x64/<Config>/AuraVaioDriver` 找包、依赖 WDK signtool，随包环境不可用；
  `installer/windows/README.md:46` 已明确「仅保留供诊断」。
- 安装向导走的是另一套正确路径：`install_engine.dart:172` →
  `<installDir>\driver\install_vaio.ps1 -Action install`。
  **app 与向导是两套互不相干的实现，发布侧只验证了向导那套。**

## 五、修复方案（按依赖分层，均未动手）

| 层 | 文件 | 改动 |
|---|---|---|
| P0 状态机 | `state_audio_modes.dart` | `installVaioDriver()` 的 early return 前后都触发 `refreshVaioDetect()`；app 启动 / 进入设置页时自动发一次 `vaiodetect`（建议放在 engine isolate 就绪回调） |
| P0 脚本定位 | `state_audio_modes.dart` + `windows_system_tools.dart` | 候选列表改为「随包 `driver/install_vaio.ps1`（以 `Platform.resolvedExecutable` 父目录为基准，不依赖 `Directory.current`）→ 源码树 `install_driver.ps1`（仅开发期）」 |
| P0 命令 | `windows_system_tools.dart` / port 接口 | 按脚本类型分支：随包脚本只传 `-Action install`，不传 `-Config`；源码树脚本保留 `-Config Release` |
| P1 检测口径 | `VaioBridge.cpp::vaio_detect` | 把「驱动存在」与「控制通道可访问」拆开：用 PnP/WASAPI 端点存在性判定 `found`，另加 `accessible`/`accessError` 字段；避免受限令牌误报 |
| P1 UI 文案 | `hardware_drivers.dart` + arb | 区分「驱动未安装」「驱动已装但需提权」「检测未执行」三态，别一律显示"未检测到" |
| P1 回归 | `test/smoke/`、`app/auradsp_app/test/` | 新增安装版布局用例：断言随包脚本候选命中、命令不含 `-Config`、空 `vaioDetectInfo` 时也能自动触发检测 |

**不建议**放宽 `ControlDevice.cpp:75` 的 DRV-04 SDDL：实测 asInvoker 令牌可正常打开，
放宽只会削弱安全加固而不解决本次问题。

## 六、归档与状态

- 原始证据与探针均落在 `outputs/`：`probe-{admin,explorer,nonadmin}.out` +
  `probe_vaio.py`。`.gitignore:101` 忽略 `test/date/**/work/`，故探针不留在
  `work/`，与结论文档同目录入库，保证自洽证据包无断链。
- 真机临时目录 `C:\Users\li\AppData\Local\Temp\auradsp_s7\` 留有探针与输出，未清理。
- 本轮**只读**：未改产品代码、未改驱动、未重打包、未提交；`git status` 仅新增本归档目录。
