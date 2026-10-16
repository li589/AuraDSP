# ADR-008 — AuraDSP 自研虚拟 ASIO 驱动（Driver 线）定名、COM 架构与分期实施路线

- 状态：**接受**（2026-10-16）
- 依据：`docs/20-执行/ASIO双线开发规划-2026-10-15.md`、Steinberg ASIO SDK 2.3.4 GPLv3 路线、`04_asio_client/README.md`
- 背景：
  AuraDSP 目前已完成 ASIO Client 线（宿主端，以宿主身份驱动硬件声卡或第三方 ASIO 设备）以及 Mode 1 AuraVAIO 虚拟声卡模式。为了让外部专业宿主（DAW，如 FL Studio、Cubase、Reaper、Ableton Live）能直接将音频低延迟注入 AuraDSP 进行全局 DSP 处理与监听，需开展 **Driver 线**（即自身作为虚拟 ASIO 驱动提供给 DAW 打开）。
- 决策：
  1. **驱动定名与商标合规**：
     - 严格遵守 Steinberg ASIO Usage Guidelines（严禁侵权使用 ASIO 注册商标作为产品主商标）。
     - 驱动对外显示名及注册表 Description 定为 **`AuraDSP Driver`**（在 DAW 设备选择列表中显示为 `AuraDSP Driver`）；COM 注册键为 `HKLM\SOFTWARE\ASIO\AuraDSP Driver`。
     - CLSID 分配固定 GUID：`{4B617572-6144-5350-4153-494F44727631}`（ASCII 语义：`AuraDSPASIODrv1`）。
  2. **工程位置与分层边界**：
     - 统一归入模式 4 驱动域，单开目录 `core/desktop/windows-drivers/04_asio_driver/`。
     - 属性为 COM In-Proc Server DLL（`auraasio_driver.dll`），导出 `DllGetClassObject`, `DllCanUnloadNow`, `DllRegisterServer`, `DllUnregisterServer`。
     - 严禁将桥（bridge）或 DSP 算法耦合进驱动目录；音频处理委托动态加载的 `auradsp_engine.dll`，音频输出可路由至 WASAPI 物理端点、AuraVAIO 或 Voicemeeter 总线。
  3. **架构实现选择（Clean-Room 现代 C++20）**：
     - 摒弃 SDK 样例中 1996 年旧式 DirectShow/MFC `combase` 宏体系与静态锁，采用与 `03_system_apo` 同款的极简现代 C++20 COM 实现：
       - `AsioClassFactory`：标准 `IClassFactory` 派生，管理单例/类实例引用计数与生命周期。
       - `AuraAsioDriver`：直接继承 `IASIO`（`asiosys.h` / `iasiodrv.h`），实现 21 个标准虚函数。
  4. **分期推进顺序**：
     - **P1**：COM 骨架构建、自注册/反注册（`regsvr32` 与代码内注册）、宿主能力协商接口（`init/getChannels/getBufferSize/canSampleRate/getSampleRate`）、注册表对账与自动化冒烟测试（DAW 与 CLI 探测均能正确枚举并握手，已通过）。
     - **P2**：双缓冲分配（64 字节对齐）、高精度 MMCSS 时钟线程驱动 `bufferSwitch` 直通发声与 WASAPI 物理渲染汇对接（已通过）。
     - **P3（进行中）**：`auradsp_process` 动态接入与参数/旁路控制。
     - **P4**：主流 DAW（FL Studio 等）实机矩阵验证与长效稳定性测试。
     - **P5**：安装打包与免提权一键配置。
- 后果：
  - 驱动线正式立项并在规范体系中固化；
  - 保持 zero-DSP 分离原则；
  - DAW 可无缝将音频通过 ASIO 协议推入 AuraDSP。
