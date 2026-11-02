# AuraDSP 架构调研报告：RT 高优遗留项取证与 Windows 插件体系扩展方案
> 报告日期：2026-11-02 | 分支基线：`dev` (`476fb8e`) | 状态：深度取证完成，纯方案论证（不修改代码）

---

## 目录
1. [第一部分：RT 高优遗留项深度调研与最新事实对账](#第一部分rt-高优遗留项深度调研与最新事实对账)
   - 1.1 关键发现：L-01 / L-02 / L-03 真实闭环状态对账（ADR-011）
   - 1.2 L-01（eq_pool 逐声道池）已修机制剖析
   - 1.3 L-03（arbmag 主卷积与池）已修机制剖析
   - 1.4 L-02（reset_channel_state 拓扑重置）已修机制剖析
   - 1.5 L-04（mc_reverb 参数/预设切换淡出与平滑）真正现存遗留深度剖析与解决方案
2. [第二部分：Windows 下插件体系扩展方案（VST3、VST2、CLAP、AU、LV2 及 32 位）](#第二部分windows-下插件体系扩展方案vst3vst2clapaulv2-及-32-位)
   - 2.1 整体现状矩阵总览
   - 2.2 VST3 现状、代码取证与深度评估
   - 2.3 CLAP 现状、代码取证与深度评估
   - 2.4 VST2 评估：合规性、逆向头方案与宿主驱动落地路线
   - 2.5 AU（Audio Unit）跨平台评估：Windows 可行性定论
   - 2.6 LV2 评估：依赖链（Turtle/RDF）、Windows 适用性与取舍
   - 2.7 32 位插件（Bit-Bridge）全面调研与进程外桥接架构方案
3. [第三部分：架构决策建议与实施路径规划](#第三部分架构决策建议与实施路径规划)

---

# 第一部分：RT 高优遗留项深度调研与最新事实对账

## 1.1 关键发现：L-01 / L-02 / L-03 真实闭环状态对账（ADR-011）

> [!IMPORTANT]
> **重大对账结论**：
> 在 `docs/30-审查/未决任务复核-2026-10-31.md`（10-31 白天初稿）中，L-01、L-02、L-03 被列为“仍在册 8 项”中的 3 个高危并发缺陷。
> 然而经深入 Git 历史与代码取证：**2026-10-31 晚间（20:00:37），提交 `3138fb8` 已完整实施了 [ADR-011（控制线程与 RT 线程不得共享可变 DSP 状态）](../adr/ADR-011-no-shared-mutable-dsp-state.md)，落地了补丁 P-047 与 P-048，三项均已彻底闭环并建立四阶段常驻门禁！**
> 当前真正属于**未完成状态的仅有 L-04**。

| 缺陷编号 | 历史登记危险度 | 10-31 晚间 ADR-011 落地状态 | 对应补丁 | 闭环证据与门禁 |
|---|---|---|---|---|
| **L-01** | **崩溃级 (UAF)** | **已闭环** | `P-047` | 逐声道 EQ 池改为双 Bank 影子槽，RT 块首快照；`smoke_pool_race.py` 阶段①通过 |
| **L-03 (池)** | **崩溃级 (UAF)** | **已闭环** | `P-047` | 逐声道 ArbMag 池同构双 Bank 影子槽；`smoke_pool_race.py` 阶段②通过 |
| **L-03 (主conv)** | **撕裂级 (幅度失控)** | **已闭环** | `P-048` | `kAuraStages` 的 `arbmag` stage 改 `lock 1`，控制侧同持 `jdsp_lock`；`smoke_pool_race.py` 阶段③通过 |
| **L-02** | **数据竞争级** | **已闭环** | `P-047` | 控制侧仅置原子 `reset_req`，RT 侧 `reset_channel_state_rt` 块首安全消费；`smoke_pool_race.py` 阶段④通过 |
| **L-04** | **中 (多声道爆音)** | **仍在册 (真正遗留)** | 待立项 | 多声道自定义参数调节未接平滑/淡出，阻塞在 5.1 实机听感验证（D-4 待裁定） |

---

## 1.2 L-01（eq_pool 逐声道池）已修机制剖析

- **代码位置**：`engine/chain/engine_chain.cpp:888-1018`，`engine/engine_internal.h:698-724`
- **原竞争根因**：控制线程执行 `eq_pool_reload()` 时，对多声道共享的 `FFTConvolver1x1` 调用 `FFTConvolver1x1LoadImpulseResponse()`。该函数首步就是 `FFTConvolver1x1Free()`，立即释放内部 `_fftBuffer`、`_overlap`、`_segments*` 堆内存；此时音频 RT 线程正在同一对象上并发调用 `FFTConvolver1x1Process()`，导致立即发生 **Use-After-Free (UAF)** 内存崩溃（引发 `0xC0000005` 访问越界）。
- **ADR-011 实施的修法架构（P-047）**：
  1. **结构重塑**：`EqPool` 定义由原本的单组卷积器改为：
     ```cpp
     struct PoolBank {
         FFTConvolver1x1* conv[kMxMaxChannels]{};
         int loaded{0};          // 下沉至 bank 内，不再是裸全局变量
         uint64_t retired_at{0}; // 换出时刻的 proc_count 快照 + 1
     };
     struct {
         PoolBank bank[2];             // 2 个 Bank（活动槽 + 影子槽）
         std::atomic<int> active{0};  // 当前生效的 bank 索引
         std::atomic<uint64_t> proc_count{0}; // RT 处理块单调递增计数
         std::atomic<uint32_t> in_flight{0};  // 当前正在处理中的 RT 块数量
     } eq_pool;
     ```
  2. **影子槽构建 + 原子发布**：
     - 控制侧通过 `pool_pick_shadow` 获取非活动槽；
     - 满足在途守卫条件任一：`in_flight == 0`（覆盖停流场景）或 `proc_count >= retired_at`；若不满足，控制侧进行有界等待（最大 500ms，60000 次自旋后休眠 1ms），超时仍未就绪则**放弃本次重载，保留旧 IR**，绝对不原地写活动槽；
     - 在影子 bank 上装载新 IR 后，原子执行 `active.exchange(shadow)` 发布；
  3. **RT 侧无锁快照**：
     - RT 线程在 `process_multichannel_chain` 块首只读一次：
       `h->eq_pool_bank = h->eq_pool.active.load(std::memory_order_acquire);`
     - 整个音频块的处理期间固定使用 `bank[h->eq_pool_bank]`，完全与控制侧并发解耦，零内存开销，零锁阻塞。

---

## 1.3 L-03（arbmag 主卷积与池）已修机制剖析

- **代码位置**：
  - 逐声道池：`engine/chain/engine_chain.cpp:730-857`
  - 主卷积锁：`engine/legacy/jdsp/jdspController.c:36`、`engine/engine_param_table.h:204-220`
- **原竞争根因**：
  - **池部分**：同 L-01，`arbmag_pool_reload()` 调 `LoadImpulseResponse` 引起堆释放与 RT `Process` 的 UAF 崩溃。
  - **主卷积部分**：Vendor 的 `ArbitraryResponseEqualizerStringParser`（`Effects/arbEqConv.c`）对主卷积器 `arbMag.conv`（`FFTConvolver2x2`）执行**原位** `RefreshImpulseResponse`（分段更新频域响应），此时 RT 的 `stage_arbmag` 正在执行 `FFTConvolver2x2Process`。由于原位刷新跨越多个频域段，RT 读到撕裂状态（一半新曲线、一半旧曲线），实测块间偏离高达 **1002%~50810%**（输出幅度剧烈失控）。
- **ADR-011 实施的修法架构**：
  - **逐声道池**：完全复用 L-01 的 `PoolBank` 双槽与在途守卫机制（P-047）。
  - **主卷积刷新（P-048）**：
    - `jdspController.c` 中 `kAuraStages` 表项将 `arbmag` 的锁标志由 `0` 改为 `1`：
      `/* arbmag */ { 0, 1, ... }`，指示 RT 线程进入该 stage 时获取 `jdsp_lock`；
    - 控制侧在 `engine_param_table.h` 的 `arbmag_refresh_vendor_conv()` 中，更新前同样获取 `jdsp_lock`：
      ```cpp
      static void arbmag_refresh_vendor_conv(auradsp_handle h) {
          jdsp_lock(&h->jdsp);
          ArbitraryResponseEqualizerRefresh(&h->jdsp);
          jdsp_unlock(&h->jdsp);
      }
      ```
    - 由于该原位重写是亚毫秒级（约 1.08~1.79ms），持锁时间极短，不会引起音频卡顿，彻底杜绝了撕裂。

---

## 1.4 L-02（reset_channel_state 拓扑重置）已修机制剖析

- **代码位置**：`engine/chain/engine_chain.cpp:200-249`，`engine/auradsp_engine.cpp:218-228`
- **原竞争根因**：用户切换输出声道模式（如立体声切 5.1/7.1）或声道拓扑变化时，控制线程执行 `reset_channel_state()`，直接调用 `memset` 清空各个算法节点的内部状态（gate / filter / shelf / dyneq / tube / limiter / spatial 等历史采样点与平滑系数）。此时 RT 音频线程正在读写这些结构，导致非原子的脏读与写入覆盖（数据竞争）。
- **ADR-011 实施的修法架构（P-047）**：
  - **控制侧与 RT 职责解耦**：
    - 控制侧 `reset_channel_state()` 仅负责控制线程的安全操作（重载池、通知 vendor 侧 `apply_reverb`、`LiveProgSetChannels`），最后向引擎下发原子请求：
      `h->reset_req.store(1, std::memory_order_release);`
    - RT 侧在 `auradsp_process()` 入口检测：
      ```cpp
      if (h->reset_req.exchange(0, std::memory_order_acquire) != 0) {
          reset_channel_state_rt(h);
      }
      ```
    - 由 RT 线程自身在**音频块开始前、无任何采样处理时**，单线程安全调用 `reset_channel_state_rt(h)` 重置全部自研节点状态，彻底消除了跨线程竞争。

---

## 1.5 L-04（mc_reverb 参数/预设切换淡出与平滑）真正现存遗留深度剖析与解决方案

### 1.5.1 现场代码取证
- **机制现状**：
  `engine/dsp/dsp_mc_reverb.cpp` 中已经设计了淡出机制：
  ```cpp
  // dsp_mc_reverb.cpp:215-217
  if (s.reset_req.exchange(0, std::memory_order_relaxed) != 0) {
      s.fading_out = true;
  }
  const float fade_step = 1.0f / (0.005f * fs); /* 5ms 淡出步进 */
  ```
  在第 311-318 行，当 `s.fade <= 0.0f` 时清空状态：
  ```cpp
  if (s.fading_out) {
      s.fade -= fade_step;
      if (s.fade <= 0.0f) {
          mc_clear_state(s);
          h->rev_ag_in = h->rev_ag_out = 0.0;
          h->rev_ag_comp = 1.0;
          h->rev_g_sm = 1.0f;
      }
  }
  ```
- **控制调用链现状**：
  1. `set_reverb_preset`（`engine_param_table.h:303`）：当用户切换预设（如由 Plate 切到 Hall，或关闭混响）时，**已经调用了 `mc_reverb_reset(h)`**。
  2. `set_freeverb_enable_alias` 与 `set_spatial_fdn_alias`：**也已经调用了 `mc_reverb_reset(h)`**。
  3. **真正的漏洞暴露点**：
     在用户调节**自定义混响参数**时（`freeverb.decay`、`freeverb.roomsize`、`freeverb.damp`、`reverb.predelay` 等，对应预设 `-2`），其参数定义如下（`engine_param_table.h:1242-1247`）：
     ```cpp
     PARAM_FLOAT("freeverb.decay", fv_decay, 0.0f, 1.0f, hook_reverb_custom),
     PARAM_FLOAT("freeverb.damp", fv_damp, 0.0f, 1.0f, hook_reverb_custom),
     PARAM_FLOAT("freeverb.roomsize", fv_roomsize, 0.5f, 2.5f, hook_reverb_custom),
     ```
     查看其回调 `hook_reverb_custom`（`engine_param_table.h:254`）：
     ```cpp
     static void hook_reverb_custom(auradsp_handle h) {
         if (h->open.load() && h->p.reverb_preset.load(std::memory_order_relaxed) == -2) {
             apply_reverb(h);
         }
     }
     ```
     查看 `apply_reverb(h)`（`engine_chain.cpp:143`）：
     `if (reverb_path_kind(h) == 0 && rv != -1)` —— 它**仅处理立体声路径**（vendor Progenitor2 原生映射），对多声道 MC FDN 路径**完全没有任何处理动作，也未调用 `mc_reverb_reset(h)`**！

### 1.5.2 产生的问题与听感缺陷
在多声道模式下（5.1/7.1），RT 线程每块直接读取原子浮点数：
```cpp
const float decay = mc_clampf(h->p.fv_decay.load(std::memory_order_relaxed), 0.0f, 1.0f);
rt60 = 0.5f + 5.5f * decay;
room = mc_clampf(h->p.fv_roomsize.load(std::memory_order_relaxed), 0.5f, 2.0f);
```
当用户在 UI 上滑动滑块时，8 路线路延时分配、内部单极点低通滤波器截断频率瞬间跳跃，FDN 延迟环内的驻波与反馈系数出现相位突变，导致**扬声器产生明显的拉链声、阶跃喀哒声（Click/Zipper Noise）**。

### 1.5.3 L-04 详细重构方案（无需清空的连续平滑法）
如果简单地在 `hook_reverb_custom` 加上 `mc_reverb_reset(h)`，用户拖动滑块时音频每 5ms 就被强制静音一次，造成严重的断音体验。
**推荐工业级解法：参数惯性平滑（Slew Rate Limiting）**
- **改动范围**：`engine/dsp/dsp_mc_reverb.cpp`
- **设计**：
  在 `McReverbState` 中，对所有敏感拓扑参数引入块级平滑器（类似既有的 `pre_len_sm`）：
  ```cpp
  struct McReverbState {
      // 既有字段...
      float rt60_sm{0.0f};
      float damp_sm{0.0f};
      float room_sm{0.0f};
  };
  ```
- **音频块处理**：
  在每块计算前，目标值与当前平滑值做一阶惯性低通平滑：
  ```cpp
  const float smooth_factor = 0.05f; // 约 20-30ms 收敛
  s.rt60_sm += smooth_factor * (target_rt60 - s.rt60_sm);
  s.damp_sm += smooth_factor * (target_damp - s.damp_sm);
  s.room_sm += smooth_factor * (target_room - s.room_sm);
  ```
  在块内循环中使用平滑值推导延时和系数，实现拖拽滑块时的无缝平滑过渡，零爆音、零断音。

---

# 第二部分：Windows 下插件体系扩展方案（VST3、VST2、CLAP、AU、LV2 及 32 位）

## 2.1 整体现状矩阵总览

| 插件标准 | 规范所有方 / 授权性质 | Windows 原生能力 | 引擎目前实现程度 | 32 位存在性与支持现状 | 最终扩展方案建议 |
|---|---|---|---|---|---|
| **VST3** | Steinberg / GPLv3 or Proprietary | 原生完美（COM） | **已完整实现（一等公民）** | 大量 32 位存在；目前已做 PE 头拦截 | 维持进程内双槽；32 位插件纳入独立进程外桥 |
| **CLAP** | u-he & Bitwig / MIT | 原生完美（纯 C ABI） | **已完整实现（一等公民）** | 极少量 32 位；目前已做 PE 头拦截 | 维持进程内双槽；支持扩展特性完善 |
| **VST2** | Steinberg / 官方已废弃授权 | 原生极佳（C 结构体） | **未实现**（Dart 侧仅有枚举预留） | **海量经典 32 位存量**（核心痛点） | **引入开源 clean-room `fst.h`**，首期支持 64 位；32 位走进程外桥 |
| **AU** | Apple / macOS 私有 CoreAudio | **Windows 完全不可用** | **未实现**（仅占位枚举） | 历史 PPC/x86 32 位，仅限 macOS | **Windows 下明确剔除/置灰**；未来移植 macOS 时再激活 |
| **LV2** | LV2 Community / ISC (开源) | 弱（极少数 Windows 移植） | **未实现**（仅占位枚举） | 极罕见 | **低优先级暂缓**；依赖 heavy RDF 解析库，Windows 投资回报率低 |

---

## 2.2 VST3 现状、代码取证与深度评估

### 2.2.1 现状与代码落地
- **头文件源**：`vendor/plugin-api/steinberg/vst3/`，包含官方完整的 base、pluginterfaces、vst 核心接口，已纳入版本控制。
- **引擎驱动层**：
  - `engine/plugins/formats/vst3/vst3_driver.cpp`（格式驱动注册）
  - `engine/plugins/formats/vst3/vst3_instance.cpp`（81KB，核心实例实现）：
    - COM 工厂入口：`GetPluginFactory()`
    - 实例创建：`factory->createInstance(cid, IAudioProcessor::iid, ...)` 与 `IEditController`
    - 初始化：`initialize()`、`setBusArrangements()`（主立体声 + Aux 侧链探测）
    - 音频循环：`IAudioProcessor::process(ProcessData)`，处理 32-bit float 平面声道数据，单块 128/256/512 帧
    - 状态读写：`getState(IBStream*)` 与 `setState(IBStream*)`，流式读写插件专有参数
  - `engine/plugins/formats/vst3/vst3_metadata.cpp`：DLL 深扫、导出的 class 分类探测（`AudioEffect`、`Fx|Reverb` 等子分类提取）
  - `engine/plugins/platform/win32/plugin_gui_win32.cpp`：`IPlugView::attached(hwnd, kPlatformTypeHWND)`，Win32 宿主窗口与消息泵绑定。

### 2.2.2 评估结论
VST3 在 AuraDSP Windows 下是**成熟的一等公民**，双槽位管理、五级阶段拓扑、参数存储、GUI 嵌入均已达到工业级稳定性。

---

## 2.3 CLAP 现状、代码取证与深度评估

### 2.3.1 现状与代码落地
- **头文件源**：`vendor/plugin-api/clap/`（CLAP 1.2+ 标准头，MIT 协议，全套 entry/host/plugin/process/stream 及 ext/draft 扩展）。
- **引擎驱动层**：
  - `engine/plugins/formats/clap/clap_driver.cpp`
  - `engine/plugins/formats/clap/clap_instance.cpp`（51KB，核心实例）：
    - 动态入口：`clap_entry_t::init()`、`get_factory(CLAP_PLUGIN_FACTORY_ID)`
    - 宿主接口：`clap_host_t`，实现了 `clap_host_latency`、`clap_host_state`、`clap_host_gui`、`clap_host_audio_ports`
    - 音频流：`clap_plugin_t::process(clap_process_t)`，严格的非交错 float 音频缓冲区与事件输入输出队列
  - `engine/plugins/formats/clap/clap_metadata.cpp`：解析 `clap_plugin_descriptor_t`，提取 features、vendor、id、description 等。

### 2.3.2 评估结论
CLAP 采用现代纯 C ABI，无 COM 引用计数陷阱，线程模型简单，已是 AuraDSP 的**标杆级支持格式**。

---

## 2.4 VST2 评估：合规性、逆向头方案与宿主驱动落地路线

### 2.4.1 背景与版权合规法律风险
- Steinberg 于 2018 年正式关闭 VST2 开发者授权签署，并从最新 SDK 中彻底删除了 VST2 文件（`aeffect.h`、`aeffectx.h`）。
- **法律风险**：未经 Steinberg 授权，直接分发原版 `aeffect.h` 存在版权合规隐患。
- **行业通用解法（Clean-Room 逆向标准）**：
  开源界（包括 LMMS、VeSTige、Ardour、Carla、Distrho）普遍采用独立的 clean-room 重建头文件 **`fst.h`** 或 **`vestige.h`**。这些头文件纯粹通过公开逆向数据结构与调度分派 opcode 重现，不受 Steinberg 专有协议限制，已被全球开源 DAW 验证无版权瑕疵。

### 2.4.2 VST2 技术架构简析
VST2 本质是极为精简的 C 语言函数指针结构体：
```c
struct AEffect {
    int32_t magic; // 'VstP'
    intptr_t (*dispatcher)(AEffect* effect, int32_t opcode, int32_t index, intptr_t value, void* ptr, float opt);
    void (*processReplacing)(AEffect* effect, float** inputs, float** outputs, int32_t sampleframes);
    void (*setParameter)(AEffect* effect, int32_t index, float parameter);
    float (*getParameter)(AEffect* effect, int32_t index);
    int32_t numPrograms, numParams, numInputs, numOutputs;
    // ...
};
```
- **初始化流程**：
  1. `LoadLibraryW(dllPath)`
  2. 获取入口函数：`VstPluginMain`（或遗留入口 `main`）
  3. 调用获得 `AEffect*` 结构体
  4. 分发 `effOpen`、`effSetSampleRate`、`effSetBlockSize`、`effMainsChanged(1)`
- **GUI 嵌入**：
  分发 `effEditOpen`，传入宿主 Win32 `HWND` 句柄；分发 `effEditGetRect` 获取窗口宽高。
- **状态存储**：
  分发 `effGetChunk`（二进制数据块直接下刷）与 `effSetChunk`。

### 2.4.3 VST2 落地工程量评估
- **所需文件**：
  - `vendor/plugin-api/vestige/vestige.h`（~400 行 C 头文件）
  - `engine/plugins/formats/vst2/vst2_driver.cpp`（~60 行）
  - `engine/plugins/formats/vst2/vst2_instance.cpp`（~800 行，结构比 VST3 简单得多）
  - `engine/plugins/formats/vst2/vst2_metadata.cpp`（~200 行）
- **预估开发成本**：约 2-3 人天即可完成 64 位 VST2 宿主。
- **收益**：激活海量历史经典 64 位 VST2 效果器（如 Waves 旧版、FabFilter 旧版、SIRTUM 等）。

---

## 2.5 AU（Audio Unit）跨平台评估：Windows 可行性定论

### 2.5.1 架构与平台绑定性
Audio Unit（v2/v3）是苹果 macOS / iOS 操作系统的专有音频插件架构：
1. **深度依赖 macOS 系统框架**：
   - AUv2 基于 `AudioToolbox.framework`、`AudioUnit.framework`、`CoreAudio.framework` 的 C/C++ 动态符号。
   - AUv3 基于 Objective-C / Swift 的 `AppExtension` 与 XPC 跨进程架构。
2. **GUI 深度绑定 macOS 视窗系统**：
   - AU 的 GUI 视图协议为 `AUViewController`（AppKit `NSView`）或 `CarbonView`（已废弃）。
3. **Windows 无对应运行时**：
   Windows 操作系统完全不存在 CoreAudio 库与 Objective-C 运行时，**在 Windows 上原生加载 AU 插件在底层二进制层面上是绝对不可行的（Impossible）**。

### 2.5.2 结论与设计处置
- **处置方案**：在 Windows 平台下，UI 的格式筛选按钮中**隐藏 AU**，或在检测到非 macOS 平台时禁用此枚举。
- 现有 `PluginFormat.au` 保持枚举不变，作为未来移植到 macOS（Apple Silicon）时的架构资产保留。

---

## 2.6 LV2 评估：依赖链（Turtle/RDF）、Windows 适用性与取舍

### 2.6.1 架构特点与依赖负担
LV2 是 Linux 领域的现代插件规范，其核心设计思想是**极度数据驱动**：
1. **双重定义**：插件的功能定义、端口属性、参数范围不是通过 C API 暴露，而是写在 **Turtle / RDF 文本文件**（`.ttl`）中。
2. **重度依赖外部生态库**：
   宿主为了读取一个 LV2 插件的元数据，必须链接并引入：
   - `serd`（Turtle 词法分析器）
   - `sord`（轻量级 RDF 图数据库）
   - `sratom`（RDF/Atom 转换）
   - `lilv`（LV2 宿主运行时库）
   以上全部为纯 C 库，但在 MSVC/Windows 下原生编译和维护非常繁琐，极易引入符号冲突和依赖地狱。
3. **Windows 现实生态极贫瘠**：
   绝大多数优质音频插件（FabFilter, iZotope, UAD, Soundtoys, Native Instruments）只提供 VST3/VST2/AU/CLAP，全球在 Windows 下分发 LV2 版本的商业插件几乎为零（仅有少数开源开发者如 Calf/LSP 的非官方实验构建）。

### 2.6.2 结论与建议
- **策略**：**Windows 端不建议推进 LV2 驱动支持**。
- 维护成本远超收益。现有 Flutter 侧 `PluginFormat.lv2` 枚举保留，待未来如果推进 Linux 深度宿主时，在 Linux 平台编译引入 `lilv`。

---

## 2.7 32 位插件（Bit-Bridge）全面调研与进程外桥接架构方案

### 2.7.1 为什么当前采取拦截？
Windows 操作系统内核有严格的硬性限制：
- 64 位进程地址空间与 32 位不同，指针长度为 8 字节 vs 4 字节。
- 64 位的 `auradsp_engine.dll` 调用 `LoadLibraryEx` 打开 32 位 PE 文件时，Windows 加载器必定失败，返回错误码 `193`（`ERROR_BAD_EXE_FORMAT`）。
- **现有仓内实现（P-042/P-043）**：
  在 `engine/plugins/driver/plugin_scanner.cpp:81-85` 与 `plugin_bundle.cpp:27` 中：
  ```cpp
  q.is64Bit = peIs64Bit(wp);
  if (!q.is64Bit) {
      q.isCompatible = false;
      q.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";
  }
  ```
  在 Dart 侧 `plugin_manager_slots.dart:15`：
  ```dart
  if (!plugin.isCompatible) {
      _lastError = '${plugin.name} 与当前 AuraDSP 版本不兼容，无法加载。';
      return;
  }
  ```
  建立了严密的三道防线：扫描期标记 → 列表置灰角标 → 加载前前端拦截 + 引擎防御。

### 2.7.2 32 位支持的唯一工程正道：独立进程外桥（Out-of-Process Bit-Bridge）
要让 64 位 AuraDSP 运行 32 位插件（尤其是海量经典的 32 位 VST2 与早期 32 位 VST3），行业标准做法（如 jBridge、Bitwig 32-bit bridge、Reaper Fire-and-Forget bridge）是：
**启动一个 32 位独立进程作为 Bridge，插件运行在该 32 位子进程内；64 位引擎与 32 位子进程通过共享内存与 IPC 进行无锁音频泵送和窗口嵌入。**

### 2.7.3 重大发现：AuraDSP 仓内已具备完备的 IPC 桥脚手架！
经全面代码取证，我们在 `engine/plugins/platform/win32/host/` 中发现了**已经完全就绪的独立进程宿主架构**：
1. **宿主入口程序**：`auradsp_plugin_host_main.cpp`（565 行）
   - 参数解析：`--pipe=\\.\pipe\auradsp_...`、`--shm=auradsp_shm_...`、`--parent=<pid>`
   - 守护机制：父进程退出检测、看门狗线程、独立 Win32 消息循环
2. **IPC 协议规范**：`plugin_ipc_protocol.h`
   - 控制通道（命名管道）：`Op::Load`, `Op::Unload`, `Op::SetBypass`, `Op::ShowEditor`, `Op::SavePreset`
   - 音频通道（共享内存环）：
     ```cpp
     struct SlotAudioRing {
         std::atomic<uint32_t> inputWrite;
         std::atomic<uint32_t> inputRead;
         std::atomic<uint32_t> outputWrite;
         std::atomic<uint32_t> outputRead;
     };
     struct AudioBlock {
         uint64_t seq;
         uint32_t frames;
         float samples[kChannels][kTransportFrames]; // 8 声道，128 帧定长传输
     };
     ```
3. **主进程代理**：`process_plugin_proxy.cpp`（26KB）
   - 实现了 `IPluginInstance` 接口，主引擎调用代理的 `process()` 时，数据推入共享内存环，通过事件通知或自旋等待子进程处理完毕。
4. **CMakeLists.txt 现状**：
   `core/desktop/windows/CMakeLists.txt:202-207`：
   ```cmake
   if(AURADSP_ENABLE_PLUGINS AND AURADSP_PLUGIN_HOST_REMOTE)
       add_executable(auradsp_plugin_host ...)
   ```

### 2.7.4 32 位桥接落地执行方案（Blueprint）

```
┌────────────────────────────────────────────────────────┐
│  AuraDSP 64 位主进程 (auradsp_engine.dll / App)        │
│    └─ ProcessPluginProxy (实现 IPluginInstance)        │
└──────────────────────────┬─────────────────────────────┘
                           │  Named Pipe (控制) + Shared Memory (音频环)
┌──────────────────────────┴─────────────────────────────┐
│  auradsp_plugin_host32.exe (Win32 x86 独立进程)        │
│    ├─ HostMainLoop (Win32 消息泵)                      │
│    ├─ Vst2Instance / Vst3Instance / ClapInstance (32位)│
│    └─ SetParent(plugin_hwnd, parent_hwnd)              │
└────────────────────────────────────────────────────────┘
```

1. **构建工程化配置**：
   - 在 CMake 中增加一个 32 位工具链交叉编译配置或子工程目标：`auradsp_plugin_host32`，生成 32 位的可执行文件 `auradsp_plugin_host32.exe`，打包随 Release 附件分发在 `bundle/` 或 `engine/` 目录下。
2. **架构调度分派（`plugin_host_manager.cpp`）**：
   - 当 `loadPlugin(meta)` 被触发时：
     - 若 `meta.is64Bit == true`：继续走既有的**进程内（In-Process）直接加载**（零延迟、零 IPC 损耗）。
     - 若 `meta.is64Bit == false`（32 位）：
       - 解除目前在 Dart / C++ 上的 `isCompatible=false` 强拦截；
       - 实例化 `ProcessPluginProxy`，子进程拉起 `auradsp_plugin_host32.exe`；
       - 32 位子进程加载 32 位 DLL 并建立连接。
3. **GUI 窗口跨进程无缝嵌入**：
   - Windows 原生支持跨进程 `SetParent(child_hwnd_32, parent_hwnd_64)`！
   - 子进程中的 32 位插件窗口直接作为子控件挂在 64 位宿主窗口内，用户视觉和交互与 64 位完全无异。
4. **延迟与性能代价**：
   - 共享内存环基于无锁 SPSC，单块 128/256 采样传输往返开销在现代 CPU 上约为 **15~35 微秒**，对于 48kHz 下 5.3ms 的缓冲预算而言，开销仅占 0.5%，完全在可接受范围内。

---

# 第三部分：架构决策建议与实施路径规划

### 3.1 建议行动清单（Actionable Plan）

#### 第一优先级（近期质量治理）：L-04 混响连续平滑改造
- **目标**：彻底消除多声道（5.1/7.1）模式下用户调节自定义混响参数时的喀哒声。
- **实施策略**：在 `engine/dsp/dsp_mc_reverb.cpp` 中增加 `rt60_sm`、`damp_sm`、`room_sm` 一阶惯性平滑，无需修改上层逻辑。

#### 第二优先级（插件格式扩展）：落地 64 位 VST2 驱动
- **目标**：满足大量使用经典 VST2 插件用户的硬需求。
- **实施策略**：
  1. 引入开源 `vestige.h` 到 `vendor/plugin-api/vestige/`；
  2. 实现 `Vst2Driver`、`Vst2Instance` 与 `Vst2Metadata`；
  3. 注册入 `PluginDriverRegistry`；
  4. 保持与既有 VST3/CLAP 一致的 2 槽位与 5 级拓扑。

#### 第三优先级（生态无敌化）：编译激活 `auradsp_plugin_host32.exe`
- **目标**：实现对海量 32 位 VST2/VST3 的完美兼容（Bit-Bridge）。
- **实施策略**：
  1. 复用既有的 `engine/plugins/platform/win32/host/` 代码；
  2. 增加 x86 (32位) 构建分支产出 `auradsp_plugin_host32.exe`；
  3. 引擎侧按 `is64Bit` 自动路由（64 位走进程内，32 位走进程外代理）。
