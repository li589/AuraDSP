# ADR-009 — Windows 底层音频两大交互范式（附加模式与管线模式）与设置面板重构

- 状态：**接受**（2026-10-16）
- 依据：`docs/Windows通用底层音频驱动与四模式架构方案-2026-10-13.md`、`docs/adr/ADR-008-asio-driver-identity-and-architecture.md`、用户真机 FL Studio 联调反馈（2026-10-16）
- 背景：
  1. 过去在 `docs/Windows通用底层音频驱动与四模式架构方案-2026-10-13.md` 与 APP 状态层中，音频处理模式被粗暴平铺为四项：`vaio`（虚拟声卡）、`vbcallback`（Voicemeeter 回调）、`sysapo`（系统 APO）、`asio`（专业 ASIO）。
  2. 随着 ASIO 双线（`04_asio_client` 宿主输出线与 `04_asio_driver` 自研虚拟驱动输入线）落地并在真机 DAW（FL Studio）中实测发声成功，原平铺模型暴露了严重的逻辑冲突与认知割裂：
     - **输入/输出语义不对称**：System APO 是直接挂载到 Windows 音频端点内原地处理；Voicemeeter 模式是挂接在已运行的 Voicemeeter 调音台引擎上回调。两者根本不存在独立意义上的“输入设备”和“输出设备”。
     - **ASIO 的职责割裂**：ASIO Client 本质是**音频输出端（Sink）**（将处理后的声音推给外部物理声卡），而自研虚拟驱动 AuraDSP Driver 本质是**音频输入源（Source）**（由外部 DAW 将音频推入 AuraDSP 处理）。将其合为单选项导致用户无法理解与配置。
     - **硬件异常边界未规范**：蓝牙耳机断开、USB 声卡热拔、硬件 ASIO 独占被占等真实硬件场景缺乏统一定义的降级与恢复契约。

- 决策：
  1. **将音频处理重构为两大顶级交互范式**：
     - **范式一：附加模式（Attachment Mode）**：
       - 特点：原地挂载/宿主引擎接管，无独立输入输出端点选择概念。
       - 包含两项：
         1. **System APO 模式 (`sysapo`)**：附加至 Windows 特定音频端点（物理扬声器、耳机或虚拟设备）的 APO 管道，面板下方提供「目标附加端点」下拉选择、注册状态与一键安装/卸载。
         2. **Voicemeeter API 模式 (`voicemeeter_api`，原 `vbcallback` 更名)**：附加至运行中的 Voicemeeter 调音台引擎，面板下方提供通道条/总线选择、通信状态与延迟监控。
     - **范式二：普通管线模式（Pipeline Mode，独立处理流转）**：
       - 特点：具备显式的「输入端点 (Input Source)」与「输出端点 (Output Target)」，AuraDSP 作为独立引擎在两端之间执行 17 项 DSP 处理。
       - **输入设备下拉选框（Input Source）**：
         - **WASAPI 采集**：物理麦克风、Line-in、系统立体声混音 (Stereo Mix)；
         - **AuraVAIO 虚拟输入**：虚拟播放端点（系统各应用播放至此，由 AuraDSP 获取）；
         - **AuraDSP Virtual ASIO Driver**：作为专业 DAW（FL Studio、Cubase、Reaper 等）的低延迟输入源，展开区显示 DAW 握手状态、协商采样率、缓冲大小与活动指示灯。
       - **输出设备下拉选框（Output Target）**：
         - **WASAPI 物理渲染**：扬声器、耳机、USB DAC、蓝牙耳机；
         - **AuraVAIO 虚拟输出**：虚拟录制端点（供 OBS、直播推流、录音软件拾取处理后音频）；
         - **ASIO Client 外部硬件驱动**：外部专业物理声卡输出（列出检测到的 Focusrite、RME、Yamaha 等硬件驱动），实现“DAW 经虚拟驱动注入 -> AuraDSP 处理 -> 物理专业声卡硬输出”的工业级闭环。

  2. **硬件生命周期与异常防御规范（Real-world Robustness）**：
     - **设备热拔与断开（以蓝牙为例）**：
       - WASAPI 渲染端挂载 `IMMNotificationClient` 设备监听；
       - 检测到当前输出设备不可用时，流循环执行原子平滑降增益（Mute）防止爆音；
       - 自动平滑退避（Fallback）至当前系统的默认音频输出设备；
       - UI 弹出琥珀色警告 Banner 提示，设备重连后支持无缝恢复。
     - **设备独占冲突（Exclusive Mode Lockout）**：
       - 输出端若选择 ASIO Client 硬件驱动，且已被第三方独占占用时，捕获错误码并在 UI 显示“设备已被独占占用”，禁止死锁轮询，提示切换设备。
     - **时钟与采样率不对齐（Clock Drift & Resampling）**：
       - 输入端（如 DAW 48kHz）与输出端（如蓝牙 44.1kHz）速率不同步时，流管线内部启用自适应多项式/Sinc 重采样器，平滑处理时钟漂移。
     - **虚拟端点未消费提示（Unconsumed Virtual Sink）**：
       - 当输出选为 AuraVAIO 虚拟端点时，UI 明确标注“虚拟声卡输出中（需录音/直播软件接入才可收听）”，并提供可选的“本地监听镜像（Monitor Mirroring）”选项。

  3. **数据模型向后兼容设计**：
     - 新建结构化模型：
       ```dart
       class AudioSetup {
         String category;       // 'attachment' | 'pipeline'
         String attachmentMode; // 'sysapo' | 'voicemeeter_api'
         String pipelineIn;     // 'wasapi' | 'vaio' | 'asio_driver'
         String pipelineOut;    // 'wasapi' | 'vaio' | 'asio_client'
       }
       ```
     - 存量配置 `config.audioMode` 保留双向映射：
       - `sysapo` <-> `attachment/sysapo`
       - `vbcallback` <-> `attachment/voicemeeter_api`
       - `vaio` <-> `pipeline/vaio`
       - `asio` <-> `pipeline/asio_client`
     - 确保任何旧版本存档升级至新版后 100% 平滑平移，不丢设置。

- 后果：
  - 彻底理清了底层驱动的职责边界，前端 UI 层次井然有序；
  - ASIO Client（输出）与 ASIO Driver（输入）各归其位，功能逻辑自洽；
  - 系统具备应对蓝牙掉线、独占冲突、时钟不对齐的弹性韧性。
