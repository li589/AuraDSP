/* P spatial: L1 参数化 HRTF + 早期反射（影院/定位/中性三预设）
 * 位置：haas 后 / exciter 前（空间族最后一道音色工序之前）。
 * 参考：docs/10-架构/空间音效升级方案-2026-10-18.md
 *   5.0 虚拟扬声器（L-30/C0/R+30/LS-110/RS+110）→ 每源 ITD（Woodworth）
 *   + ILD（头影低通/远耳增益）+ 每源/每耳方向 pinna → 早期反射（8 tap 对称）
 *   → 输出增益 / 干湿比 / autogain。
 * 输入：立体声上混（L→L/LS，R→R/RS，C 取中置和；v1 不做 5.1 分离）。
 * RT：全部固定数组预分配；音频线程零分配/零锁/无 IO。
 * 头跟踪：spatial.headazim 始终作为手动/外部朝向消费；DSP 只做块级平滑。
 * 注意：本文件为 clean-room 参数模型，不包含第三方 HRIR 数据。 */
#include "engine_internal.h"

#include <cmath>
#include <cstring>

namespace {

// kSpatSpk/kSpatItdLen/kSpatHistLen 在 handle 结构体（engine_internal.h）
constexpr float kSpatDeg[5] = {-30.0f, 0.0f, 30.0f, -110.0f, 110.0f};
// 早期反射 tap（ms）L/R 交替；8 tap 严格配对，保证 mono 下左右能量相等
constexpr float kSpatTapMs[8] =
    {5.5f, 9.0f, 14.0f, 21.0f, 30.0f, 42.0f, 55.0f, 68.0f};
constexpr float kSpatTapG[8] =
    {0.250f, -0.250f, 0.180f, -0.180f, 0.120f, -0.120f, 0.070f, -0.070f};
constexpr float kSpatHeadR = 0.0875f;  // 头半径（m）
constexpr float kSpatSoundC = 343.0f;  // 声速（m/s）
constexpr float kPiF = 3.14159265358979f;

static_assert(sizeof(kSpatDeg) / sizeof(kSpatDeg[0]) ==
                  auradsp_handle_s::kSpatSpk,
              "speaker table must match handle state");

inline float spat_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

inline float spat_wrap_deg(float deg) {
    while (deg > 180.0f) deg -= 360.0f;
    while (deg < -180.0f) deg += 360.0f;
    return deg;
}

}  // namespace


/* RBJ peaking 系数（每块现算；fs 相关，控制线程无法预计算） */
static inline void spat_peaking(float fs, float fc, float q, float dbg,
                                float* b0, float* b1, float* b2, float* a1,
                                float* a2) {
    fc = spat_clampf(fc, 20.0f, fs * 0.45f);
    const float w0 = 2.0f * kPiF * fc / fs;
    const float c = cosf(w0), s = sinf(w0);
    const float a = powf(10.0f, dbg / 40.0f);
    const float alpha = s / (2.0f * q);
    const float a0 = 1.0f + alpha / a;
    *b0 = (1.0f + alpha * a) / a0;
    *b1 = (-2.0f * c) / a0;
    *b2 = (1.0f - alpha * a) / a0;
    *a1 = (-2.0f * c) / a0;
    *a2 = (1.0f - alpha / a) / a0;
}

/* DF1 biquad；state = {x1,x2,y1,y2} */
static inline float spat_bq(float* st, float b0, float b1, float b2,
                            float a1, float a2, float x) {
    const float y = b0 * x + b1 * st[0] + b2 * st[1]
                    - a1 * st[2] - a2 * st[3];
    st[1] = st[0];
    st[0] = x;
    st[3] = st[2];
    st[2] = y;
    return y;
}


/* 控制线程/开关切换时调用：清空全部 RT 状态，避免残留瞬态。
 * 不在音频线程调用。 */
void spatial_reset(auradsp_handle h) {
    if (!h) return;
    for (int s = 0; s < auradsp_handle_s::kSpatSpk; ++s) {
        memset(h->spat_ring[s], 0, sizeof(h->spat_ring[s]));
        h->spat_ring_pos[s] = 0;
        h->spat_lp[s] = 0.0f;
        memset(h->spat_src_pinna[s], 0, sizeof(h->spat_src_pinna[s]));
    }
    memset(h->spat_hist, 0, sizeof(h->spat_hist));
    h->spat_hist_pos = 0;
    memset(h->spat_pinna, 0, sizeof(h->spat_pinna));
    h->spat_ag_in = 0.0;
    h->spat_ag_out = 0.0;
    h->spat_ag_comp = 1.0;
    h->spat_g_sm = 1.0f;

    const float mix = spat_clampf(
        h->p.spatial_mix.load(std::memory_order_relaxed), 0.0f, 1.0f);
    h->spat_mix_sm = mix;
    h->spat_headazim_sm = spat_clampf(
        h->p.spatial_headazim.load(std::memory_order_relaxed), -180.0f, 180.0f);
}


void spatial_process(auradsp_handle h, float* io, int frames) {
    if (!h || !io || frames <= 0) return;

    const float fs = (h->jdsp.fs > 0.0f) ? (float)h->jdsp.fs : 48000.0f;
    const float room = spat_clampf(
        h->p.spatial_room.load(std::memory_order_relaxed), 0.0f, 1.0f);
    const float width = spat_clampf(
        h->p.spatial_width.load(std::memory_order_relaxed), 0.5f, 1.5f);
    const float center = spat_clampf(
        h->p.spatial_center.load(std::memory_order_relaxed), 0.0f, 1.0f);
    const float outgDb = h->p.spatial_outgain.load(std::memory_order_relaxed);
    const bool ag = h->p.spatial_autogain.load(std::memory_order_relaxed) != 0;
    const float mixTarget = spat_clampf(
        h->p.spatial_mix.load(std::memory_order_relaxed), 0.0f, 1.0f);
    const float elev = spat_clampf(
        h->p.spatial_elevation.load(std::memory_order_relaxed), -30.0f, 30.0f);

    // 头跟踪：块级平滑（~15ms），避免参数/传感器跳变造成声像台阶
    const float headTarget = spat_clampf(
        h->p.spatial_headazim.load(std::memory_order_relaxed), -180.0f, 180.0f);
    float head = h->spat_headazim_sm;
    if (!(head == head)) head = headTarget;
    const float blockTau = 0.015f;
    const float blockAlpha = expf(-(float)frames / (blockTau * fs));
    head = blockAlpha * head + (1.0f - blockAlpha) * headTarget;
    if (!(head == head)) head = headTarget;

    // 每源方位（已应用头旋转）
    float srcDeg[5];
    for (int s = 0; s < 5; ++s) {
        srcDeg[s] = spat_wrap_deg(kSpatDeg[s] * width - head);
    }

    // 每源 ITD / ILD 系数
    float itdSamp[5];
    float farGain[5];
    float farLpA[5];
    for (int s = 0; s < 5; ++s) {
        const float deg = srcDeg[s];
        const float th = fabsf(deg) * kPiF / 180.0f;
        const float itdSec = kSpatHeadR / kSpatSoundC * (th + sinf(th));
        float d = itdSec * fs;
        d = spat_clampf(d, 0.0f, 127.0f);
        itdSamp[s] = d;

        const float ax = spat_clampf(th / (kPiF * 0.5f), 0.0f, 1.0f);
        farGain[s] = 1.0f - 0.5f * ax;  // 远端 -6dB

        const float ax2 = spat_clampf(th / (110.0f * kPiF / 180.0f), 0.0f, 1.0f);
        const float fc = spat_clampf(8000.0f - 5500.0f * ax2, 1500.0f, 8000.0f);
        farLpA[s] = 1.0f - expf(-2.0f * kPiF * fc / fs);
    }

    // 每源/每耳方向 pinna：stage0 前后向，stage1 仰角 notch 移动
    float pb0[5][2][2], pb1[5][2][2], pb2[5][2][2];
    float pa1[5][2][2], pa2[5][2][2];
    const float ev = spat_clampf(elev / 30.0f, -1.0f, 1.0f);
    for (int s = 0; s < 5; ++s) {
        const float deg = srcDeg[s];
        const bool rear = fabsf(deg) > 90.0f;
        for (int ear = 0; ear < 2; ++ear) {
            const bool isFar = (deg > 0.5f && ear == 0) ||
                               (deg < -0.5f && ear == 1);
            float g0 = rear ? -4.0f : 2.2f;
            if (isFar) g0 -= 1.0f;
            spat_peaking(fs, rear ? 10500.0f : 8200.0f, 1.1f, g0,
                         &pb0[s][ear][0], &pb1[s][ear][0], &pb2[s][ear][0],
                         &pa1[s][ear][0], &pa2[s][ear][0]);

            const float fc1 = 7200.0f + 2600.0f * ev;
            const float g1 = -2.2f * (0.7f + 0.3f * fabsf(ev));
            spat_peaking(fs, fc1, 2.0f, g1,
                         &pb0[s][ear][1], &pb1[s][ear][1], &pb2[s][ear][1],
                         &pa1[s][ear][1], &pa2[s][ear][1]);
        }
    }

    // 反射总线 pinna（保留原全局双 biquad，仅作用于早期反射）
    float rb0[2], rb1[2], rb2[2], ra1[2], ra2[2];
    spat_peaking(fs, 8000.0f, 1.0f, 2.5f,
                 &rb0[0], &rb1[0], &rb2[0], &ra1[0], &ra2[0]);
    spat_peaking(fs, 12500.0f, 2.0f, -3.0f,
                 &rb0[1], &rb1[1], &rb2[1], &ra1[1], &ra2[1]);

    const float tscale = 0.5f + 1.5f * room;
    const float outG = powf(10.0f, spat_clampf(outgDb, -12.0f, 6.0f) * 0.05f);

    double rin = 0.0;
    if (ag) {
        double e = 0.0;
        for (int i = 0; i < frames * 2; ++i) e += (double)io[i] * io[i];
        rin = sqrt(e / (double)(frames * 2) + 1e-12);
    }

    const float alpha = (float)exp(-1.0 / (0.002 * (double)fs));
    const float beta = 1.0f - alpha;
    float g_sm = h->spat_g_sm;
    float mix_sm = h->spat_mix_sm;

    for (int i = 0; i < frames; ++i) {
        const float inL = io[i * 2], inR = io[i * 2 + 1];
        const float mC = 0.5f * (inL + inR) * center;
        const float mSpk[5] = {inL, mC, inR, inL * 0.7f, inR * 0.7f};
        float oL = 0.0f, oR = 0.0f;

        for (int s = 0; s < 5; ++s) {
            const float m = mSpk[s];
            const float deg = srcDeg[s];

            // 中置/正前方：双耳同幅，但走完整方向 pinna
            if (fabsf(deg) < 0.5f) {
                float l = spat_bq(h->spat_src_pinna[s][0][0],
                                  pb0[s][0][0], pb1[s][0][0], pb2[s][0][0],
                                  pa1[s][0][0], pa2[s][0][0], m);
                l = spat_bq(h->spat_src_pinna[s][0][1],
                            pb0[s][0][1], pb1[s][0][1], pb2[s][0][1],
                            pa1[s][0][1], pa2[s][0][1], l);
                float r = spat_bq(h->spat_src_pinna[s][1][0],
                                  pb0[s][1][0], pb1[s][1][0], pb2[s][1][0],
                                  pa1[s][1][0], pa2[s][1][0], m);
                r = spat_bq(h->spat_src_pinna[s][1][1],
                            pb0[s][1][1], pb1[s][1][1], pb2[s][1][1],
                            pa1[s][1][1], pa2[s][1][1], r);
                oL += l;
                oR += r;
                // 保持该源延迟线/状态连续，避免旋转离开中置时读到陈旧样本
                float* ring = h->spat_ring[s];
                int pos = h->spat_ring_pos[s];
                ring[pos] = m;
                if (++pos >= 128) pos = 0;
                h->spat_ring_pos[s] = pos;
                continue;
            }

            const bool nearR = deg > 0.0f;
            const int nearEar = nearR ? 1 : 0;
            const int farEar = nearR ? 0 : 1;

            // 近耳直达 + 方向 pinna
            float nearSig = spat_bq(h->spat_src_pinna[s][nearEar][0],
                                    pb0[s][nearEar][0], pb1[s][nearEar][0],
                                    pb2[s][nearEar][0], pa1[s][nearEar][0],
                                    pa2[s][nearEar][0], m);
            nearSig = spat_bq(h->spat_src_pinna[s][nearEar][1],
                              pb0[s][nearEar][1], pb1[s][nearEar][1],
                              pb2[s][nearEar][1], pa1[s][nearEar][1],
                              pa2[s][nearEar][1], nearSig);
            if (nearR) oR += nearSig; else oL += nearSig;

            // 远耳：ITD 延迟 + 头影低通 + ILD + 方向 pinna
            float* ring = h->spat_ring[s];
            int pos = h->spat_ring_pos[s];
            ring[pos] = m;
            const float d = itdSamp[s];
            const int di = (int)d;
            const float frac = d - (float)di;
            int i0 = pos - di;
            i0 %= 128; if (i0 < 0) i0 += 128;
            int i1 = i0 - 1; if (i1 < 0) i1 += 128;
            const float delayed = ring[i0] * (1.0f - frac) + ring[i1] * frac;
            float y = h->spat_lp[s] + farLpA[s] * (delayed - h->spat_lp[s]);
            if (fabsf(y) < 1e-15f) y = 0.0f;
            h->spat_lp[s] = y;
            float farSig = y * farGain[s];
            farSig = spat_bq(h->spat_src_pinna[s][farEar][0],
                             pb0[s][farEar][0], pb1[s][farEar][0],
                             pb2[s][farEar][0], pa1[s][farEar][0],
                             pa2[s][farEar][0], farSig);
            farSig = spat_bq(h->spat_src_pinna[s][farEar][1],
                             pb0[s][farEar][1], pb1[s][farEar][1],
                             pb2[s][farEar][1], pa1[s][farEar][1],
                             pa2[s][farEar][1], farSig);
            if (nearR) oL += farSig; else oR += farSig;

            if (++pos >= 128) pos = 0;
            h->spat_ring_pos[s] = pos;
        }

        // 早期反射（mono 下混历史；8 tap ±配对）
        float eL = 0.0f, eR = 0.0f;
        h->spat_hist[h->spat_hist_pos] = 0.5f * (inL + inR);
        if (room > 0.001f) {
            for (int t = 0; t < 8; ++t) {
                int off = (int)(kSpatTapMs[t] * tscale * fs / 1000.0f);
                if (off >= 32768) off = 32767;
                if (off < 0) off = 0;
                int rp = h->spat_hist_pos - off;
                rp %= 32768; if (rp < 0) rp += 32768;
                const float te = h->spat_hist[rp] * kSpatTapG[t] * room;
                if ((t & 1) == 0) eL += te; else eR += te;
            }
        }
        if (++h->spat_hist_pos >= 32768) h->spat_hist_pos = 0;

        // 反射总线走原全局 pinna；直达声已按源/耳处理，不再二次滤波
        eL = spat_bq(h->spat_pinna[0][0], rb0[0], rb1[0], rb2[0],
                     ra1[0], ra2[0], eL);
        eL = spat_bq(h->spat_pinna[1][0], rb0[1], rb1[1], rb2[1],
                     ra1[1], ra2[1], eL);
        eR = spat_bq(h->spat_pinna[0][1], rb0[0], rb1[0], rb2[0],
                     ra1[0], ra2[0], eR);
        eR = spat_bq(h->spat_pinna[1][1], rb0[1], rb1[1], rb2[1],
                     ra1[1], ra2[1], eR);

        // 等能量归一化（消除多源直加的能量暴涨）
        const float spat_norm = 1.0f /
            sqrtf(2.0f + 0.5f * center * center + 0.98f +
                  (room > 0.001f ? room * 0.4f : 0.0f));
        g_sm = alpha * g_sm + beta * outG;
        const float wetL = (oL + eL) * spat_norm * g_sm;
        const float wetR = (oR + eR) * spat_norm * g_sm;

        mix_sm = alpha * mix_sm + beta * mixTarget;
        io[i * 2] = inL + (wetL - inL) * mix_sm;
        io[i * 2 + 1] = inR + (wetR - inR) * mix_sm;
    }

    h->spat_g_sm = (fabsf(g_sm) < 1e-15f) ? 0.0f : g_sm;
    h->spat_mix_sm = spat_clampf(mix_sm, 0.0f, 1.0f);
    h->spat_headazim_sm = head;

    // 自动增益（与 reverb 同式；mix=0 时保持纯直通，不做增益改写）
    if (ag && mixTarget > 0.001f) {
        double e = 0.0;
        for (int i = 0; i < frames * 2; ++i) e += (double)io[i] * io[i];
        const double rout = sqrt(e / (double)(frames * 2) + 1e-12);
        h->spat_ag_in += (rin - h->spat_ag_in) * 0.05;
        h->spat_ag_out += (rout - h->spat_ag_out) * 0.05;
        double desired = 1.0;
        if (h->spat_ag_in > 1e-6 && h->spat_ag_out > 1e-6)
            desired = h->spat_ag_in / h->spat_ag_out;
        desired = (desired < 0.25) ? 0.25 : ((desired > 4.0) ? 4.0 : desired);
        h->spat_ag_comp += (desired - h->spat_ag_comp) * 0.1;
        const float g = (float)h->spat_ag_comp;
        if (g != 1.0f) {
            for (int i = 0; i < frames * 2; ++i) io[i] *= g;
        }
    }
}
