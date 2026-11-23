# r65 细节方案：ASIO 遥测逐声道 / VB 双修 / MilkDrop 内置预设（2026-11-23）

user 裁定（2026-11-23 16:57）：① ASIO 完整修复；② VB 甲乙全修、
乙的次级嫌疑也修；③ 两项修完再做 2×2（S1 已先行落码
`f825c4fa`，S2 起排在本轮三修之后）；④ MilkDrop 先修内置预设
内容，能修的先修；若需 .milk 文件，后续扩展 resources 资源包
并默认设定 milk 预设位置（登记为后续项，见 §四-4）。

三修同轮发行 r65（与 2×2 S2–S5 同包，发行段在 2×2 计划 §七
S5）。诊断证据均已回源码定罪，见各节所引 file:line（仓库
`b353f5c5` 基线）。

## 一、ASIO 遥测逐声道峰值（#4 完整修复）

定性：DAW 内引擎逐声道处理、逐声道回录均正常；遥测块只有
peakIn（字面 ch0/1）/ peakOut（折叠立体声单值），Dart 读者复制
成左右两格且声道数写死 2。开发机 REAPER 便携版 ini 实查
asio_input/output 范围 0–7，用户配置无误。

| 段 | 内容 |
|---|---|
| A1 契约头 | `04_asio_driver/AsioDriverShared.h`：块尾追加 `float peakInCh[8]; float peakOutCh[8];`（偏移 520，旧偏移全不动，照 ApoShared 尾加先例）；`ASIO_DRIVER_TELEMETRY_VERSION` 2→3；static_assert 钉旧偏移 + 新 sizeof（584）≤ 4096 |
| A2 驱动写者 | `AuraAsioDriver.cpp`：峰值循环（:724-740）扩逐声道——入取 `m_interleavedIn[i*ch+c]`、出取折叠前 `m_proc[i*ch+c]`；旧 peakIn/peakOut 语义原样保留（面板兼容）；块初始化 version 改**无条件写**（:463-466 既存块残留旧版本号的坑同修） |
| A3 桥核对 | `bridge/asio_bridge/AsioBridge.cpp`（:584-619）共用同一头：映射长度按 sizeof 自增、版本上限随宏——预计零逻辑改动，核对后随包重编 |
| A4 Dart 读者 | `audio_isolate_asio.dart`：版本上限 2→3；v≥3 时 chLevels 取 `peakOutCh[0..dawCh)` 换算 dB、chCount = dawCh（钳 2..8），l/r 仍取折叠 peakOut；v2 回落今日立体声合成；断流清零帧（_sendStaleZeroViz）改用最后已知 dawCh，不再写死 2 |
| A5 UI | 零改动：home_page/state_events 已按 vizChannelCount/vizChannelLevels 渲染至 8 声道，四十六轮显示钳自动生效 |
| A6 冒烟 | `smoke_asio_telemetry_contract.py`：版本字面 2→3 + 新字段存在性；`smoke_asio_multichannel.py` 扩判别（**本症状回归**）：6ch 下只给 ch4 送信号 → 断言 peakOutCh[4] > 阈值、其余声道 ≈0、旧 peakOut 仍 >0 |

兼容：新 App + 旧驱动（v2）走回落零回归；旧 App + 新驱动（v3）
读者版本检查按块缺席处理（诚实显示 DAW 不在场），同 Setup 同版
发行下错位窗口仅限非常规半装。驱动重编/签名走 pack driver 门。

验收：宾机 REAPER 7.1 逐声道测试音 → 主页逐格独立亮灭；
B14 听辨可顺带以显示复核。

## 二、VB 双修（#1 甲 + 乙，含乙次级嫌疑）

### 乙主修（确定性 bug，一行量级）

`bridge/vm_bridge/VmBridge.cpp` 的 `vb_set_param` 影子更新块
（:1776-1779）只处理 spatial 两参数，漏 `channels.mode`：每次
vb_start 清零后泵影子恒为矩阵（0），引擎已是离散（1），procCh<8
时泵先折叠、引擎再逐声道处理已折叠信号；procCh=8 折叠分支被门
挡住故唯独 7.1 正常。

- 修：影子块补 mode 分支（与 count 专用通道同式，
  `g_b.ctx.chanMode = (iv == 1) ? 1 : 0`）。会话回放逐参数走同一
  setParam 路径，启动即对齐，不需另改回放。
- 冒烟：扩 `smoke_vm_pump.py` 或新增 VB 桥契约冒烟，断言
  vb_set_param 含 channels.mode 影子分支。

### 乙次级（gate/idle 只看主对）

`VmPumpCore.h`：门控取峰 `gateInPeak` 只自主对 FL/FR（:431），
idle 的 inSilent 只判主对（:633）——离散逐声道测试只放高声道
单音时整组被误判静音：SilenceGate hold 到期清零整组、3 秒转
idle 直通（DSP 被绕过），表现为声道消失。

- 修：gate 输入峰值与静音判据改按**本组工作声道映射槽**取总线
  峰值（BusChForSlot(procCh, ·) 的像集合，procCh=2 时即主对，
  行为与今日一致）；idle 累计同口径。
- 纪律：VmPumpCore.h 是演进本，`02_voicemeeter_client/
  VmAudioCallback.cpp` 是同源冻结参照——回调语义变更两处同步
  改，以 `smoke_vm_pump.py` 为准绳全过。

### 甲（电平残留，方案①：纯显示层）

机理：Voicemeeter 停播后持续给出同一块冻结缓冲，引擎无限重
处理、viz 帧不断流，两道清屏看门狗（isolate 1.5s 补零、state
3s 静默清屏）永不触发；泵内冻结防御只压状态面峰值、不管 viz。

- 修：`VmBridge.cpp` 的 `vb_viz_read`（:1826-1843）在「热组冻结」
  （泵既有 sigSame 超 frozenAt 阈）或「ctx.frames 超 ~1s 未推进」
  时改发 SilentVizEmitter 静音帧（复用既有补帧口径）；音频路径
  与「冻结不动音频」的既有裁定不碰。
- 冒烟：VB 桥契约冒烟断言 vb_viz_read 含冻结/停滞判据与静音帧
  分支。

## 三、MilkDrop 内置预设（#5b 先修内容）

定性：真实 .milk 文件全好（开发机 tryptonaut 包 1226 个实测
6 个依次加载全成功、帧差 27–82）；坏的是三个内置预设——
`builtin:` 伪路径被原生桥 loadPreset 明文拒绝，且 parseFile
不解析 builtin id，三个预设塌成同一套默认参数（waveMode 0）。

| 段 | 内容 |
|---|---|
| M1 真文件 | 按三只内置的既定名义与参数（Cosmic Warp decay .97/zoom 1.05/wave 2、Bio Pulsar .95/1.02/0、Neon Vortex .98/1.08/1）各写一份**真 .milk**（preset 头参数 + per_frame/per_pixel 方程 + 波形设置，内容互异），置 `assets/milkdrop/`，pubspec 登记 |
| M2 落盘解析 | 启动时把三份资产释放到用户数据目录 `milkdrop_builtins/`（版本戳比对、已存在同版跳过；落点合「用户数据文件夹」规矩）；`MilkdropPreset` 增单一解析口：`builtin:` id → 落盘真实路径。viewport 加载、dispatcher 选预设、HUD/抽屉显示三处统一走解析口 |
| M3 回落诚实 | 原生不可用（非 Windows/桥缺失）走 Dart 画笔时，parseFile 对 builtin id 直接返回**声明参数**（不再塌默认）——画笔按各自 waveMode/decay/zoom 渲染，三只互异 |
| M4 验证 | 桥运行时冒烟扩：加载三只随包 .milk 并断言两两帧差 > 1.0（与 tryptonaut 实测同法）；Dart 测试断言解析口三 id 均映射到存在文件且参数互异 |

## 四、衔接与后续

1. 顺序：§一 → §二 → §三 → 2×2 S2–S5 → 统一门禁 → r65。
2. S1（驱动回写环）已落码 `f825c4fa`，开发机验证构建在 scratch
   副本上进行（克隆顶有 user 自己的 promo 提交 `add8f4f4`，不
   动）；三修动工后与 S2 起的同步改走同一 scratch/合并口径，
   发行前再定克隆同步方式。
3. #5a 粒子龙卷风着色器迭代不并入本轮判读链，排 r65 后目检轮。
4. **后续登记（user 2026-11-23 裁定方向）**：resources 资源包
   扩展 MilkDrop 预设库（版本线从 resources 规矩），App 默认
   milk 预设位置指向资源包预设目录；本轮 M1 的三只内置是种子
   内容，资源包就绪后内置可与其合并口径。
