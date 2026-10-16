/* P spatial: L1 参数化 HRTF + 早期反射（Dolby 房默认）。
 * 位置：haas 后 / exciter 前（空间族抱团，最后一道音色工序之前）。
 * 设计（见 docs/20-执行/空间音效卡与空间核心方案-2026-10-16.md）：
 *   5.0 虚拟扬声器摆位（L-30/C0/R+30/LS-110/RS+110）→ 每扬声器近耳直达、
 *   远耳 ITD（Woodworth）+ ILD（头影衰减）+ 头影低通 → 全局 pinna 双 biquad
 *   点缀 → 早期反射（8 离散 tap ±配对，room 缩放）→ outgain → autogain。
 * 输入：立体声上混（L→L/LS，R→R/RS，C 取中置和；v1 不做真 5.1 分离）。
 * RT 安全：固定环形缓冲（ITD 128/反射 32768，随 handle 分配，零 RT 分配）；
 *   参数每块快照一次；延迟线整数读写 + ITD 线性插值；次正常数截断；
 *   NaN 由链尾全局守卫处理（与 haas 同口径）。
 * 与 ViPER 系无任何代码关系：全部公式为公开声学常识（Woodworth/RBJ），
 *   实现为 clean-room 独立编写。 */
#include "engine_internal.h"

#include <cmath>

namespace {

// kSpatSpk/kSpatItdLen/kSpatHistLen 见 handle 结构体（engine_internal.h），
// 此处只放纯 DSP 常量。
// 虚拟扬声器表：方位角（度，右为正）+ 基础增益
constexpr float kSpatDeg[5] = {-30.0f, 0.0f, 30.0f, -110.0f, 110.0f};
// 早期反射 tap（ms，L/R 交错，相位交替扩散感）
// 注：8 tap ±配对（偶→L 奇→R，同 |g|），保证左右反射能量严格相等；
// 7 tap 时左 4 右 3 能量左偏（Σg² 0.102 vs 0.063），mono 下 L/R 差 7%。
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

}  // namespace


/* RBJ peaking 系数（每块现算；fs 相关，控制线程无法预先算好）。 */
static inline void spat_peaking(float fs, float fc, float q, float dbg,
                                float* b0, float* b1, float* b2, float* a1,
                                float* a2) {
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


void spatial_process(auradsp_handle h, float* io, int frames) {
    const float fs =
        (h->jdsp.fs > 0.0f) ? (float)h->jdsp.fs : 48000.0f;
    // 参数快照（每块一次；x86 对齐字无撕裂）
    float room = h->p.spatial_room.load(std::memory_order_relaxed);
    if (room < 0.0f) room = 0.0f; if (room > 1.0f) room = 1.0f;
    float width = h->p.spatial_width.load(std::memory_order_relaxed);
    if (width < 0.5f) width = 0.5f; if (width > 1.5f) width = 1.5f;
    float center = h->p.spatial_center.load(std::memory_order_relaxed);
    if (center < 0.0f) center = 0.0f; if (center > 1.0f) center = 1.0f;
    const float outgDb = h->p.spatial_outgain.load(std::memory_order_relaxed);
    const bool ag = h->p.spatial_autogain.load(std::memory_order_relaxed) != 0;

    // 扬声器级系数（随 width 变化，每块重算，便宜）
    float itdSamp[5];
    float farGain[5];
    float farLpA[5];
    for (int s = 0; s < 5; ++s) {
        float deg = kSpatDeg[s] * width;
        if (deg < -160.0f) deg = -160.0f; if (deg > 160.0f) deg = 160.0f;
        const float th = fabsf(deg) * kPiF / 180.0f;
        const float itdSec = kSpatHeadR / kSpatSoundC * (th + sinf(th));
        float d = itdSec * fs;
        if (d < 0.0f) d = 0.0f;
        if (d > 127.0f) d = 127.0f;
        itdSamp[s] = d;
        float ax = th / (kPiF * 0.5f);
        if (ax > 1.0f) ax = 1.0f;
        farGain[s] = 1.0f - 0.5f * ax;  // 最多 -6dB
        float ax2 = th / (110.0f * kPiF / 180.0f);
        if (ax2 > 1.0f) ax2 = 1.0f;
        float fc = 8000.0f - 5500.0f * ax2;
        if (fc < 1500.0f) fc = 1500.0f;
        farLpA[s] = 1.0f - expf(-2.0f * kPiF * fc / fs);
    }

    // pinna 双 biquad 系数（固定签名，只随 fs 变）
    float b0[2], b1[2], b2[2], a1[2], a2[2];
    spat_peaking(fs, 8000.0f, 1.0f, 2.5f, &b0[0], &b1[0], &b2[0], &a1[0], &a2[0]);
    spat_peaking(fs, 12500.0f, 2.0f, -3.0f, &b0[1], &b1[1], &b2[1], &a1[1], &a2[1]);

    // 早期反射时间缩放 + 电平
    const float tscale = 0.5f + 1.5f * room;
    const float outG = powf(10.0f, (outgDb < -12.0f ? -12.0f : (outgDb > 6.0f ? 6.0f : outgDb)) * 0.05f);

    double rin = 0.0;
    if (ag) {
        double e = 0.0;
        for (int i = 0; i < frames * 2; ++i) e += (double)io[i] * io[i];
        rin = sqrt(e / (double)(frames * 2) + 1e-12);
    }

    for (int i = 0; i < frames; ++i) {
        const float inL = io[i * 2], inR = io[i * 2 + 1];
        // 立体声上混 → 5 扬声器 mono
        const float mC = 0.5f * (inL + inR) * center;
        const float mSpk[5] = {inL, mC, inR, inL * 0.7f, inR * 0.7f};
        float oL = 0.0f, oR = 0.0f;
        for (int s = 0; s < 5; ++s) {
            const float m = mSpk[s];
            float deg = kSpatDeg[s] * width;
            if (deg < -160.0f) deg = -160.0f; if (deg > 160.0f) deg = 160.0f;
            if (fabsf(deg) < 0.5f) {
                oL += m; oR += m;  // 中置：双耳等同
                continue;
            }
            const bool nearR = deg > 0.0f;
            // 近耳直达
            if (nearR) oR += m; else oL += m;
            // 远耳：ITD 延迟线（线性插值）+ 头影低通 + ILD
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
            const float contrib = y * farGain[s];
            if (nearR) oL += contrib; else oR += contrib;
            if (++pos >= 128) pos = 0;
            h->spat_ring_pos[s] = pos;
        }
        // 早期反射（输入 mono 历史；room==0 整段跳过）
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
        float yL = oL + eL, yR = oR + eR;
        // pinna 双 biquad（DF1，固定签名）
        for (int st = 0; st < 2; ++st) {
            float* sL = h->spat_pinna[st][0];
            float* sR = h->spat_pinna[st][1];
            float o = b0[st] * yL + b1[st] * sL[0] + b2[st] * sL[1]
                      - a1[st] * sL[2] - a2[st] * sL[3];
            sL[1] = sL[0]; sL[0] = yL; sL[3] = sL[2]; sL[2] = o;
            yL = o;
            o = b0[st] * yR + b1[st] * sR[0] + b2[st] * sR[1]
                      - a1[st] * sR[2] - a2[st] * sR[3];
            sR[1] = sR[0]; sR[0] = yR; sR[3] = sR[2]; sR[2] = o;
            yR = o;
        }
        if (fabsf(yL) < 1e-15f) yL = 0.0f;
        if (fabsf(yR) < 1e-15f) yR = 0.0f;
        io[i * 2] = yL * outG;
        io[i * 2 + 1] = yR * outG;
    }

    // 自动增益（reverb 同式：慢跟随收敛到输入响度，0.25..4 钳位）
    if (ag) {
        double e = 0.0;
        for (int i = 0; i < frames * 2; ++i) e += (double)io[i] * io[i];
        const double rout = sqrt(e / (double)(frames * 2) + 1e-12);
        h->spat_ag_in += (rin - h->spat_ag_in) * 0.05;
        h->spat_ag_out += (rout - h->spat_ag_out) * 0.05;
        double desired = 1.0;
        if (h->spat_ag_in > 1e-6 && h->spat_ag_out > 1e-6)
            desired = h->spat_ag_in / h->spat_ag_out;
        if (desired < 0.25) desired = 0.25;
        if (desired > 4.0) desired = 4.0;
        h->spat_ag_comp += (desired - h->spat_ag_comp) * 0.1;
        const float g = (float)h->spat_ag_comp;
        if (g != 1.0f) {
            for (int i = 0; i < frames * 2; ++i) io[i] *= g;
        }
    }
}
