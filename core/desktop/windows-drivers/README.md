# core/desktop/windows-drivers/ — Windows 底层驱动套件（SPEC-WIN-DRIVER-001）

> 与 `engine/`（DSP 算法）彻底解耦：本目录只做传输与格式搬运，
> 不承载任何具体音效算法；仅依赖 Windows SDK（用户态）/ WDK（内核态）。
> APP 侧音频后端四模式（vaio/vbcallback/sysapo/asio）见 `app/auradsp_app/lib/core/audio_modes.dart`，
> 本目录是其 Windows 驱动侧对应实现（vbcallback / sysapo / asio / **vaio** 四者现均有实物；
> vaio 为内核态，见 `01_vaio_driver/`）。
>
> 刻意**不在**本目录的 Windows-only 代码：进程内 WASAPI 渲染
> （`app/auradsp_app/lib/engine/audio_device.dart`，Dart 直调 COM）。
> 本目录是 C++/CMake 运输层（SDK/WDK 门禁、dumpbin 导出表、ctypes smoke），
> 一个 Dart 文件搬进来两边都不沾；真要收编只能重写成 `00_wasapi_engine` DLL
> （render 线程 + FFI + smoke 全套），而主力通路（ADR-001）在 Dart 侧跑得好好的——
> 结论：不搬。触发重写的唯一理由是功能需求（独占模式/事件驱动/设备变更回调），
> 不是洁癖。

## 现状（2026-10-15；vaio 驱动 Phase 4 双轨编译通过）

- [x] 目录骨架 + 独立 CMake（VS18 x64，不进引擎构建）
- [x] `02_voicemeeter_client/`：三级自省检测（注册表 → Remote DLL → PE 版本）
- [x] `02` OUTPUT INSERT 回调泵（A1 主对进引擎 + 其余透传 + 静音旁路 + 中性透传验证）
- [x] 回调语义对标 `source/equalizerAPO64/VoicemeeterClient`（bus 组迭代/精确零+10s+输出静默
      三条件 idle/CHANGE 计数；初版 1e-5+2s 已按此推翻，见 `VmAudioCallback.cpp` 头注）
- [x] `02` **CHANGE 触发引擎重建**（`c3e26b4`：VM 参数变化才重建，`--fake-change` 可测；
      旧轮询式重建已废）

## 托盘图标语义（VM 原生 tooltip 实证）

- **R-BOX**：Remote API 客户端占用，一格一 login，上限 8。漏 Logout 即攒 R
  （曾 6 次运行复现 R 全亮；现已 Login/Logout 单次配对，EAPO `endSoftware` 同式）。
- **A-BOX**：内部音频回调被占用。EAPO 常驻回调故常亮 A；本泵只在运行秒级内持有，
  平时无 A。点 A 可看占用者（与 EAPO 共存时互相看到对方名）。

## 占用 / 崩溃 / 重试策略（EAPO 对标）

- OUT 槽同时只能一家：`rc==1` 直接让路记 note；其它非零按 EAPO 式有界重试
  10×100ms（EAPO 是 30×，泵短命故减半），超时仍优雅退出码 0。
- Double-Logout / Double-FreeLibrary 会 AV（已抓现行各一次）：leave 幂等，
  logout+unreg 全路径单次配对。
- 进程崩溃会滞留 OUT 槽（VM 侧无超时回收）→ 重启 VM；R 会话同理靠重启清。
- VM 被杀：回调断流→精确零→bypass 透传→ stop/unreg/logout 照常返回（已实测杀进程，
  exit 0 无崩溃）；引擎住在 audiodg，杀 GUI 未必停泵。
- 死锁：结构不可能（RT 零锁 + 主线程无等待回调的原语，见源码头注）。
- 爆音预算：`maxCbUs` 打点上报，中性 8 组约 3.2ms（缓冲 42.7ms），smoke 阈值半周期。
- [x] `02` 多总线逐对处理（版型预建 handle，组独立 idle）
- [x] `02` 参数下发面（`--seti/--setf`，回报 applied/failed；声学有条件断言）
- [x] `03_system_apo/`：自研 APO v1（`AuraApo.dll`：裸 COM 聚合 + 自注册 + 透传 + 心跳映射
      + SILENT 清零；专属 CLSID，IID 取自 SDK IDL；`smoke_apo_register.py` 覆盖导出表 + 注册往返）
- [x] `03` **EAPO 对标加固**（`d33bab4`：聚合/QI/注册/CRT/CFG/v2 五线对齐 equalizerAPO 行为）
- [x] `03` Configurator（`806b44b`：安装/备份/卸载/服务重启握手；`.reg` 备份 + 编程式恢复——
      `reg import` rc=1 不可靠已改道，见 `42c757e`）
- [x] `03` selftest（`806b44b`：unreg-safe 不破坏现场；心跳经 `Local\` 命名对象，
      **任意权限可验**，`c3e26b4` 起权限自适应）
- [x] `03` tone_play（`806b44b`/`88f35aa`：端点发声 + `set_default_endpoint` 切换默认设备）
- [x] `03` 诊断探针族（`88f35aa`/`4a77448`：`comact_probe`/`classfact_probe` COM/CLSID 链路、
      `ases_probe`/`audioclient_probe` 激活对象与音频客户端、`auditses_probe` 审计会话）
- [x] `03` 只读检测（端点枚举/FxProperties 五槽/签名开关；本机 48 端点全可读，
      在用微软 inbox SFX/MFX，无第三方 APO；`smoke_apo_inspect.py`）
- [x] `bridge/vm_bridge/`（原 `05_vm_bridge/`，`82a75ae`：`auravm_bridge.dll` SHARED 目标 + APP 安装捆绑；
      `verify_dll_copies` 校验 9 导出；桥 bypass 透传 + per-group 衰减峰值 +
      hottest-non-idle 可视化组 + 4 态显示 error/bypass/idle/processing）
- [x] `04_asio_engine/` Phase 1（`fcd0f3f`：ASIO 宿主探测+发声，GPLv3 路线；
      `asio_probe` 枚举 7 驱动 6 ok 全量能力 JSON + `asio_tone` 双驱动 3s 实测
      （FL Studio 259×512/44100=3.007s、VM Virtual 69×2048/48000=2.944s）；
      `smoke_asio_probe.py`/`smoke_asio_tone.py` 值守，全量 smoke 53 项 100%；
      SDK 2.3.4 就位于 `C:\FreeRulesPrograms\BasicToolkits\SteinbergDev\ASIOSDK`，
      登记与红线见该目录 README + `docs/20-执行/ASIO驱动开工Spec-2026-10-14.md`；
      Phase 2 常驻桥（DSP 入链）待开工）
- [x] `01_vaio_driver/`（**AuraVAIO 虚拟声卡，双轨**）—— **Phase 4 已落地并双轨编译通过**。
      目录按"源码单点真相 + 两条构建轨"组织：

      ```
      01_vaio_driver/
      ├── build_drivers.ps1        # 双轨构建入口（-Track modern | legacy）
      ├── install_driver.ps1       # 装载/卸载/只读体检（验收 ①）
      ├── src/                     # 单一源码真相：.cpp/.h + AuraVaioDriver.inf
      ├── modern/                  # WDK 28000 + VS2026，Win10 1809+/Win11 x64
      │   └── AuraVaioDriver.vcxproj + x64/<Config>/AuraVaioDriver/  # 包目录
      └── legacy/                  # EWDK 19041 + KMDF 1.11，Win7 SP1/8/8.1
          ├── AuraVaioDriverLegacy.vcxproj + build_legacy.ps1
          └── x64/<Config>/AuraVaioDriverLegacy/                     # 包目录
      ```

      AuraVAIO 为 PortCls/WaveRT 虚拟声卡（无硬件），单渲染端点：
      `WaveRT 过滤器（Wave）` + `拓扑过滤器（Topology）`，桥脚由
      `PcRegisterPhysicalConnection` 在运行时对接。`src/` 下 11 个 TU/头：
      `Driver.cpp`（DriverEntry→WdfDriverCreate(NoDispatchOverride)→PcInitializeAdapterDriver→
      挂钩 IRP_MJ_PNP/Unload）、`AdapterCommon.{h,cpp}`（IAdapterPowerManagement + 子设备安装/拆除）、
      `MiniportWaveRT.{h,cpp}`、`MiniportWaveRTStream.{h,cpp}`、`Topology.{h,cpp}`、
      `VirtualClock.{h,cpp}`（合成播放时钟，QPC 换算字节、余数进位不漏拍）、`Guids.cpp`、
      `NewDelete.{h,cpp}`、`AuraVaio.h`、`AuraVaoTables.h`、`AuraPoolCompat.h`。
      **两个 .vcxproj 都只列文件名、不复制源码**，都从 `../src/` 取；
      `TargetName` 均为 `AuraVaioDriver`（INF 的 `SourceDisksFiles` 名要一致）。
      **不链 `stdunk.lib`**：每个对象只继承一条 PortCls 接口链 → 只有一个 IUnknown 子对象，
      QueryInterface 自行实现（无聚合，故抛弃 CUnknown）；只链 `portcls.lib + libcntpr.lib`。

      产物（各轨独立，互不覆盖）：
      `modern/x64/Debug/AuraVaioDriver/` 与 `legacy/x64/Debug/AuraVaioDriverLegacy/`，
      各含 `.sys/.inf/.cat`，`Inf2Cat` 0 error。

### 双轨产物对照（实测）

| | modern | legacy |
|---|---|---|
| 工具链 | WDK 28000 + VS2026 (MSVC 14.51) | EWDK 19041 + VS2019 BuildTools (MSVC 14.27) |
| 目标平台 | Universal | Desktop |
| KMDF | 1.15 | 1.11 |
| OS / 子系统版本 | 10.0 / 10.0 | 10.0 / **6.1** |
| 导入模块 | `ntoskrnl.exe` + `portcls.sys` + `WDFLDR.SYS` | 同左 |
| 输出 | `01_vaio_driver/modern/x64/Debug/AuraVaioDriver/` | `01_vaio_driver/legacy/x64/Debug/AuraVaioDriverLegacy/` |
| Inf2Cat | 0 error / 0 warning | 0 error / 0 warning |

> **legacy 轨的 Win7 设定全部烘焙进 `legacy/AuraVaioDriverLegacy.vcxproj`**
> （`WindowsTargetPlatformVersion=10.0.19041.0` / `TargetVersion=Windows7` /
> `DriverTargetPlatform=Desktop` / `KMDF 1.11` / `TargetName=AuraVaioDriver`），
> 故 `build_legacy.ps1` 不再从命令行覆盖任何属性。实测 link 出的子系统版本为 **6.1**，
> 与 modern 的 10.0 形成对照，坐实降级目标生效。

> **本轮不做（明确排除，已在源码头注登记）**：采集端点、`KSPROPSETID_Audio`
> （音量/静音/峰值表）、`IMiniportWaveRTStreamNotification` 事件通知、
> 7.1 格式矩阵，以及面向 `engine/` 的共享环形缓冲设备接口
> （`GUID_DEVINTERFACE_*`）。本轮验收口径 = **最小可枚举端点**
> （设备管理器能识别 AuraVAIO 为一个可用渲染端点）。

> ⚠️ **Known issue**（`806b44b` 立案）：APO 注册后 audiodg 加载失败（SFX/MFX APO 加载路径），
> 已登记待查。03 全部操作遵循"系统现场可恢复"原则（备份 → 操作 → 验证 → 恢复，
> `88f35aa` 实测干净还原）。

## 环境结论（本机实测）

- Voicemeeter 全家桶已安装（Standard/Banana/Potato exe + Remote32/64 DLL 1.1.1.9）→
  模式 2 可即刻联调；三级自省在本机应三级全通。
- Windows Kits 10（SDK 19041/26100 + **WDK 28000 已装**）→ 用户态全可构建，
  内核态 `01_vaio_driver/modern` 轨已实证 link 通过；安装器与一键脚本存于 `.tmp/wdk-install/`。
- **EWDK 19041 已挂载于 `E:\`**（`E:\BuildEnv\SetupBuildEnv.cmd` 存在）→ `01_vaio_driver/legacy` 轨零安装即可构建；
  换盘符时只需在跑之前 `$env:AURA_EWDK19041 = "<新盘符>\"`。
- 当前 shell 非管理员 → APO 注册/回滚、以及**装载本驱动**（需测试签名）均需另行提权。

## Voicemeeter 版本兼容（bridge/vm_bridge 常驻桥）

- **Remote DLL 定位**：`vb_start` 优先用三级自省检出的安装目录
  （`Uninstall/VB:Voicemeeter*` 注册表 → API 自省 → PE 校验），覆盖标准版/香蕉/
  土豆的默认与自定义安装路径；两条 `Program Files` 默认路径只做兜底。
- **版型未知降级**：edition 未检出（0）时按 8 组预建引擎，泵在运行时按
  `min(nbi,nbo)/8` 钳位 + 空 handle 透传——多建无害，绝不吞声。
- **旧版 Remote**：回调族导出缺失时 note 写 `remote-api-missing r<版本>`，
  UI 设备卡直接显示原因；`VBVMR_Login` 返回值不做断言（各版本语义不同）。
- **采样率/缓冲**：CHANGE 重建只认 `samplerate>0` 的 STARTING（引擎未打开时 VM
  可能先发全零 info），超时用旧采样率续命——任何设备速率组合都成立。
- **总线送达语义**：VB 只给"活着"的总线填 buffer，未路由的总线给空指针
  （EAPO/Element 同症，非我方 bug）；桥对空 buffer 总线直通不吞声，`status`
  的 `grpLive` 掩码逐条标存活，UI 置灰而非灭灯。对无路由总线持续给同一块
  buffer（非零但永不变）时，桥判冻清表头（仅电平，音频路径不动）。
- **0x8889000a 是独占不是失效**：`AUDCLNT_E_DEVICE_IN_USE`（VB 以独占/KS
  方式开着同一端点时，任何 shared 打开都撞墙，重试无用）。排查先看 VB
  侧该设备的打开方式（WDM 共享 vs KS 独占），而不是怀疑端点死了。
- **32 位系统**：本桥为 x64，只能加载 `VoicemeeterRemote64.dll`；32 位 Windows
  下检测报 `found=false`，模式不可用（App 为 x64，无 32 位构建）。
- **已知限制**：`arbmag.string` 走同一字符串通道（编译+镜像+回放），与
  `liveprog.code` 同命运；`liveprog.param1..8` 等数值参数走 `vb_set_param`
  镜像——两者在 CHANGE 重建后都会回来。

## 构建

```powershell
cmake -S core/desktop/windows-drivers -B core/desktop/windows-drivers/out -G "Visual Studio 18 2026" -A x64
cmake --build core/desktop/windows-drivers/out --config Release
```

产物进 `out/`（`**/out/` 已 gitignore），不污染源码树。

## 双轨驱动构建（`01_vaio_driver/`，内核态，独立于 CMake）

> 内核驱动走 MSBuild（依赖 WDK 的 `WindowsDriver.props/targets`、`StampInf`、`Inf2Cat`、签名），
> **不并入**本目录的 CMake；用户态 02/03/04/bridge 仍走上面的 CMake 流程。
> 两条轨都编译 `01_vaio_driver/src/` 里的同一批源码，只是工具链/目标版本不同。

```powershell
# 默认 modern（VS2026 + WDK 28000，Win10 1809+/Win11 x64）
core/desktop/windows-drivers/01_vaio_driver/build_drivers.ps1
core/desktop/windows-drivers/01_vaio_driver/build_drivers.ps1 -Config Release

# legacy（EWDK 19041 + KMDF 1.11，Win7/8/8.1）：先挂载 EWDK 19041 并设环境变量
$env:AURA_EWDK19041 = "<挂载盘符或解压目录>"
core/desktop/windows-drivers/01_vaio_driver/build_drivers.ps1 -Track legacy -Config Release
```

### 构建脚本的三处坑（已修，勿回退）

1. **`Path`/`PATH` 去重不能写在 `try` 里**。两份脚本开头都做环境净化（MSB6001：
   继承环境里同时存在 `Path` 与 `PATH` 时，MSBuild 建的大小写不敏感字典会撞键）。
   但 `Remove-Item env:Path` 在第一个拼写被删掉后会抛 `path-not-found`——
   若还原语句跟在 `try` 内部，`catch` 会**吞掉异常并跳过还原**，`PATH` 直接变空。
   modern 轨用绝对路径调 MSBuild 所以看不出问题，legacy 轨要调 `cmd.exe` 就会
   `CommandNotFoundException`。现改为「先取快照 → 两条 `-ErrorAction SilentlyContinue` 删除 →
   在 `try` 之外还原」，并且 `cmd.exe` 一律走 `$env:SystemRoot\System32\cmd.exe` 绝对路径。
2. **`.vcxproj` 的 XML 注释里不能出现 `--`**（MSB4025）。注释里写破折号请用单个 `-`。
3. **含中文的 `.ps1` 必须存成 UTF-8 *带 BOM***。Windows PowerShell 5.1 读**无 BOM** 的
   `.ps1` 时按系统 ANSI（本机 GBK）解码，中文注释会被拆成非法标记，报
   `MissingExpressionAfterToken` 一类语法错——而且报错位置会飘到别处，极难看出真因。
   `build_drivers.ps1` / `install_driver.ps1` 现已带 BOM；纯 ASCII 的 `build_legacy.ps1`
   不需要。新增脚本请一并检查。

### 跨工具链的池分配（`AuraPoolCompat.h`）

Win10 2004+ 的「标志位池 API」在 `wdm.h` 里整体挂在 `NTDDI_WIN10_VB` 之下。
EWDK 19041 的头文件有个不对称：`POOL_FLAG_*` **常量**在更早的
`#if (NTDDI_VERSION >= NTDDI_WS03SP1)` 块里，Win7 目标下仍可见；但 `POOL_FLAGS`
**typedef** 与 `ExAllocatePool2/3` 一起消失。于是按 Win7 目标编译时，
所有出现 `POOL_FLAGS` 的签名都会 `C2065: identifier not found`。

`AuraPoolCompat.h` 提供单一开关 `AURA_POOL_HAS_FLAG_API`，不满足时把 `POOL_FLAGS`
按现代类型原样补出（`ULONG64`），使**两份源文件、一份代码路径**成立；
`NewDelete.h` 的 `AuraAllocatePool()` 是唯一知道分叉的地方，并在下行分支手工
`RtlZeroMemory`，以对齐 `ExAllocatePool2` 默认零初始化、而 `ExAllocatePoolWithTag`
不零初始化的语义差异。

> 另注：`POOL_TAGGING` 在 19041 的 `wdm.h` 里是无条件 `#define`，
> 因此 `ExAllocatePoolWithTag(type, size, tag)` 在 Win7 目标下仍是真三参内核 API，
> 不会被降成两参宏。

## 装载与卸载（Phase 4 验收 ①：设备管理器识别 AuraVAIO）

AuraVAIO 是 **root 枚举**的软件设备（无硬件），装载链路为：
`pnputil` 把驱动包进 DriverStore → 创建 `Root\AuraVAIO` 设备节点 → PnP 回调
`AddDevice`/`StartDevice` → PortCls 注册 Wave + Topology 两个 KS 过滤器 →
AudioEndpointBuilder 配对成一个渲染端点。

前置条件（**缺一不可**）：

1. **管理员权限**。
2. **驱动已签名**。当前两轨都以 `SignMode=None` 出未签名 `.sys`，只能配合
   `bcdedit /set testsigning on` + 重启，或用测试证书签后导入信任。
   （`AuraVaioDriver.cat` 已由 Inf2Cat 生成，测试签名可直接对它签。）
3. legacy 轨若要在 Win7 上真装，INF 还需要 `[<Service>.NT.CoInstallers]` 段 +
   `WdfCoinstaller01011.dll`（KMDF 运行时不在 Win7 内置）。当前 INF **没有**这段，
   所以 legacy 包只对「已自备 KMDF 1.11 运行时」的机器可直接安装。

`WdfCoinstaller01011.dll` 已由 WDK 自动放进两个包目录，但 INF 没有引用它，
故它目前是惰性的（modern 目标 Win10+ 内置 KMDF，本就不需要）。

```powershell
# 只读体检（任何权限；默认动作）
core\desktop\windows-drivers\01_vaio_driver\install_driver.ps1
core\desktop\windows-drivers\01_vaio_driver\install_driver.ps1 -Track legacy

# 装载 / 卸载（必须管理员 + 已开测试签名）
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File',"$PWD\01_vaio_driver\install_driver.ps1",'-Action','install'
core\desktop\windows-drivers\01_vaio_driver\install_driver.ps1 -Action uninstall -RemoveTestCert
```

`install_driver.ps1` 做的事：体检 → （可选）生成/复用 `CN=AuraDSP Test Signing`
自签证书并签 `.cat` + 导入 `Root`/`TrustedPublisher` → `pnputil /add-driver /install`
→ `devcon install <inf> Root\AuraVAIO` → 复验。
**它不代改启动配置、也不代重启**：`testsigning` 未开时只打印
`bcdedit /set testsigning on` + 重启命令后停下。
默认 `-Action status` 纯只读；`install`/`uninstall` 需要显式指定并要求管理员。

手工等价命令：

```powershell
# 装载（管理员 + 已开测试签名）
pnputil /add-driver core\desktop\windows-drivers\01_vaio_driver\modern\x64\Debug\AuraVaioDriver\AuraVaioDriver.inf /install
# pnputil 只把包装进 DriverStore，不会建 root 设备节点，必须再用 devcon
devcon install core\desktop\windows-drivers\01_vaio_driver\modern\x64\Debug\AuraVaioDriver\AuraVaioDriver.inf Root\AuraVAIO

# 卸载
devcon remove Root\AuraVAIO
pnputil /delete-driver auravaiodriver.inf /uninstall /force
```

验收判据：`设备管理器` 出现 **AuraVAIO Virtual Audio Device**；`声音设置` 的
输出设备列表出现 **AuraVAIO**；`install_driver.ps1` 体检第 [4]/[6] 节中
状态为 `OK`。本机实测（未提权）当前为：包三件套齐全、
**未发现 AuraVAIO 设备**、本机 21 个 OK 音频端点中 AuraVAIO = 0 —— 即"已具备装载条件、尚未装载"。

> **已知缺口（legacy 轨真要装 Win7 时）**：INF 目前没有
> `[<Service>.NT.CoInstallers]` 段与 `WdfCoinstaller01011.dll` 的
> `CopyFiles`/`CoInstallers32` 引用（KMDF 运行时不在 Win7 内置）。
> 当前 INF 是"最小可枚举端点"口径，只保证 Win10+（KMDF 内置）可直接装。
