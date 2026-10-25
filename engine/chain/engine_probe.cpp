/* P2 split: probe (extern "C" context preserved from original). */
#include "engine_internal.h"
extern "C" {


/* ---------------------------------------------------------------------------
 * 组件延迟实测（D11）
 *
 * 做法：自建一次性探针 handle（不触碰调用方正在放音的 handle —— 实测两个 handle
 * 可安全共存，见 tools/probe/probe_concurrent.py），只启用目标组件，注入单位脉冲，
 * 检测首个非零输出的样本位置。返回值是**测出来的**，不是查表来的。
 *
 * 先测一遍"全关基线"，再减去它——基线可能因链上零相位环节而有微小偏移，
 * 相减后得到的是该组件自身的净算法延迟。
 *
 * 窗口上限 kProbeWindow：覆盖 vendor 侧最大前瞻（FFT 块级）绰绰有余；
 * 超窗仍未出现输出即视为"无可测延迟"返回 0（纯 IIR 的正常情形）。
 * ------------------------------------------------------------------------- */
namespace {
constexpr int kProbeWindow = 16384;   /* @48k ≈ 341ms */
constexpr int kProbeBlock  = 256;

/* 把探针 handle 上的所有效果关掉，只留下要测的那个。
 * probe_arg：仅 haas 使用——传入当前延迟（ms），让探针按用户实际设定测，
 * 而不是用出厂默认 12ms（否则徽标读数与引擎 compute_latency 的动态口径脱节）。
 * 其它组件忽略该参数。 */
void probe_isolate(auradsp_handle p, const char* comp, float probe_arg = 0.0f) {
    const struct { const char* id; int i; } zeros[] = {
        {"bass.enable", 0}, {"eq.enable", 0}, {"tube.enable", 0},
        {"crossfeed.enable", 0}, {"limiter.enable", 0}, {"convolver.enable", 0},
        {"ddc.enable", 0}, {"liveprog.enable", 0}, {"shelf.enable", 0},
        {"bassmono.enable", 0}, {"haas.enable", 0}, {"exciter.enable", 0},
        {"stereo.enable", 0}, {"arbmag.enable", 0},
        {"spatial.enable", 0},
        /* 自研 stage：此前整组漏在这里。它们虽在引擎自己的链上而不在 vendor
         * 链上，auradsp_process 走的正是 process_stereo_chain，所以探针
         * handle 上同样能被启用/关闭——漏列只是让"全关基线"名不副实。 */
        {"gate.enable", 0}, {"filter.enable", 0}, {"dyneq.enable", 0},
        {"loudness.enable", 0}, {"comp.enable", 0},
    };
    for (const auto& z : zeros) {
        const int32_t v = 0;
        auradsp_set_param(p, z.id, &v, 4);
    }
    int32_t zero = 0;
    /* WP1：preset=-1 才是「关」（0..18 是开启的预设号）。旧值 0 会把 vendor
     * 混响留在探针基线里（+30ms + 尾音能量），污染每一条测量。 */
    int32_t off = -1;
    auradsp_set_param(p, "reverb.preset", &off, 4);   /* -1 = off */
    auradsp_set_param(p, "freeverb.enable", &zero, 4);
    const float zero_f = 0.0f;
    auradsp_set_param(p, "stereo.mix", &zero_f, 4);
    auradsp_set_param(p, "post.gain", &zero_f, 4);
    auradsp_set_param(p, "bass.gain", &zero_f, 4);
    auradsp_set_param(p, "haas.mix", &zero_f, 4);
    auradsp_set_param(p, "exciter.amount", &zero_f, 4);

    if (!strcmp(comp, "bass")) {
        const int32_t one = 1; const float g = 6.0f;
        auradsp_set_param(p, "bass.enable", &one, 4);
        auradsp_set_param(p, "bass.gain", &g, 4);
    } else if (!strcmp(comp, "reverb")) {
        const int32_t one = 1;
        auradsp_set_param(p, "reverb.preset", &one, 4);
    } else if (!strcmp(comp, "eq")) {
        const int32_t one = 1;
        auradsp_set_param(p, "eq.enable", &one, 4);
        const char* curve = "20:0;100:0;1000:0;10000:0;20000:0;";
        auradsp_set_param(p, "eq.curve", curve, (uint32_t)strlen(curve));
    } else if (!strcmp(comp, "tube")) {
        const int32_t one = 1;
        auradsp_set_param(p, "tube.enable", &one, 4);
    } else if (!strcmp(comp, "crossfeed")) {
        const int32_t one = 1;
        auradsp_set_param(p, "crossfeed.enable", &one, 4);
    } else if (!strcmp(comp, "limiter") || !strcmp(comp, "post")) {
        const int32_t one = 1;
        auradsp_set_param(p, "limiter.enable", &one, 4);
    } else if (!strcmp(comp, "shelf")) {
        const int32_t one = 1; const float g = 6.0f;
        auradsp_set_param(p, "shelf.enable", &one, 4);
        auradsp_set_param(p, "shelf.gain", &g, 4);
    } else if (!strcmp(comp, "comp")) {
        const int32_t one = 1;
        auradsp_set_param(p, "comp.enable", &one, 4);
    } else if (!strcmp(comp, "bassmono")) {
        const int32_t one = 1; const float f = 120.0f;
        auradsp_set_param(p, "bassmono.enable", &one, 4);
        auradsp_set_param(p, "bassmono.freq", &f, 4);
    } else if (!strcmp(comp, "exciter")) {
        const int32_t one = 1; const float amt = 0.8f;
        auradsp_set_param(p, "exciter.enable", &one, 4);
        auradsp_set_param(p, "exciter.amount", &amt, 4);
    } else if (!strcmp(comp, "stereo")) {
        const int32_t one = 1; const float mix = 0.5f;
        auradsp_set_param(p, "stereo.enable", &one, 4);
        auradsp_set_param(p, "stereo.mix", &mix, 4);
    } else if (!strcmp(comp, "arbmag")) {
        const int32_t one = 1;
        const char* str = "GraphicEQ: 20 0; 1000 0; 20000 0";
        auradsp_set_param(p, "arbmag.string", str, (uint32_t)strlen(str));
        auradsp_set_param(p, "arbmag.enable", &one, 4);
    } else if (!strcmp(comp, "dyneq")) {
        /* 全参数动态 EQ：三段默认参数即可，它按样本逐点处理（无 FFT 块延迟），
         * 预期测出 0——但必须是"实测的 0"，不是"拒绝测量"。 */
        const int32_t one = 1;
        auradsp_set_param(p, "dyneq.enable", &one, 4);
    } else if (!strcmp(comp, "filter")) {
        const int32_t one = 1;
        auradsp_set_param(p, "filter.enable", &one, 4);
    } else if (!strcmp(comp, "gate")) {
        const int32_t one = 1;
        auradsp_set_param(p, "gate.enable", &one, 4);
    } else if (!strcmp(comp, "loudness")) {
        const int32_t one = 1;
        auradsp_set_param(p, "loudness.enable", &one, 4);
    } else if (!strcmp(comp, "haas")) {
        /* Haas = 纯延迟线：只延迟一侧（haas.side 决定），另一侧恒直通。
         * 首非零法打双声道脉冲时干声侧恒在 0，故必须用「逐声道首非零取
         * 最大」测延迟侧；且 mix 必须拨到 1.0（纯延迟），否则延迟侧也有
         * 干声成分、首非零仍落在 0。delay 用调用方传入的 probe_arg——
         * 测的是用户当前设定值，与 compute_latency 动态口径一致。 */
        const int32_t one = 1;
        const float delay = (probe_arg >= 0.0f && probe_arg <= 25.0f) ? probe_arg : 12.0f;
        const float mix1 = 1.0f;
        auradsp_set_param(p, "haas.delay", &delay, 4);
        auradsp_set_param(p, "haas.mix", &mix1, 4);
        auradsp_set_param(p, "haas.enable", &one, 4);
    } else if (!strcmp(comp, "spatial")) {
        /* 空间音效：近耳直达 + 中置源均即时输出（ITD 是耳间差而非链延迟），
         * 首非零必然落在 0——实测 0ms 是诚实的「链上无前瞻」；kLatSpatial
         * 的 1ms 名义属总延迟口径里的耳间 ITD 语义，不是链延迟。 */
        const int32_t one = 1;
        auradsp_set_param(p, "spatial.enable", &one, 4);
    }
    /* convolver / ddc / liveprog 需要外部资源（IR / VDC / 脚本），
     * 无法在空探针上就绪，此时如实返回"不可测"而不是编一个数字。 */
}


bool probe_is_supported(const char* comp) {
    static const char* kSupported[] = {
        "bass", "reverb", "eq", "tube", "crossfeed", "limiter", "post", "shelf", "comp",
        "bassmono", "exciter", "stereo", "arbmag",
        /* 自研 stage（2026-10-16 补）：此前 UI 给了 ↻ 按钮但引擎一律返回 -1，
         * 用户点任何一次都只得到「未测量」。这四者都在 process_stereo_chain 上、
         * 按样本逐点处理，探针能如实测出（预期 0ms）。 */
        "dyneq", "filter", "gate", "loudness"
        /* haas / spatial（2026-10-19 补）：此前认为探针结构性失明（haas 只延迟
         * 一侧、spatial 近耳即时），改为逐声道首非零取最大后均可如实测量——
         * haas 测出当前延迟值，spatial 测出 0ms（诚实链延迟）。 */
        , "haas", "spatial"
    };
    for (const char* s : kSupported)
        if (!strcmp(comp, s)) return true;
    return false;
}


/* 打脉冲，返回首个非零输出样本下标（无则 -1），并把输出总能量写入 *energy。
 * 能量用于判定「该组件是否真的参与了处理」——否则一个没接上的组件会被
 * 误报成「实测 0 ms 延迟」，把「测不到」谎报成「测到了」。
 *
 * 首非零按**逐声道**分别检测后取两者较大者返回：多数组件左右对称，两声道
 * 同一时刻过线，等价于旧实现；而 Haas 只延迟一侧（另一侧干声恒在 0），
 * 只有取「较晚的那一侧」才是延迟线的真实通过时刻。 */
long probe_first_nonzero(auradsp_handle p, float threshold, double* energy) {
    float* in = (float*)calloc(kProbeBlock * 2, sizeof(float));
    float* out = (float*)calloc(kProbeBlock * 2, sizeof(float));
    if (!in || !out) { free(in); free(out); return -1; }
    long firstL = -1, firstR = -1;
    double e = 0.0;
    /* 激励用**宽带噪声**而非单位冲激。
     *
     * 冲激是纯 DC，而 VDC 是高通滤波器（AKG K2xx 等监听耳机校正曲线
     * 在 DC 处增益为 0），冲激一进去就被滤光，首个非零点仍然是样本 0，
     * 能量也与基线相同 —— 于是被判定成「组件未启用」。
     * 用宽带噪声则每个频段都有能量，高通的通带与被抑制的低频都能被
     * 如实反映，测到的 first 才是真实的信号通过时刻。
     *
     * 噪声用确定性 LCG 生成：探针必须可复现，���机数会让结果漂移。 */
    uint32_t rng = 0x1234567u;
    auto next_noise = [&rng]() -> float {
        rng = rng * 1664525u + 1013904223u;
        return ((float)((rng >> 8) & 0xFFFF) / 32768.0f) - 1.0f;
    };
    bool warmed = false;
    for (int processed = 0; processed < kProbeWindow; processed += kProbeBlock) {
        for (int i = 0; i < kProbeBlock * 2; ++i) in[i] = next_noise();
        if (!warmed) {
            /* 先过一段静音让内部状态收敛，避免起始瞬态被当成延迟。
             * 冲激方案是靠「第一块前全零」实现同一目的。 */
            memset(in, 0, kProbeBlock * 2 * sizeof(float));
            warmed = true;
        }
        auradsp_process(p, in, out, kProbeBlock);
        for (int i = 0; i < kProbeBlock * 2; ++i) {
            const double a = fabs((double)out[i]);
            if (a > (double)threshold) {
                const int sample = processed + i / 2;
                if ((i & 1) == 0) { if (firstL < 0) firstL = sample; }
                else              { if (firstR < 0) firstR = sample; }
            }
            e += a * a;
        }
    }
    free(in);
    free(out);
    if (energy) *energy = e;
    if (firstL < 0) return firstR;
    if (firstR < 0) return firstL;
    return (firstL > firstR) ? firstL : firstR;
}

}  // namespace


static int probe_component_impl(const char* component, const char* resource_path,
                                float probe_arg, double sample_rate,
                                uint32_t* out_samples) {
    if (!component || !out_samples) return -1;
    *out_samples = 0;

    const bool is_conv = !strcmp(component, "convolver");
const bool is_ddc = !strcmp(component, "ddc");
    const bool supported = probe_is_supported(component);
    if (!supported) {
        /* convolver / ddc 需要外部资源（IR / VDC），没有就拒绝测量：
         * 未加载时无法探测，返回 -1 表示「不支持」而不是一个假的 0。
         *
         * 空字符串必须与 nullptr 同等看待：调用方（Dart 侧
         * latencyProbeResource）在没有资源时传的就是 ''，若只判指针非空，
         * 空串会一路走下去，在组件未启用的链上测出 first=0，
         * 能量又与基线相同 —— 而 first==0 不满足 first<0 的拒绝条件，
         * 于是返回 rc=0 / samples=0，**把「无法测量」伪装成「零延迟」**。
         * 那比拒绝更危险：UI 会据此显示一个看似合理却错误的延迟值。 */
        if (!resource_path || resource_path[0] == '\0' ||
            (!is_conv && !is_ddc))
            return -1;
    }

    const double fs = (sample_rate > 8000.0) ? sample_rate : 48000.0;
    auradsp_handle probe = auradsp_create((float)fs, kProbeBlock);
    if (!probe) return -2;
    /* ADR-006：延迟档已移除，探针无需再预设档位（原先下发 mode.latency=2）。 */

    /* 基线：全关，量出链自身的零点偏移与能量 */
    double base_energy = 0.0;
    probe_isolate(probe, "");
    const long baseline = probe_first_nonzero(probe, 1e-7f, &base_energy);

    probe_isolate(probe, supported ? component : "", probe_arg);
    if (!supported) {
        /* 带资源探测：先让资源就绪，再打开组件，
         * 否则 probe_isolate 已将它关掉且无资源时开启会被引擎拒绝。 */
        const int32_t one = 1;
        if (is_conv) {
            auradsp_set_param(probe, "convolver.ir.path", resource_path,
                              (uint32_t)strlen(resource_path));
            auradsp_set_param(probe, "convolver.enable", &one, 4);
        } else {
            auradsp_set_param(probe, "ddc.load", resource_path,
                              (uint32_t)strlen(resource_path));
            auradsp_set_param(probe, "ddc.enable", &one, 4);
        }
    }

    double energy = 0.0;
    const long first = probe_first_nonzero(probe, 1e-7f, &energy);
    auradsp_destroy(probe);

    /* 数据判定：全空输出→-3（无法测），
     * 能量与基线一致→-3（探针未能使其生效）。
     * 若能量已改变且 first >= 0，说明组件有效介入且为即时样本级处理（真实 0 延迟）。
     *
     * haas 纯延迟线特例：当前延迟为 0ms 时延迟环就是恒等映射（din*0 + delayed*1
     * 且 r0 刚写入），输出与基线逐样本相同——「能量不变」此刻不代表组件未生效，
     * 而是诚实的 0ms。非零延迟能量必然变化，仍走通用判据。 */
    if (first < 0) return -3;
    const bool unchanged = fabs(energy - base_energy) <= 1e-9 * (base_energy + 1.0);
    if (unchanged && !strcmp(component, "haas")) {
        *out_samples = 0;
        return 0;
    }
    if (unchanged) return -3;

    long delay = first - (baseline > 0 ? baseline : 0);
    if (delay < 0) delay = 0;
    *out_samples = (uint32_t)delay;
    return 0;
}


int auradsp_probe_component(const char* component, double sample_rate,
                            uint32_t* out_samples) {
    return probe_component_impl(component, nullptr, 0.0f, sample_rate, out_samples);
}


int auradsp_probe_component_with_resource(const char* component,
                                          const char* resource_path,
                                          double sample_rate,
                                          uint32_t* out_samples) {
    return probe_component_impl(component, resource_path, 0.0f, sample_rate,
                                out_samples);
}


/* 带「当前配置」实测：arg 仅 haas 使用——传入用户当前的 haas.delay_ms，
 * 使实测值等于引擎 compute_latency 动态上报口径；其它组件忽略 arg。
 * 保留前两个符号不破坏既有 ABI。 */
int auradsp_probe_component_current(const char* component, double arg,
                                    double sample_rate,
                                    uint32_t* out_samples) {
    return probe_component_impl(component, nullptr, (float)arg, sample_rate,
                                out_samples);
}


/* ---- EQ 曲线：解析 + log-f 重采样（响应探针与 eq.curve 下发共用） ----
 *
 * 刻意抽成共用函数：探针必须与实时链路走**完全相同**的解析与重采样路径。
 * 一旦两边各自实现，探针量到的就不是设备实际产生的曲线，C2 等于用另一套
 * 算法自证。txt 会被就地改写（分词需要可写缓冲），调用方持有可写副本。
 *
 * 可选头 `eqm:<interp>:<op>;`（UI 侧拼接，见 AppModel._pushEqCurve）：
 *   interp = vendor interpolationMode（0=PCHIP，1=Makima）；
 *   op     = vendor operatingMode（0=最小相位 FIR，2=6 阶 IIR，5=12 阶 IIR）。
 * 无头或头非法时回退为历史默认（interp=1，op=0），旧曲线字符串行为不变。
 * 注意 vendor 的 IIR 分支不使用 interpolationMode（见 multimodalEQ.c），
 * 因此 IIR 模式下 interp 选择无声学意义，UI 侧应禁用该选项。 */


/* ---- C2：EQ 实际频率响应实测 ----
 *
 * 问题的本质是两侧算法不同：UI 画的是 log-f 上的 smoothstep 三次插值
 * （interactive_eq.dart 的 _interpolateGain），而引擎走
 * MultimodalEqualizerAxisInterpolation —— makima + **最小相位 IR** + FFT
 * 卷积刷新。最小相位化会让实测幅度偏离用户锚点（过冲、振铃、频带间相互
 * 影响），所以 UI 那条平滑曲线本来就不等于设备产生的响应。
 *
 * 没有「导出系数」这条路：这条链路上 EQ 不是一个解析式滤波器，它就是
 * 一个卷积器，没有可导出的 biquad 系数。改为**直接实测**——私有 jdsp
 * 实例 + 单位冲激 → MultimodalEqualizerProcess → Hann 窗 → FFT → 模 → dB。
 * 这是地面真值，不是再实现一遍近似。
 *
 * 刻意**不用**调用方的 handle：那会和音频线程争同一个 FFTConvolver2x2 的
 * 内部历史（EQ 经 P-006 后 processing 走 activeConv），构成数据竞争。
 * 私有实例走同一份 vendor 代码与同一份解析路径，结果等价且无副作用。
 *
 * 无句柄纯函数，调用方可在任意线程（含 UI isolate）调用。 */
int auradsp_probe_eq_response(int sample_rate, const char* curve, int n_points,
                              double f_max, float* out_db) {
    if (sample_rate < 8000 || sample_rate > 384000) return AURADSP_E_PARAM;
    if (!curve || !out_db || n_points < 2 || n_points > 1024) return AURADSP_E_PARAM;
    const int bytes = (int)strlen(curve);
    if (bytes == 0 || bytes > 4096) return AURADSP_E_PARAM;
    const double nyq = sample_rate * 0.5;
    /* 下限固定 20 Hz：EQ 可视化的常规下限，也是 build_eq_axis 的锚点下界 */
    const double f0 = 20.0;
    double f1 = f_max;
    if (!(f1 > f0)) return AURADSP_E_PARAM;
    if (f1 > nyq * 0.999) f1 = nyq * 0.999;   /* C3：与下发同一条 Nyquist 约束 */

    double freqAx[NUMPTS], gainAx[NUMPTS];
    char* txt = (char*)malloc((size_t)bytes + 1);
    if (!txt) return AURADSP_E_IO;
    memcpy(txt, curve, (size_t)bytes);
    txt[bytes] = 0;
    int interp = 1, op = 0;
    const int npts = build_eq_axis(txt, (double)sample_rate, freqAx, gainAx,
                                   &interp, &op);
    free(txt);
    if (npts < 2) return AURADSP_E_PARAM;

    /* 冲激长度 8192：足够覆盖 makima 最小相位 IR 的有效长度，也给低频留足
     * 分辨率（8192 @48k 的 bin 间隔约 5.9Hz）。 */
    constexpr int kImp = 8192;
    /* JamesDSPLib 体积很大（含全部效果的状态），必须放堆 —— 栈上会直接
     * 溢出，实测 smoke 起来就是 stack overflow。
     * 用 calloc 而非 malloc：JamesDSPInit 开头会 memset 整个结构，但 memset
     * 之前 JamesDSPGlobalMemoryAllocation() 之类的逻辑可能先读指针；
     * 更关键的是 vendor 各 Constructor 之间的调用顺序依赖「指针为 NULL
     * 才走首次分配」这一约定，malloc 的垃圾值会让它们写进野指针。 */
    JamesDSPLib* jd = (JamesDSPLib*)calloc(1, sizeof(JamesDSPLib));
    float* re = (float*)malloc((size_t)kImp * sizeof(float));
    if (!jd || !re) {
        free(re); free(jd);
        return AURADSP_E_IO;
    }
    /* 必须先 global_init()：它做 JamesDSPGlobalMemoryAllocation() + WDL_fft_init()，
     * 分配 vendor 的全局 scratch 与 FFT 查找表。JamesDSPInit 内部直接用这些
     * 全局表，跳过它就是在野指针上跑 —— 实测崩在 0x14A2D8。
     * global_init 自带引用计数，多个探针/多个实例都能安全共用。 */
    global_init();
    JamesDSPInit(jd, kImp, sample_rate);
    /* JamesDSPInit 只在采样率 **不在** [44.1k,48k] 时才分配 tmpBuffer[]
     * （vendor 靠 ASRC 分支顺带分配的副作用）。走 else 分支时 tmpBuffer 全为
     * NULL，直接 MultimodalEqualizerProcess 就是访问违例。
     * 这里显式分配并挂到 blockSizeMax 之后，布局与 vendor 一致。 */
    if (!jd->tmpBuffer[0]) {
        const size_t ctMemBlk = (size_t)jd->blockSizeMax * 2 + (size_t)kImp * 4;
        jd->tmpBuffer[0] = (float*)malloc(ctMemBlk * sizeof(float));
        if (!jd->tmpBuffer[0]) { free(re); free(jd); return AURADSP_E_IO; }
        jd->tmpBuffer[1] = jd->tmpBuffer[0] + jd->blockSizeMax;
        jd->tmpBuffer[2] = jd->tmpBuffer[1] + jd->blockSizeMax;
        jd->tmpBuffer[3] = jd->tmpBuffer[2] + kImp;
        jd->tmpBuffer[4] = jd->tmpBuffer[3] + kImp;
        jd->tmpBuffer[5] = jd->tmpBuffer[4] + kImp;
    }
/* 工作模式取自曲线头的 `eqm:` 元信息，与生产链 `eq.curve` 下发时
     * 解析出的模式完全一致 —— 探针与生产链永远同路。
     * 新创建实例的 `convProcCount - convSwapProc` 已满足 P-006 的换出条件，
     * 因此可以直接重建并换指针，无需先跑一次 Process。 */
MultimodalEqualizerAxisInterpolation(jd, interp, op, freqAx, gainAx);
    MultimodalEqualizerEnable(jd, 1);
    /* 冲激放在窗的 1/4 处，不能放 index 0。
     * Hann 窗 w[0] = 0.5-0.5*cos(0) = 0，冲激若在 0 会被窗本身乘成 0，
     * FFT 之后整条曲线都是 -inf —— 实测平坦曲线整条 -120 就是这个原因，
     * 而不是 EQ 系数或 overallGain 的问题（排查时在这两处各绕了一圈）。 */
    for (int ch = 0; ch < 2; ++ch) {
        memset(jd->tmpBuffer[ch], 0, kImp * sizeof(float));
        jd->tmpBuffer[ch][kImp / 4] = 1.0f;
    }
    MultimodalEqualizerProcess(jd, (size_t)kImp);

    /* Hann 窗 + 实 FFT：冲激响应在窗两端仍有能量，直接 FFT 的谱泄漏足以在
     * ±18dB 的显示范围里被误读成「曲线在抖」。 */
    for (int i = 0; i < kImp; ++i) {
        const double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / (double)(kImp - 1));
        re[i] = jd->tmpBuffer[0][i] * (float)w;
    }
    WDL_real_fft(re, kImp, 0);

    const int half = kImp / 2;
    const int32_t* perm = WDL_fft_permute_tab(half);
    const double bin_hz = (double)sample_rate / (double)kImp;
    const double lf0 = log(f0), lf1 = log(f1);
    for (int i = 0; i < n_points; ++i) {
        const double t = (double)i / (double)(n_points - 1);
        const double f = exp(lf0 + t * (lf1 - lf0));
        int bin = (int)(f / bin_hz + 0.5);
        if (bin < 1) bin = 1;
        if (bin > half - 1) bin = half - 1;
        const int pi = perm ? perm[bin] : bin;
        const double m = sqrt((double)re[pi * 2] * re[pi * 2] +
                              (double)re[pi * 2 + 1] * re[pi * 2 + 1]);
        /* 1e-6 下限避免 log(0) */
        out_db[i] = (float)(20.0 * log10(m > 1e-6 ? m : 1e-6));
    }
    free(re);
    JamesDSPFree(jd);
    free(jd);
    return AURADSP_OK;
}
}  // extern "C"

/* build_eq_axis: C++ linkage (called cross-TU); body moved verbatim. */
int build_eq_axis(char* txt, double sample_rate,
                         double* freqAx, double* gainAx,
                         int* interpMode, int* opMode) {
    int interp = 1, op = 0;
    double pf[64], pg[64];
    int n = 0;
    char* cur = txt;
    if (strncmp(cur, "eqm:", 4) == 0) {
        char* semi = strchr(cur, ';');
        if (semi) {
            int ii = -1, oo = -1;
            if (sscanf(cur, "eqm:%d:%d", &ii, &oo) == 2) {
                if (ii == 0 || ii == 1) interp = ii;
                if (oo >= 0 && oo <= 5) op = oo;
            }
            cur = semi + 1;
        }
    }
    while (cur && n < 64) {
        char* semi = strchr(cur, ';');
        if (semi) *semi = 0;
        char* colon = strchr(cur, ':');
        if (colon) {
            *colon = 0;
            const double f = atof(cur), g = atof(colon + 1);
            /* NaN 会绕过所有 < / > 钳制并污染插值/IR 设计；整对丢弃。 */
            if (std::isfinite(f) && std::isfinite(g) && f > 0 && f <= 96000) {
                /* C3：钳到 Nyquist 以内。只判 <=96000 时，低采样率下越界频点
                 * 会进 vendor 的最小相位 IR 设计。 */
                const double nyq = sample_rate * 0.5;
                pf[n] = (f < nyq) ? f : nyq * 0.999;
                pg[n] = g < -64 ? -64 : (g > 64 ? 64 : g);
                ++n;
            }
        }
        cur = semi ? semi + 1 : nullptr;
    }
    if (n < 2) return 0;
    /* 插入排序按 freq 升序 */
    for (int i = 1; i < n; ++i) {
        const double kf = pf[i], kg = pg[i];
        int j = i - 1;
        while (j >= 0 && pf[j] > kf) { pf[j + 1] = pf[j]; pg[j + 1] = pg[j]; --j; }
        pf[j + 1] = kf; pg[j + 1] = kg;
    }
    /* 补齐到 NUMPTS：对数频率域均匀重采样（EQ 插值工作在 log-f 域，
     * 线性采样会把 UI 轴点挤掉——烟囱测试抓回） */
    const double lf0 = log(pf[0]), lf1 = log(pf[n - 1]);
    for (int i = 0; i < NUMPTS; ++i) {
        const double t = (NUMPTS == 1) ? 0.0 : (double)i / (double)(NUMPTS - 1);
        const double target = exp(lf0 + t * (lf1 - lf0));
        int seg = 0;
        while (seg < n - 2 && pf[seg + 1] < target) ++seg;
        const double ls0 = log(pf[seg]), ls1 = log(pf[seg + 1]);
        const double k = (ls1 - ls0) > 1e-9
            ? (log(target) - ls0) / (ls1 - ls0) : 0.0;
        freqAx[i] = target;
        gainAx[i] = pg[seg] + k * (pg[seg + 1] - pg[seg]);
    }
    if (interpMode) *interpMode = interp;
    if (opMode) *opMode = op;
    return n;
}
