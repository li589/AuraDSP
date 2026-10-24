/*
 * auradsp_engine.h — AuraDSP Engines 统一控制协议（engine_api C ABI）v1.0
 *
 * 定位：UI 层与驱动层之间的唯一边界。Android Root（经 AIDL VendorParamId
 * 透传同语义）、Android Rootless（进程内 FFI）、Desktop（DLL）三种引擎形态
 * 全部实现本 ABI 语义；UI 不感知引擎所在进程与形态。
 *
 * 线程契约：
 *   - auradsp_process()      仅 RT 音频线程调用。内部无 malloc/锁/IO/日志。
 *   - auradsp_set/get_param  控制线程调用；与 process 的同步由实现内部
 *                            （原子量/指针交换）保证，调用方无需持锁。
 *   - auradsp_viz_read()     UI 侧线程调用；SPSC 单向，引擎侧只写。
 *
 * 参数模型：字符串 ID + POD 值。参数语义表（v1）：
 *   bass.enable      i32  0/1
 *   bass.gain        f32  dB [0,15]
 *   reverb.preset    i32  -1=off, 0..N 预设索引（SF_REVERB_PRESET_*）
 *   stereo.mix       f32  [0,1]
 *   eq.enable        i32  0/1
 *   post.gain        f32  dB [-15,15]
 *   limiter.enable   i32  0/1
 *   mode.latency     已移除（ADR-006 撤销三档延迟硬约束）。下发/回读均返回
 *                     AURADSP_E_PARAM，不静默忽略。延迟改由
 *                     auradsp_get_latency_ms() 纯测量上报 + 组件级脉冲实测徽标呈现。
 *   channels.mode    i32  0=stereo 1=5.1 2=7.1（Phase A 为矩阵包络，见 ADR-003）
 *   liveprog.enable  i32  0/1 —— EEL2 实时可编程 DSP（v1.1 增量）
 *   liveprog.code    str  UTF-8 脚本全文（@init/@sample 两段），bytes=字节数
 *   liveprog.unload  i32  停用并清编译态
 *   liveprog.status  i32  get：0=无代码 1=编译成功 <0=语法错误码
 *   liveprog.paramN  f32  slider1..8（vendor 补丁 P-001，见 PATCHES.md）
 *   字符串回读（2026-10-17）：liveprog.code / eq.curve / arbmag.string 三 id 均支持
 *     get 回读（存下发原串副本，杜绝重序列化漂移；bytes 须 >= len+1，容量不足
 *     返回 E_PARAM，无副本回 NUL 空串）。不新增导出符号、不升 ABI 版本。
 *   convolver.enable i32  0/1 —— 卷积混响，可自由使能（ADR-006 起不再受延迟档限定）
 *   convolver.ir.path str UTF-8 文件路径（WAV/FLAC，门卫见 load_ir_file）
 *   convolver.clear  i32  清除 IR 并停用
 *   convolver.ready/ir.frames/ir.channels/ir.srcRate/ir.peak/ir.spectrum get 回读
 *
 * 引擎配置项（由 AppConfig 下发；改动即时生效，但见各条约束）：
 *   channels.count   i32  驱动层交织缓冲声道数：2=立体声 6=5.1 8=7.1。
 *                          >2 时 auradsp_process 的 in/out 按 frames*channels
 *                          交织解释，并走 ADR-003 Phase A 的矩阵混音。
 *                          只接受 2/6/8，其它值拒绝。
 *   gate.maxIrSeconds f32  FileGate 时长上限（秒，0.1~600）。此前写死 16M 帧。
 *   gate.maxFileMb    f32  FileGate 体积上限（MiB，1~4096）。此前写死 256MiB。
 *   viz.fftSize       i32  频谱 FFT 点数（2 的幂，1024~8192，默认 4096）。
 *                          **仅允许在产出过第一帧频谱之前修改**（窗体重建需与
 *                          RT 线程互斥）；属于启动期配置，不是实时滑块。
 */
#ifndef AURADSP_ENGINE_H
#define AURADSP_ENGINE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct auradsp_handle_s* auradsp_handle;

typedef enum auradsp_status {
    AURADSP_OK = 0,
    AURADSP_E_PARAM = -1,          /* 参数 ID 未知或值越界 */
    AURADSP_E_UNSUPPORTED = -2,    /* 当前形态不支持该能力 */
    AURADSP_E_LATENCY_GUARD = -3,  /* 已废弃（ADR-006）：延迟不再有任何准入判定。
                                    *   保留枚举值仅为不破坏既有 ABI 编号，新代码不应返回它。 */
    AURADSP_E_STATE = -4,          /* 状态机拒绝（如未 open） */
    AURADSP_E_IO = -5,
} auradsp_status;

typedef enum auradsp_state {
    AURADSP_STATE_BYPASS = 0,      /* 旁路（直通） */
    AURADSP_STATE_PROCESSING = 1,  /* 处理中 */
    AURADSP_STATE_ERROR = 2,       /* 失效（原因经 auradsp_last_error） */
} auradsp_state;

/* 可视化帧：引擎 RT 线程每处理块写入 SPSC ring，UI 拉取。
 * spectrum 为 32 段对数频带归一化幅度 [0,1]，levels 为 dBFS。 */
#define AURADSP_VIZ_BANDS 32
#define AURADSP_STAGE_MAX 32   /* ABI 容量：per-stage 电平数组的物理长度（预留 32 槽） */
/* 实际在用的 vendor 处理链节点数（graph.order 的合法集合大小）。
 * AURADSP_STAGE_MAX 是 ABI 容量，本值是真实 stage 数——两者不要混用。
 * 改动 vendor 链长度时必须同步：此处 + Dart 的 kEngineStageCount。 */
#define AURADSP_VENDOR_STAGES 12
#if AURADSP_VENDOR_STAGES > AURADSP_STAGE_MAX
#error "AURADSP_VENDOR_STAGES exceeds AURADSP_STAGE_MAX (ABI capacity)"
#endif
/* [Phase B 多声道电平] per-channel 电平数组的物理长度。8 与全引擎声道 clamp
 * 一致（vst3/clap/plugin_host_manager/delay_line/plugin_chain_component 均
 * channels > 8 → 8）。stage_ch_levels/channel_levels 按本长度定长，未用声道
 * 恒 -120.0f。 */
#define AURADSP_CH_MAX 8
typedef struct auradsp_viz_frame {
    uint64_t seq;
    double   timestamp_ms;
    float    spectrum[AURADSP_VIZ_BANDS];
    /* [EQ tap] vendor 链入口（即均衡器输入）的同规格 32 段频谱。
     *
     * spectrum 取的是**整条链的最终输出**（EQ 之后的混响/卷积/Freeverb/
     * 插件全都算在内），所以拿它当均衡器面板的背景柱是错的：面板上看到的
     * 频谱并不是均衡器输出的东西，调整 EQ 时背景柱几乎不动。
     *
     * EQ 位于 libjamesdsp 的单体链内部（processFloatMultiplexd 一次跑完
     * 全链），拿不到它的输出——但按 LTI 性质有 |Y(f)| = |X(f)|·|H_eq(f)|，
     * 而 |H_eq| 可由 auradsp_probe_eq_response 精确测得。因此这里下发
     * **EQ 输入**谱，输出谱由 UI 用实测响应合成。
     * 语义与 spectrum 完全相同（同一 kBandEdges、同一 [0,1] 归一化）。 */
    float    eq_in_spectrum[AURADSP_VIZ_BANDS];
    float    level_l_dbfs;
    float    level_r_dbfs;
    /* [M3.5-c / 全量电平补齐] 处理链各阶段实时双声道峰值 (dBFS)：
     * 0..11: vendor 12 级链 (tube..output)
     * 12: gate 输入电平 (input_lvl_in)
     * 13: gate 本级输出电平 (gate stage output)
     * 14: dyneq 动态均衡输出电平
     * 15: filter 独立滤波输出电平
     * 16: bassmono 低频单声道输出电平
     * 17: haas 哈斯环绕输出电平
     * 18: exciter 高频激励输出电平
     * 19: loudness 响度补偿输出电平
     * 20: spatial 空间音效输出电平
     * 21..31: 预留槽位（插件插槽 / 未来扩展，恒为 -120.0f） */
    float    stage_levels_l[AURADSP_STAGE_MAX];
    float    stage_levels_r[AURADSP_STAGE_MAX];
    /* [Phase B 多声道电平 / ADR-003] 追加式扩展（2026-10-24，ABI 1→2）。
     * 前 536 B 布局零变化：按旧 sizeof 读取的老消费者逐位兼容；新消费者
     * （Dart Struct 定长读）必须与引擎同 ABI 版本，加载时经 auradsp_abi() 强校验。
     *
     * channel_count：本帧来源块的声道数（2/6/8）；0 = 无有效帧（UI 回退 L/R）。
     *
     * channel_levels：auradsp_process 最终输出 per-channel 峰值 dBFS。
     *   未用声道 -120.0f。
     *   **限定**：[0]/[1] 与 level_l/r_dbfs 恒等**仅在立体声路径成立**
     *   （viz_write 同一趟扫描同源）。离散多声道（channels.mode=1）下
     *   level_l/r 仍按立体声 stride 取 out[i*2]（既存近似，见设计文档遗留项），
     *   此时请以 channel_levels 为准、不要假设两者相等。
     *   矩阵模式（mode=0）的 per-channel 值取自 mx_upmix 之后的 out 实测
     *   （spectrum 仍取 mx_stereo 下混，两者口径不同是刻意的）。
     *
     * stage_ch_levels[stage][ch]（stage-major）：
     *   0..11 vendor：仅 [0]/[1] 有效（= stage_levels_l/r；MC 下 vendor 段
     *        只作用于 FL/FR 对，ADR-003 Category B 设计语义），[2..7] 恒 -120；
     *   12 gate 输入 / 13 gate 输出 / 14 dyneq / 15 filter / 18 exciter /
     *        19 loudness：MC 下 [0..ch-1] 有效；
     *   16 bassmono / 17 haas / 20 spatial（Category B 仅作用于前置对）：
     *        仅 [0]/[1] 有效，[2..7] 恒 -120；
     *   21..23、30..31 预留槽与 24..29 GR 槽：全 -120（GR 是全链单值计量，
     *        per-channel 无意义；GR 仍读 stage_levels_l/r 的 L 列）。
     *   即：stereo 模式下 [0]/[1] 与 stage_levels_l/r 逐位一致、[2..7] 恒 -120，
     *        MC 模式下诚实反映各效果器的真实作用域，不复制假装全声道。 */
    uint32_t channel_count;
    float    channel_levels[AURADSP_CH_MAX];
    float    stage_ch_levels[AURADSP_STAGE_MAX][AURADSP_CH_MAX];
} auradsp_viz_frame;

/* ABI 尺寸哨兵：536B（v1）→ 1600B（v2）。变更即编译失败，杜绝静默漂移。
 * Dart 侧对应断言见 test/（sizeOf<VizFrame>() == 1600）。
 * 1600 = 536 + 4(channel_count) + 32(channel_levels) + 1024(stage_ch_levels)
 *        + 4 尾填充（struct 含 uint64/double，sizeof 须为 8 的倍数）。
 * 用 typedef 数组而非 _Static_assert：本头是公共 ABI 头，C89 消费者亦须通吃。 */
typedef char auradsp_viz_frame_abi_size_check[(sizeof(auradsp_viz_frame) == 1600) ? 1 : -1];

/* ---- 生命周期（控制线程） ---- */
auradsp_handle auradsp_create(float sample_rate, int max_block_frames);
void           auradsp_destroy(auradsp_handle h);

/* ---- RT 音频（仅音频线程；stereo interleaved） ---- */
void auradsp_process(auradsp_handle h, const float* in, float* out, int frames);

/* ---- 参数与状态（控制线程） ---- */
auradsp_status auradsp_set_param(auradsp_handle h, const char* id,
                                 const void* value, uint32_t bytes);
auradsp_status auradsp_get_param(auradsp_handle h, const char* id,
                                 void* out_value, uint32_t bytes);
auradsp_state  auradsp_get_state(auradsp_handle h);
/* 当前链上各效果引入的附加延迟（毫秒）。纯测量上报，不参与任何准入判定
 * （ADR-006 已撤销延迟档硬约束）。
 *
 * D1（2026-10-24）：返回值**随采样率与块长变化**——结构性延迟按帧数换算：
 *   comp     = 4096 帧（FFTCompander 固定 FFTSIZE_DRS/2）→ 48k 85.33ms / 96k 42.67ms
 *   arbmag   = 单块帧数（分块 FFT 卷积，随驱动块长变）
 *   其余项为听感名义毫秒值（reverb 30 / crossfeed 3 / spatial 1 / ddc 6 /
 *   limiter 2 / convolver 10 下限），不随采样率变。
 * 该函数在控制线程读参数快照，无锁、无 RT 依赖，可在任意控制线程调用。 */
double         auradsp_get_latency_ms(auradsp_handle h);
const char*    auradsp_last_error(auradsp_handle h);

/* ---- 可视化（UI 线程；返回实际读取帧数） ---- */
uint32_t auradsp_viz_read(auradsp_handle h, auradsp_viz_frame* out, uint32_t max_frames);

/* ---- 测试放音用的音频文件解码（isolate 线程；允许分配，非 RT 路径） ----
 * MP3（dr_mp3，vendor 自带头单实例化）。WAV 仍走 Dart 自解码，此处只做 MP3。
 * 成功返回 stereo interleave float32 缓冲（调用方 ownership），附采样率与总帧数；
 * 失败返回 nullptr。用 auradsp_free_audio_buffer 释放（配对 free）。 */
float*   auradsp_decode_audio_file(const char* utf8path, int* out_rate, uint64_t* out_frames);
void     auradsp_free_audio_buffer(void* p);

/* ---- 元信息 ---- */
const char* auradsp_version(void);      /* 引擎版本；实际值以 AURADSP_VERSION（engine_internal.h）为准 */
uint32_t    auradsp_abi(void);          /* ABI 序号，加载时校验 */

/* ---- 组件延迟实测（控制线程；不触碰调用方正在使用的 handle） ---- */
/* 真实脉冲响应测量，而非查表：函数内部自建一次性探针 handle，只启用目标组件，
 * 注入单位脉冲，检测首个非零输出样本的位置。
 *   component: bass|reverb|eq|tube|crossfeed|limiter|convolver|ddc|liveprog|shelf|post
 *   out_samples: 输出算法延迟（样本数）；纯零相位 IIR 返回 0
 *   返回 0 成功；-1 组件名未知；-2 探针创建失败。
 * 代价：每次调用建/毁一个 handle 并跑一段静音，耗时约数毫秒，
 * 因此只应在用户显式请求时调用，绝不要放进音频路径。 */
int auradsp_probe_component(const char* component, double sample_rate,
                            uint32_t* out_samples);

/* 同上，但为需要外部资源的组件（convolver / ddc）提供资源路径，
 * 使其能在探针内就绪并被真实测量。
 *
 * resource_path: IR (.wav) 或 VDC (.vdc) 文件路径；其它组件可传 NULL。
 * 返回 0 表示测得，-1 组件未知，-2 探针创建失败，
 * -3 探针未能使该组件生效（含资源加载失败）。
 *
 * 保留原 auradsp_probe_component 是为了不破坏既有 ABI：对 convolver/ddc/
 * liveprog 它仍返回 -1，调用方需显式改用本函数才是「实测」而非「不可测」。 */
int auradsp_probe_component_with_resource(const char* component,
                                          const char* resource_path,
                                          double sample_rate,
                                          uint32_t* out_samples);

/* 同上，但携带「当前配置」实参：arg 仅 haas 使用——传入用户当前的
 * haas.delay_ms，使实测值等于引擎 compute_latency 的动态口径（0..25ms）；
 * 其它组件忽略 arg（传 0 即可）。haas / spatial 已入探针支持集：
 * 逐声道首非零取最大后，haas 测出延迟值，spatial 测出 0ms（链上无前瞻，
 * ITD 是耳间差而非链延迟）。 */
int auradsp_probe_component_current(const char* component, double arg,
                                    double sample_rate,
                                    uint32_t* out_samples);

/* ---- C2：EQ 实际频率响应实测 ----
 *
 * 传入 eq.curve 同格式字符串（"f:g;f:g;..."），在 [f_min, f_max] 上按
 * **对数等分**取 n_points 个点，把引擎真实产生的幅度响应（dB）写入 out_db。
 *
 * 用途：UI 画的是 log-f 上的 smoothstep 插值，而引擎走 makima + 最小相位 IR
 * + FFT 卷积，两者本就不一致（最小相位化会带来过冲与频带间相互影响）。
 * 本接口给出地面真值，让 UI 不必再用自己的近似去猜引擎行为。
 *
 * 解析与重采样与实时 eq.curve 下发**共用同一段代码**，因此结果就是设备
 * 实际会产生的响应，而不是「另一套实现的自我印证」。
 *
 * 不接受 handle：内部构造私有 jdsp 实例，避免与音频线程争同一个卷积器历史。
 * 纯函数，可在任意线程调用。curve 非法或点数 <2 返回 AURADSP_E_PARAM。
 */
int auradsp_probe_eq_response(int sample_rate, const char* curve, int n_points,
                              double f_max, float* out_db);

/* ---- 第三方插件宿主（M1：VST3 / CLAP 64位） ---- */
int      auradsp_plugin_scan(auradsp_handle h, const char* extra_dirs_json, int deep_scan);
/* C2 分块扫描：把「枚举 + 取元数据」拆成可让出的小步，调用方在步间让出
 * 线程，扫描不再是一记长时间阻塞 FFI。结果渐进可见（scan_step 期间
 * auradsp_plugin_get_all 即返回已扫到的部分）。
 *   scan_begin → 返回候选总数（>0 表示有活）；
 *   scan_step  → 处理至多 max_items 个候选，返回本步处理数（<=0 = 全部完成）；
 *   scan_progress → 返回已处理数；out_total 非空时写入候选总数；无任务返回 -1；
 *   scan_end   → 收尾并刷新元数据缓存，返回最终插件数。
 * 未调用 scan_end 直接开始下一次 scan_begin 等价于放弃上一次任务。 */
int      auradsp_plugin_scan_begin(auradsp_handle h, const char* extra_dirs_json, int deep_scan);
int      auradsp_plugin_scan_step(auradsp_handle h, int max_items);
int      auradsp_plugin_scan_progress(auradsp_handle h, int* out_total);
int      auradsp_plugin_scan_end(auradsp_handle h);
int      auradsp_plugin_get_count(auradsp_handle h);
int      auradsp_plugin_get_item(auradsp_handle h, int index, char* out_json, int max_len);
int      auradsp_plugin_get_all(auradsp_handle h, char* out_json, int max_len);

/* 多插槽控制 (slot: 0..kMaxPluginSlots-1，当前为 0..3，以 get_num_slots 为准) */
int      auradsp_plugin_get_num_slots(auradsp_handle h);
int      auradsp_plugin_slot_load(auradsp_handle h, int slot, const char* path, const char* plugin_id);
int      auradsp_plugin_slot_unload(auradsp_handle h, int slot);

/* ---- C3 异步挂载/卸载（2026-10-12）----
 * 提交后立即返回（非阻塞），调用方轮询 auradsp_plugin_slot_task_state 直到终态。
 * task_state: 0=无任务 1=进行中 2=成功 3=失败 */
int      auradsp_plugin_slot_load_async(auradsp_handle h, int slot, const char* path, const char* plugin_id);
int      auradsp_plugin_slot_unload_async(auradsp_handle h, int slot);
int      auradsp_plugin_slot_task_state(auradsp_handle h, int slot);
int      auradsp_plugin_slot_set_bypass(auradsp_handle h, int slot, int bypass);
int      auradsp_plugin_slot_get_bypass(auradsp_handle h, int slot);
uint32_t auradsp_plugin_slot_get_latency(auradsp_handle h, int slot);
int      auradsp_plugin_slot_get_status(auradsp_handle h, int slot, char* out_json, int max_len);

/* 界面与预设 */
/* show_editor 的 title：窗口标题，可传 NULL（退化为插件自报名）。
 * E1 修正：Dart FFI 早年即传 title，但 C ABI 仅 2 参，标题被静默丢弃。 */
int      auradsp_plugin_slot_show_editor(auradsp_handle h, int slot, const char* title);
int      auradsp_plugin_slot_close_editor(auradsp_handle h, int slot);
int      auradsp_plugin_slot_is_editor_open(auradsp_handle h, int slot);
int      auradsp_plugin_slot_save_preset(auradsp_handle h, int slot, const char* path);
int      auradsp_plugin_slot_load_preset(auradsp_handle h, int slot, const char* path);

/* 插件编辑器隔离名单（预设系统数据，UI/预设层维护，引擎不硬编码插件名）。
 * patterns: 逗号分隔的小写子串（匹配插件 name/path），如 "zebra2,ozone"；
 * NULL 或空串清空名单。命中名单的插件关闭编辑器时跳过 removed()/release()
 * （防插件自身 teardown fail-fast 崩溃，宿主不因插件缺陷陪葬）。
 * 2026-10-19：从引擎内硬编码迁移为运行时数据。 */
int      auradsp_plugin_set_editor_quarantine_list(const char* patterns);

/* 处理链插入阶段 (0=Pre-DSP, 1=Pre-Vendor, 2=Post-Vendor, 3=Post-Reverb, 4=Post-Limiter) */
int      auradsp_plugin_slot_set_insert_stage(auradsp_handle h, int slot, int stage);
int      auradsp_plugin_slot_get_insert_stage(auradsp_handle h, int slot);

int      auradsp_plugin_slot_set_channels(auradsp_handle h, int slot, int mask);
int      auradsp_plugin_slot_get_channels(auradsp_handle h, int slot);

/* 兼容旧版单插槽（映射至 slot 0） */
int      auradsp_plugin_load(auradsp_handle h, const char* path, const char* plugin_id);
int      auradsp_plugin_unload(auradsp_handle h);
int      auradsp_plugin_set_bypass(auradsp_handle h, int bypass);
int      auradsp_plugin_get_bypass(auradsp_handle h);
uint32_t auradsp_plugin_get_latency(auradsp_handle h);
int      auradsp_plugin_get_status(auradsp_handle h, char* out_json, int max_len);

/* PDC ��·�ӳٲ����� */
int      auradsp_plugin_set_pdc(auradsp_handle h, int enable);
int      auradsp_plugin_get_pdc(auradsp_handle h);
uint32_t auradsp_plugin_get_total_latency(auradsp_handle h);

/* plugin chain enable switch (VB multi-bus per-bus plugin processing):
 * disabled = plugins (incl. PDC) bypassed on this handle; slot mounts and
 * vendor DSP unaffected. Enabled by default. */
int      auradsp_plugin_chain_set_enabled(auradsp_handle h, int enabled);
int      auradsp_plugin_chain_get_enabled(auradsp_handle h);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AURADSP_ENGINE_H */
