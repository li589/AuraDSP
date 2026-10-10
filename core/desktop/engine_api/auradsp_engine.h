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
 *   mode.latency     i32  0=realtime(<=10ms) 1=music(<=30ms) 2=quality(不限)
 *   channels.mode    i32  0=stereo 1=5.1 2=7.1（Phase A 为矩阵包络，见 ADR-003）
 *   liveprog.enable  i32  0/1 —— EEL2 实时可编程 DSP（v1.1 增量）
 *   liveprog.code    str  UTF-8 脚本全文（@init/@sample 两段），bytes=字节数
 *   liveprog.unload  i32  停用并清编译态
 *   liveprog.status  i32  get：0=无代码 1=编译成功 <0=语法错误码
 *   liveprog.paramN  f32  slider1..8（vendor 补丁 P-001，见 PATCHES.md）
 *   convolver.enable i32  0/1 —— T2 效果，品质档限定（v1.1 M4）
 *   convolver.ir.path str UTF-8 文件路径（WAV/FLAC，门卫见 load_ir_file）
 *   convolver.clear  i32  清除 IR 并停用
 *   convolver.ready/ir.frames/ir.channels/ir.srcRate/ir.peak/ir.spectrum get 回读
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
    AURADSP_E_LATENCY_GUARD = -3,  /* 超出当前延迟档预算（ADR-002） */
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
#define AURADSP_STAGE_MAX 16
typedef struct auradsp_viz_frame {
    uint64_t seq;
    double   timestamp_ms;
    float    spectrum[AURADSP_VIZ_BANDS];
    float    level_l_dbfs;
    float    level_r_dbfs;
    /* [M3.5-c] 12 个 stage 的实时双声道峰值 (dBFS) */
    float    stage_levels_l[AURADSP_STAGE_MAX];
    float    stage_levels_r[AURADSP_STAGE_MAX];
} auradsp_viz_frame;

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
double         auradsp_get_latency_ms(auradsp_handle h);
const char*    auradsp_last_error(auradsp_handle h);

/* ---- 可视化（UI 线程；返回实际读取帧数） ---- */
uint32_t auradsp_viz_read(auradsp_handle h, auradsp_viz_frame* out, uint32_t max_frames);

/* ---- 元信息 ---- */
const char* auradsp_version(void);      /* 引擎 ABI 版本，如 "1.0.0" */
uint32_t    auradsp_abi(void);          /* ABI 序号，加载时校验 */

/* ---- 第三方插件宿主（M1：VST3 / CLAP 64位） ---- */
int      auradsp_plugin_scan(auradsp_handle h, const char* extra_dirs_json, int deep_scan);
int      auradsp_plugin_get_count(auradsp_handle h);
int      auradsp_plugin_get_item(auradsp_handle h, int index, char* out_json, int max_len);
int      auradsp_plugin_get_all(auradsp_handle h, char* out_json, int max_len);
int      auradsp_plugin_load(auradsp_handle h, const char* path, const char* plugin_id);
int      auradsp_plugin_unload(auradsp_handle h);
int      auradsp_plugin_set_bypass(auradsp_handle h, int bypass);
int      auradsp_plugin_get_bypass(auradsp_handle h);
uint32_t auradsp_plugin_get_latency(auradsp_handle h);
int      auradsp_plugin_get_status(auradsp_handle h, char* out_json, int max_len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AURADSP_ENGINE_H */
