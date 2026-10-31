# AuraDSP 空间音效与动态压限器深度修复与重构执行计划

> **目标版本**：AuraDSP v1.3.0  
> **核心导向**：彻底解决用户反馈的五大核心痛点——动态压限器参数底层缺失、示波器偶尔停滞、空间音频卡片调参/开启时自动折叠关闭、效果器调参伴随剧烈音量变化（滑块变音量调节器）、空间图示“AI 简陋感”。  
> **工程规范**：严格执行全站 FFI RT-Safe 规则、无工程黑话去工程师化文案、Flutter analyze 0 警告、全量测试 100% 通过。
>
> **实施状态（2026-10-18 复核）**
> - 阶段一（7 频带 comp 参数 + UI）：✅ 引擎 `comp.freq1..7` / `comp.gain1..7` 已接线；`comp.threshold`/`comp.ratio` 为 UI 宏观参数，映射到分带 gain，不是独立 ABI 参数。
> - 阶段二（Ticker 示波器）：✅ `comp_card.dart` 已用 `Ticker` 驱动衰减；GR 计量由 `gain_reduction_meter.dart` 承载。
> - 阶段三（空间卡自闭/文案）：✅ `resetStereoWiden()` 不再关开关；`isSpatialReverbOn` 与自定义预设解耦。
> - 阶段四（恒能量/等响）：✅ `dsp_spatial.cpp` 等能量归一化 + 2ms 平滑；`dsp_freeverb.cpp` 干湿等能量；`stereoEnhancement.c` 平滑补偿。
> - 阶段五（空间/混响可视化）：✅ `spatial_card.dart` 全息声场、`reverb_card.dart` 声学面板已重绘。
> - 遗留：本文中 `engine/chain/engine_chain.cpp#L205` 等旧行号为历史定位，阅读时以当前文件为准。

---

## 一、 核心痛点与技术根因深度解剖

### 1. 动态压限器缺失参数调节底层与 UI
- **底层现状**：在 [`engine_chain.cpp:205`](file:///d:/temp_desktop/Proj/JamesDSP/engine/chain/engine_chain.cpp#L205) 中，底层写死了 `CompressorSetGain(&h->jdsp, 0, 0, 0);`。
- **机理分析**：JamesDSP 的动态压限器底层是 7 频带频域动态压扩器（`NUMPTS_DRS = 7`，默认中心频点：`95, 200, 400, 800, 1600, 3400, 7500 Hz`）。`CompressorSetGain` 接收各频点的频率与压扩增益（`-1.2 ~ +1.2`，正值为动态向上扩展，负值为向下压缩限幅）。由于 AuraDSP 原引擎参数表完全未暴露频段中心频率与增益压限值，导致用户完全无法修改压限幅度和频率！
- **UI 现状**：[`comp_card.dart`](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/effects/comp_card.dart) 目前仅有时间常数一个主滑块和两个下拉框，没有提供多频段压限均衡或总压缩强度的直观调节控件。

### 2. 压限器示波器偶尔停滞冻结（依然有声音）
- **根因分析**：
  1. [`comp_card.dart:134`](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/effects/comp_card.dart#L134) 中 `_CompressorTransferScope` **仅**监听了 `Listenable.merge([model.levelL, model.levelR])`，未监听 `model` 自身变化；
  2. 视觉衰减跟踪算法（Ballistics）是在 `build()` 内部计算的：
     ```dart
     _smoothGr = _smoothGr * 0.85 + targetGr * 0.15;
     ```
     当音频电平恒定、或处于静音、或因缓冲流波动导致电平值浮点未变时，`ValueNotifier` 会抑制通知，`build()` 不再被触发，`_smoothGr` 就会永远停留在上一帧的位置！即使依然在播放，由于电平值没有跳变，图示立刻表现为“停滞冻结”。
  3. 缺少独立的硬件 VSync / `Ticker` 驱动的真实时间衰减步长。

### 3. 空间音效面板效果器一打开/调参就自动关闭
- **根因分析**：
  1. **双击/归零误关开关**：例如在 [`state.dart:2222`](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/core/state.dart#L2222) 的 `resetStereoWiden()` 内部，竟然硬编码了 `stereoOn = false;`！用户双击重置滑块时直接将开关关闭，而卡片绑定了 `collapsed: !model.stereoOn`，导致整张卡片瞬间缩回自闭；
  2. **混响开关状态判断脆弱**：`isSpatialReverbOn` 定义为 `reverbPreset >= 0 || fvOn`。当在子卡调自定义滑块时触发 `selectReverbPreset(-2)`，如果在异步流中 `fvOn` 未原子就绪，`isSpatialReverbOn` 瞬间判定为 false，卡片立刻收起；
  3. **防抖全量回读（Readback）覆盖竞态**：[`state.dart:1055`](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/core/state.dart#L1055) 在调参 500ms 后触发 `scheduleReadback()`，引擎 `getParams` 返回所有参数。若底层某模块在特定模式下未能持久写入（或默认值为 0），回读事件就会将 UI 的开关变量强行改回 false，造成用户“一调参数，过半秒卡片就自己关闭”的诡异手感；
  4. **嵌套卡层级与文案混乱**：空间面板包含了空间主体、混响、脉冲、串扰、Haas、立体声 5 个大子卡，彼此的声学定位缺乏清晰说明，部分文案生硬。

### 4. 调音效伴随剧烈改变音量（滑块感觉像音量调节器）
- **根因分析**：
  1. **空间音频 HRTF 上混能量超载**：[`dsp_spatial.cpp:113-145`](file:///d:/temp_desktop/Proj/JamesDSP/engine/dsp/dsp_spatial.cpp#L113-L145) 将立体声上混为 5 声道，近耳直达声、远耳延迟声、中置声全都是无归一化直接 `+=` 累加，再加上早期反射 `eL, eR` 和高频双二阶峰值，导致信号总能量暴增 +8dB ~ +10dB！虽然有慢速 AGC，但 AGC 时间常数极长（0.05/0.1），用户拉动滑块时音量忽大忽小、剧烈漂移；
  2. **立体声展宽 (Stereo Widen) 增益突变**：[`stereoEnhancement.c:21-25`](file:///d:/temp_desktop/Proj/JamesDSP/engine/legacy/jdsp/Effects/stereoEnhancement.c#L21-L25) 的增益公式在 `mix=0.5` 处硬生生放大了 2.0 倍（+6dB），在 `mix=0` 与 `1.0` 处又是 1.0 倍，拉滑块就像在坐音量过山车；
  3. **混响 (Freeverb) 直达声未衰减**：[`dsp_mc_reverb.cpp`](file:///d:/temp_desktop/Proj/JamesDSP/engine/dsp/dsp_mc_reverb.cpp)（原 `dsp_freeverb.cpp:89`，WP1 后并入该文件） 直达声 `dryG` 在预设中恒为 1.0，湿声直接加上去，缺乏专业的恒能量交叉淡入淡出（Constant-Power Crossfade $\cos/\sin$），越加混响整体音量越响。

### 5. 空间音频图示过于“AI 化”、简陋不优雅
- **根因分析**：
  1. 现有的极坐标雷达、五角星式发声点、八根彩色火柴棒早期反射，缺乏声学逻辑与现代工业设计感，像是用基本画笔勉强堆凑出来的 HUD；
  2. 3D 线框盒子缺少真实声学空间（反射面、高频空气吸收吸收率、直达声波阵面与混响尾部微粒扩散感）的物理质感；
  3. 缺乏看齐 Apple Spatial / Dolby Atmos / Flux:: Spat 的极简、优雅的微光几何与物理声场射线。

---

## 二、 总体架构与重构设计方案

```mermaid
graph TD
    subgraph UI Layer [UI 层 (Flutter)]
        CompCard["动态压限卡片<br/>(总阈值/比率 + 7频带压限曲线 + Ticker衰减)"]
        SpatialCard["空间音频全息舞台<br/>(极简商业级声像锥 + 扩散微粒 + 房间声学)"]
        SubCards["解耦子卡区<br/>(混响/脉冲/串扰/Haas/立体声 · 防自闭状态机)"]
    end

    subgraph State Layer [状态与通信层 (Dart Isolate)]
        AppModel["AppModel 状态管理<br/>(防抖回读隔离 · 杜绝误置 false)"]
        AudioIso["AudioIsolate 管道<br/>(7频段参数下发 · 双向同步)"]
    end

    subgraph Engine Layer [C++ 核心引擎 (RT-Safe)]
        ChainCPP["engine_chain.cpp<br/>(CompressorSetGain 真实参数对接)"]
        CompDSP["dynamic.c FFTCompander<br/>(7 频带 PCHIP 频域动态压扩)"]
        SpatialDSP["dsp_spatial.cpp<br/>(恒能量等功率归一化 1/√N)"]
        StereoDSP["stereoEnhancement.c<br/>(平滑增益补偿 · 消除+6dB突变)"]
        FreeverbDSP["dsp_freeverb.cpp<br/>(恒能量 Equal-Power 交叉淡入淡出)"]
    end

    CompCard --> AppModel
    SpatialCard --> AppModel
    SubCards --> AppModel
    AppModel --> AudioIso
    AudioIso --> ChainCPP
    ChainCPP --> CompDSP
    ChainCPP --> SpatialDSP
    ChainCPP --> StereoDSP
    ChainCPP --> FreeverbDSP
```

---

## 三、 分阶段实施计划

### 阶段一：动态压限器底层参数支持与多频段控制 (C++ + FFI + State)
1. **引擎参数表扩展 (`engine_param_table.h`)**：
   - 增加 7 个频带中心频率：`comp.freq1` ~ `comp.freq7`（默认 95, 200, 400, 800, 1600, 3400, 7500 Hz，范围 20~20000 Hz）；
   - 增加 7 个频带压扩增益：`comp.gain1` ~ `comp.gain7`（默认 0.0，范围 -1.2 ~ +1.2）；
   - 增加全局压限阈值 `comp.threshold`（-48 ~ 0 dB）与全局压缩比 `comp.ratio`（1.0 ~ 20.0），支持宏观一键压缩。
2. **底层生效与管线接入 (`engine_chain.cpp`)**：
   - 在 `apply_comp(h)` 中构造 `double freqs[7]` 与 `double gains[7]`；
   - 结合全局 threshold/ratio 与分带偏移计算实际压扩系数，调用：
     ```cpp
     CompressorSetParam(&h->jdsp, h->p.comp_timeconstant.load(), h->p.comp_granularity.load(), h->p.comp_tfresolution.load(), 0);
     CompressorSetGain(&h->jdsp, freqs, gains, 1);
     ```
3. **Dart FFI 与参数映射 (`param_schema.dart`, `state.dart`, `audio_isolate.dart`)**：
   - 注册 14 个分带参数及全局压限参数，建立回读与下发管道。

### 阶段二：压限器示波器停滞彻底根治与 UI 交互升级
1. **独立物理时钟（Ballistics Ticker 驱动）**：
   - `_CompressorTransferScopeState` 混入 `SingleTickerProviderStateMixin`；
   - 创建由真实 VSync 驱动的 `Ticker`，以毫秒为时间步计算对数释放衰减：
     ```dart
     final dt = elapsed.inMicroseconds / 1000000.0;
     final decayRate = math.exp(-dt / (model.compTimeconstant.clamp(0.02, 0.5)));
     _smoothGr = _smoothGr * decayRate + targetGr * (1.0 - decayRate);
     ```
   - 监听 `model` 变化与电平变化，当电平恒定或无声音时，平滑回弹至 0.0 dB 并自动暂停 Ticker（0% CPU 开销），彻底根治“图示卡住停滞”现象。
2. **7 频带动态压限曲线与宏观阈值 UI**：
   - 重新设计 `_CompressorCard`，增加宏观压缩阈值（Threshold）与压缩比（Ratio）滑块；
   - 在高级面板内提供 7 频带压扩均衡曲线交互视图或分频滑块组，让用户可自由调节各频段的压缩量和频率分界点。

### 阶段三：空间音效面板自闭 Bug 根治与文案体系重构
1. **根治开关意外关闭与折叠**：
   - 移除 `resetStereoWiden()` 中恶意的 `stereoOn = false;`，双击滑块仅重置参数，坚决不关开关；
   - 重构 `isSpatialReverbOn` 与 `selectReverbPreset`，彻底解耦预设切换与开关生命周期，确保调自定义参数时卡片绝不缩回；
   - 在 `scheduleReadback()` 与 `_onMessage` 建立保护锁：用户主动操作引发的参数变更，在防抖窗口内禁止被引擎旧镜像覆盖关停。
2. **重构空间音效文案体系**：
   - 全面梳理并润色空间面板各卡片文案（杜绝技术代号与不自然翻译），采用专业音乐与声学用语：
     - `空间音频` -> 沉浸式双耳声场与扬声器虚拟化；
     - `串扰消除` -> 耳机头中效应消除与音箱自然声场重塑；
     - `Haas 环绕` -> 空间优先效应微延迟展宽；
     - `立体声扩展` -> 频带差异化立体声开阔度；
     - `混响` -> 物理声学空间环境混响。

### 阶段四：全站效果器恒能量与等响度增益级平衡
1. **空间音频 HRTF 上混恒能量归一化 (`dsp_spatial.cpp`)**：
   - 重新计算 5 扬声器分流系数，引入等功率因子 $1 / \sqrt{N}$：
     ```cpp
     const float norm = 1.0f / sqrtf(1.0f + 0.5f * center * center + 1.0f + 0.49f + 0.49f);
     ```
   - 保证开启空间音频或调节宽度/中置时，总体能量均方根保持严格一致；
   - 优化 AGC 平滑系数，消除拖动滑块时音量抽动。
2. **立体声扩展平滑等响度修正 (`stereoEnhancement.c`)**：
   - 修正 `mix` 从 0 到 1.0 时的增益曲线，引入平滑等功率补偿函数，彻底消除在 `mix=0.5` 附近的 +6dB 突跳。
3. **混响恒能量干湿比混合 (`dsp_freeverb.cpp`)**：
   - 引入正弦/余弦恒能量法则：
     ```cpp
     const float mix = h->p.fv_wet.load();
     const float dryG = cosf(mix * (kPiF * 0.5f));
     const float wetG = sinf(mix * (kPiF * 0.5f)) * 0.8f;
     ```
   - 无论用户如何拉大混响比例，总声能恒定，再也不会有“调混响就是在调音量”的错觉。

### 阶段五：空间音频全息声场图示重塑（去除 AI 简陋感）
1. **重构 `_SpatialStagePainter`（看齐 Apple Spatial / Dolby Atmos 标杆）**：
   - 废除生硬的极坐标与彩色火柴棒；
   - 绘制高精度**微光双耳听音区**（精美的人耳指向弧线与微弱方位感知线圈）；
   - 绘制**动态声场波导面**（根据 width 展开的平滑微光渐变波束，边缘做高斯软化）；
   - 绘制**声学脉冲微粒云（Acoustic Particle Diffusion）**，用有机扩散的微粒密度和透明度表现早期反射与房间大小，兼具高级感与真实声学物理意义。
2. **重构 `_Freeverb3DPainter`（极简声学透视）**：
   - 去除粗糙的线框盒子，改用精细网格透视地面与半透明声学反射切面，随 roomSize 呼吸式伸展，极具商业工作站质感。

---

## 四、 风险分析与验证策略

| 风险点 | 应对措施 |
| :--- | :--- |
| 压限器底层 7 频带参数增加导致 FFI 结构体/消息通信包膨胀 | 使用已有的原子参数表系统 `PARAM_FLOAT`，与现存 100+ 参数统一管道，零结构体 ABI 破坏。 |
| Ticker 驱动示波器可能增加后台耗电 | 仅在卡片处于展开状态（`!collapsed`）且有有效 GR 衰减时运行，当 GR 回落至 0 或卡片折叠时自动 `stop()`，GPU/CPU 开销为 0。 |
| 等功率混合修改可能影响老用户的混响听感 | 保持默认预设（如大音乐厅、房间）的整体听觉平衡，消除暴音与音量突跳，实际带来更平滑的听感升级。 |
| 全量测试破坏 | 本地 257 项全量测试必须保持 100% 通过，并为新参数与状态机补充专项单元测试。 |

---

## 五、 执行阶段交付物矩阵

- [ ] **交付物 1**：C++ 引擎 7 频段动态压限器参数接口与生效逻辑；
- [ ] **交付物 2**：`comp_card.dart` Ticker 独立物理衰减驱动（告别停滞）与频段/阈值交互；
- [ ] **交付物 3**：`spatial_card.dart`、`reverb_card.dart`、`stereo_card.dart` 自闭问题修复与文案升级；
- [ ] **交付物 4**：`dsp_spatial.cpp`、`stereoEnhancement.c`、`dsp_freeverb.cpp` 等响度与恒能量法则落实；
- [ ] **交付物 5**：商业标杆级极简极美空间音频全息声场与混响声学室可视化重绘；
- [ ] **交付物 6**：Flutter analyze 0 警告与全量自动化测试套件回归验证。
