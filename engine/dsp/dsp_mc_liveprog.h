#pragma once

/* 多声道 EEL 脚本级宿主（liveprog.mc，方案 B，2026-11-09）。
 *
 * 设计见 docs/10-架构/EEL多声道脚本级实施方案-2026-11-09.md：
 * 引擎层独立 NSEEL VM 宿主，脚本读写 spl0..spl7；立体声
 * liveprogWrapper（legacy）一行不改，两套脚本的 VM/RAM/滑块互不可见。
 *
 * 并发纪律逐条平移 P-016 影子槽范式：3 槽 + 在途守卫双条件 +
 * 500ms 有界等待 + 原子换活动指针；RT 路径零分配/零锁/零系统调用。
 * 本头只暴露不透明句柄与控制面 API（NSEEL 类型不外泄）。 */

struct McLiveProgHost;

/* 控制线程：构造/析构。sampleRate 为引擎处理采样率，channels 为当前
 * 链路声道数（2/4/6/8）。VM 分配失败时返回的宿主仍可安全调用全部
 * API（编译会自然失败/跳过），destroy 接受 nullptr。 */
McLiveProgHost* mc_liveprog_create(float sampleRate, int channels);
void mc_liveprog_destroy(McLiveProgHost* host);

/* 控制线程：编译并换入脚本（@init/@sample 必备，@slider/@block 合并
 * 为每块前置段）。返回 1=成功换入；<0=错误码（口径同
 * LiveProgStringParser：0 缺 @init、-1 @init 语法、-2 缺 @sample、
 * -3 @sample 语法、-4 引擎忙、-5 @slider 语法）。失败时活动快照
 * 不受影响，旧代码继续运行。 */
int mc_liveprog_load(McLiveProgHost* host, const char* code);

/* 控制线程：停用活动快照的编译态（单次 int 写，RT 最多少停一块）。 */
void mc_liveprog_unload(McLiveProgHost* host);

/* 控制线程：使能开关（RT 读端为原子量）。 */
void mc_liveprog_set_enabled(McLiveProgHost* host, int enabled);
int mc_liveprog_get_enabled(const McLiveProgHost* host);

/* 控制线程：环境同步——采样率/声道数变化时调用；写全部槽快照与
 * 已注册的环境寄存器（srate/dev_srate/num_ch/nch）。 */
void mc_liveprog_set_sample_rate(McLiveProgHost* host, float sampleRate);
void mc_liveprog_set_channels(McLiveProgHost* host, int channels);

/* 控制线程：取活动 VM 的 sliderN 寄存器指针（N=1..64），无活动 VM
 * 时返回 nullptr。供参数层在编译成功后刷新滑块指针（平移
 * lp_refresh_sliders 的取指针部分）。 */
float* mc_liveprog_slider_var(McLiveProgHost* host, int index1Based);

/* 控制线程：执行一次活动快照的 slider 段（滑块刷新后调用，平移
 * lp_refresh_sliders 的尾步）。 */
void mc_liveprog_exec_slider_section(McLiveProgHost* host);

/* RT 线程：对交织缓冲原地执行多声道脚本。
 * buf 为 frames × channels 交织；仅在使能且编译成功时改动数据，
 * 否则逐字节直通。channels 钳制到 [1,8]；spl 越界声道读 0、写丢弃；
 * 写回逐声道做非有限卫士（非有限置 0）。 */
void mc_liveprog_process(McLiveProgHost* host, float* buf, int frames,
                         int channels);
