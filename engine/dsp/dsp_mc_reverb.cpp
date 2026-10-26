/* WP1：离散多声道 FDN 混响（N 进 N 出）。
 *
 * 设计见 docs/20-执行/多声道重构与混响边界工程-2026-10-25.md §3.3：
 *   8 条延迟线（29.7..73.9ms @44.1k 基准，按 roomScale 缩放）
 *   + 8×8 Hadamard 反馈（正交归一）
 *   + N×8 输入矩阵 / 8×N 输出矩阵（同一个 Hadamard 的前 N 行）
 *   + 每线一阶阻尼、每声道分数预延迟、可选 LFE 120Hz 低通入/出。
 *
 * 只在 channels.mode==1 且非双耳路径运行。立体声/矩阵/双耳路径使用
 * vendor Progenitor2；两套混响永不同时运行。
 */
#include "engine_internal.h"

namespace {

constexpr float kPiF = 3.14159265358979f;

/* 基准延迟线长度（ms @44.1k 经典值，沿用旧 spatial FDN 的 kMs）。 */
constexpr float kMs[8] = {29.7f, 37.1f, 41.1f, 43.7f,
                          53.3f, 59.9f, 67.7f, 73.9f};

/* curated 预设参数（UI 的 8 个 chip）。 */
struct McPresetParams {
    float rt60;       /* 秒 */
    float room;       /* roomScale */
    float damp_hz;    /* 每线低通截止 */
    float wet;        /* 0..1 */
    float width;      /* 0.2..2.0（MC 宽度语义） */
    float pre_ms;     /* 预设基础预延迟 */
};

/* 顺序：大音乐厅(5)、音乐厅(3)、中音乐厅(1)、小音乐厅(2)、
 *       录音棚(9)、房间(7)、大礼堂(11)、板式(15)。 */
constexpr McPresetParams kCurated[8] = {
    {3.2f, 1.6f, 7000.0f, 0.45f, 1.00f, 20.0f}, /* 5  LARGEHALL1 */
    {2.3f, 1.2f, 8000.0f, 0.40f, 1.00f, 10.0f}, /* 3  MEDIUMHALL1 */
    {2.1f, 1.0f, 9000.0f, 0.35f, 0.90f, 10.0f}, /* 1  SMALLHALL1 */
    {1.8f, 0.9f, 9000.0f, 0.30f, 0.85f,  8.0f}, /* 2  SMALLHALL2 */
    {1.2f, 0.8f, 10000.0f, 0.28f, 0.80f, 8.0f}, /* 9  MEDIUMROOM1 */
    {0.8f, 0.65f, 10000.0f, 0.25f, 0.75f, 5.0f}, /* 7  SMALLROOM1 */
    {2.9f, 1.5f, 6000.0f, 0.35f, 1.00f, 18.0f}, /* 11 LARGEROOM1 */
    {1.9f, 1.0f, 12000.0f, 0.35f, 0.90f, 5.0f}, /* 15 PLATEHIGH */
};

/* vendor 预设 ID 0..18 → curated 表下标。非 curated 旧会话按文档
 * §3.5 的 kMcPresetMap 就近映射，保证旧会话不静音、不突变到极端房间。 */
constexpr int kCuratedIdx[19] = {
    0, 2, 3, 1, 1, 0, 0, 5, 5, 4, 4, 6, 6, 1, 1, 7, 7, 0, 0,
};

inline float mc_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

/* 8 点快速 Hadamard（正交，1/sqrt(8) 归一）。 */
inline void mc_hadamard8(float* v) {
    for (int h = 1; h < 8; h <<= 1) {
        for (int i = 0; i < 8; i += (h << 1)) {
            for (int j = i; j < i + h; ++j) {
                const float a = v[j], b = v[j + h];
                v[j] = a + b;
                v[j + h] = a - b;
            }
        }
    }
    const float s = 0.35355339f; /* 1/sqrt(8) */
    for (int i = 0; i < 8; ++i) v[i] *= s;
}

/* Hadamard 符号矩阵：sign(r,c) = (-1)^popcount(r&c)。 */
inline float mc_hadamard_sign(int r, int c) {
    int bits = r & c;
    bits ^= bits >> 1;
    bits ^= bits >> 2;
    return ((bits & 1) == 0) ? 0.35355339f : -0.35355339f;
}

inline double mc_block_rms(const float* io, int n) {
    double acc = 0.0;
    for (int i = 0; i < n; ++i) acc += (double)io[i] * io[i];
    return sqrt(acc / (double)(n > 0 ? n : 1));
}

/* 清 FDN 全部 RT 状态。只在 create（未 open）或 RT 线程淡出完成后调用。 */
void mc_clear_state(McReverbState& s) {
    for (int i = 0; i < McReverbState::kLines; ++i) {
        memset(s.buf[i], 0, sizeof(s.buf[i]));
        memset(s.pre_buf[i], 0, sizeof(s.pre_buf[i]));
        s.pos[i] = 0;
        s.len[i] = 1;
        s.lp[i] = 0.0f;
        s.fb[i] = 0.5f;
    }
    s.pre_pos = 0;
    s.pre_len_sm = 0.0f;
    s.pre_init = false;
    s.lfe_in_lp = 0.0f;
    s.lfe_out_lp = 0.0f;
    s.damp = 0.0f;
    s.rt60 = 0.0f;
    s.room_scale = 0.0f;
    s.fade = 1.0f;
    s.fading_out = false;
}

}  // namespace

void mc_reverb_reset(auradsp_handle h) {
    if (!h) return;
    if (h->open.load(std::memory_order_acquire)) {
        /* RT 正在跑：请求淡出后清状态，避免湿声瞬间归零的爆音。 */
        h->mc_rev.reset_req.store(1, std::memory_order_relaxed);
    } else {
        mc_clear_state(h->mc_rev);
        h->mc_rev.reset_req.store(0, std::memory_order_relaxed);
        h->rev_ag_in = h->rev_ag_out = 0.0;
        h->rev_ag_comp = 1.0;
        h->rev_g_sm = 1.0f;
    }
}

void mc_reverb_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || !io || frames <= 0 || ch <= 0) return;
    const int32_t preset = h->p.reverb_preset.load(std::memory_order_relaxed);
    if (preset == -1 || preset < -2) return; /* -1 关；越界不应到达 */

    McReverbState& s = h->mc_rev;
    const float fs = (h->sample_rate > 8000.0f) ? h->sample_rate : 48000.0f;

    /* ---- 参数解析：预设表 / 自定义映射（§3.3 / §3.5） ---- */
    float rt60, room, damp_hz, wet, dry, width, pre_ms;
    if (preset == -2) {
        const float decay = mc_clampf(h->p.fv_decay.load(std::memory_order_relaxed), 0.0f, 1.0f);
        rt60 = 0.5f + 5.5f * decay;
        room = mc_clampf(h->p.fv_roomsize.load(std::memory_order_relaxed), 0.5f, 2.0f);
        damp_hz = 18000.0f * powf(1.0f / 18.0f,
                                   mc_clampf(h->p.fv_damp.load(std::memory_order_relaxed), 0.0f, 1.0f));
        wet = mc_clampf(h->p.fv_wet.load(std::memory_order_relaxed), 0.0f, 1.0f);
        dry = mc_clampf(h->p.fv_dry.load(std::memory_order_relaxed), 0.0f, 1.0f);
        width = mc_clampf(h->p.fv_width.load(std::memory_order_relaxed), 0.2f, 2.0f);
        pre_ms = 0.0f; /* 自定义模式基础预延迟为 0，只叠加 reverb.predelay */
    } else {
        const McPresetParams& p = kCurated[kCuratedIdx[preset]];
        rt60 = p.rt60;
        room = p.room;
        damp_hz = p.damp_hz;
        wet = p.wet;
        dry = 1.0f;
        width = p.width;
        pre_ms = p.pre_ms;
    }
    pre_ms += h->p.reverb_predelay.load(std::memory_order_relaxed);
    pre_ms = mc_clampf(pre_ms, 0.0f, 100.0f);

    /* ---- 每块参数更新（不重分配；只改有效长度/反馈/阻尼） ---- */
    if (rt60 != s.rt60 || room != s.room_scale) {
        s.rt60 = rt60;
        s.room_scale = room;
        for (int i = 0; i < McReverbState::kLines; ++i) {
            int len = (int)(kMs[i] * 0.001f * fs * room + 0.5f);
            if (len < 2) len = 2;
            if (len > McReverbState::kMax - 1) len = McReverbState::kMax - 1;
            s.len[i] = len;
            float g = powf(10.0f, -3.0f * (float)len / (rt60 * fs));
            if (g > 0.995f) g = 0.995f;
            s.fb[i] = g;
        }
    }
    s.damp = 1.0f - expf(-2.0f * kPiF * damp_hz / fs);

    /* ---- 输入/输出矩阵（Hadamard 前 N 行；对称矩阵，输入输出同表） ---- */
    float m[8][8];
    for (int r = 0; r < 8; ++r)
        for (int c = 0; c < 8; ++c) m[r][c] = mc_hadamard_sign(r, c);

    /* ---- 预延迟：分数延迟 + 块级线性平滑 ---- */
    const int kPreMax = McReverbState::kPreMax;
    float pre_target = pre_ms * 0.001f * fs;
    if (pre_target > (float)(kPreMax - 4)) pre_target = (float)(kPreMax - 4);
    if (!s.pre_init) {
        s.pre_len_sm = pre_target;
        s.pre_init = true;
    }
    const float pre_step = (pre_target - s.pre_len_sm) / (float)frames;

    const SpeakerLayout ly = layout_for(ch);

    /* ---- LFE（layout_for(ch).lfe；默认不进 FDN） ---- */
    const int lfe_idx = ly.lfe;
    const bool lfe_on =
        (lfe_idx >= 0) && (h->p.reverb_lfe.load(std::memory_order_relaxed) != 0);
    const float lfe_a = 1.0f - expf(-2.0f * kPiF * 120.0f / fs);

    /* ---- 干湿等能量归一（沿用 Freeverb 校准常数） ---- */
    float wetG = wet * 0.7f;
    float dryG = dry;
    const float norm = 1.0f / sqrtf(fmaxf(0.01f, dryG * dryG + wetG * wetG));
    dryG *= norm;
    wetG *= norm;

    /* ---- 自动增益计量（全声道） ---- */
    const bool ag = h->p.reverb_autogain.load(std::memory_order_relaxed) != 0;
    const int total = frames * ch;
    double rin = 0.0;
    if (ag) rin = mc_block_rms(io, total);

    /* ---- 宽度只处理 FL/FR、SL/SR、BL/BR；C/LFE 不动 ---- */
    int pairs[3][2];
    int np = 0;
    if (ly.fl >= 0 && ly.fr >= 0) { pairs[np][0] = ly.fl; pairs[np][1] = ly.fr; ++np; }
    if (ly.sl >= 0 && ly.sr >= 0) { pairs[np][0] = ly.sl; pairs[np][1] = ly.sr; ++np; }
    if (ly.bl >= 0 && ly.br >= 0) { pairs[np][0] = ly.bl; pairs[np][1] = ly.br; ++np; }

    /* ---- 重置请求：本块开始淡出；淡出到 0 后清状态再重新起尾 ---- */
    if (s.reset_req.exchange(0, std::memory_order_relaxed) != 0) {
        s.fading_out = true;
    }
    const float fade_step = 1.0f / (0.005f * fs); /* 5ms */

    const int nch = (ch < 8) ? ch : 8;
    for (int n = 0; n < frames; ++n) {
        /* 预延迟长度平滑 */
        s.pre_len_sm += pre_step;
        if (s.pre_len_sm < 0.0f) s.pre_len_sm = 0.0f;
        int di = (int)s.pre_len_sm;
        if (di > kPreMax - 2) di = kPreMax - 2;
        const float frac = s.pre_len_sm - (float)di;

        /* 逐声道预延迟（写当前输入、读延迟后的输入） */
        float vin[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        for (int c = 0; c < nch; ++c) {
            float x = io[n * ch + c];
            if (c == lfe_idx && lfe_on) {
                s.lfe_in_lp += lfe_a * (x - s.lfe_in_lp);
                x = s.lfe_in_lp * 0.5f; /* -6dB */
            }
            s.pre_buf[c][s.pre_pos] = x;
            int rp = s.pre_pos - di;
            if (rp < 0) rp += kPreMax;
            int rp1 = rp - 1;
            if (rp1 < 0) rp1 += kPreMax;
            const float a0 = s.pre_buf[c][rp];
            vin[c] = a0 + frac * (s.pre_buf[c][rp1] - a0);
        }
        if (++s.pre_pos >= kPreMax) s.pre_pos = 0;

        /* 输入矩阵 N×8（LFE 关闭时其输入完全不进 FDN） */
        float inl[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        for (int c = 0; c < nch; ++c) {
            if (c == lfe_idx && !lfe_on) continue;
            const float x = vin[c];
            for (int i = 0; i < 8; ++i) inl[i] += m[c][i] * x;
        }

        /* 读 8 线 + 每线阻尼 + 反馈增益 */
        float z[8];
        for (int i = 0; i < 8; ++i) {
            int rp = s.pos[i] - s.len[i];
            if (rp < 0) rp += McReverbState::kMax;
            const float y = s.buf[i][rp];
            s.lp[i] += s.damp * (y - s.lp[i]);
            if (fabsf(s.lp[i]) < 1e-15f) s.lp[i] = 0.0f;
            z[i] = s.lp[i] * s.fb[i];
        }

        /* 8×8 Hadamard 反馈 + 输入注入 */
        mc_hadamard8(z);
        for (int i = 0; i < 8; ++i) {
            s.buf[i][s.pos[i]] = inl[i] + z[i];
            if (++s.pos[i] >= McReverbState::kMax) s.pos[i] = 0;
        }

        /* 输出矩阵 8×N（湿声） */
        float wetv[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        for (int c = 0; c < nch; ++c) {
            float w = 0.0f;
            for (int i = 0; i < 8; ++i) w += m[c][i] * s.lp[i];
            wetv[c] = w;
        }
        if (lfe_idx >= 0 && lfe_idx < nch && !lfe_on) {
            wetv[lfe_idx] = 0.0f; /* LFE 默认只留干声 */
        } else if (lfe_on) {
            s.lfe_out_lp += lfe_a * (wetv[lfe_idx] - s.lfe_out_lp);
            wetv[lfe_idx] = s.lfe_out_lp;
        }

        /* 宽度（只加宽湿声） */
        if (width != 1.0f) {
            for (int p = 0; p < np; ++p) {
                const int a = pairs[p][0], b = pairs[p][1];
                if (b >= nch) continue;
                const float mid = (wetv[a] + wetv[b]) * 0.5f;
                const float side = (wetv[a] - wetv[b]) * 0.5f * width;
                wetv[a] = mid + side;
                wetv[b] = mid - side;
            }
        }

        /* 干湿混合（湿声乘淡出系数） */
        const float f = s.fade;
        for (int c = 0; c < nch; ++c) {
            const float d = io[n * ch + c];
            if (c == lfe_idx && !lfe_on) {
                io[n * ch + c] = d * dryG;
            } else {
                io[n * ch + c] = d * dryG + wetv[c] * wetG * f;
            }
        }

        /* 淡出推进：到 0 后清状态，湿声从新尾音重新开始（此刻新尾≈0） */
        if (s.fading_out) {
            s.fade -= fade_step;
            if (s.fade <= 0.0f) {
                mc_clear_state(s);
                h->rev_ag_in = h->rev_ag_out = 0.0;
                h->rev_ag_comp = 1.0;
                h->rev_g_sm = 1.0f;
            }
        }
    }

    /* ---- 输出增益 + 自动增益（与旧 Freeverb 同平滑常数） ---- */
    float g_target = powf(10.0f, h->p.reverb_outgain.load(std::memory_order_relaxed) * 0.05f);
    if (ag) {
        const double rout = mc_block_rms(io, total);
        h->rev_ag_in += (rin - h->rev_ag_in) * 0.05;
        h->rev_ag_out += (rout - h->rev_ag_out) * 0.05;
        double desired = 1.0;
        if (h->rev_ag_in > 1e-6 && h->rev_ag_out > 1e-6)
            desired = h->rev_ag_in / h->rev_ag_out;
        if (desired < 0.25) desired = 0.25;
        if (desired > 4.0) desired = 4.0;
        h->rev_ag_comp += (desired - h->rev_ag_comp) * 0.1;
        g_target *= (float)h->rev_ag_comp;
    }
    float g_sm = h->rev_g_sm;
    if (g_target != 1.0f || fabsf(g_sm - 1.0f) >= 1e-6f) {
        const float alpha = (float)exp(-1.0 / (0.002 * (double)fs));
        const float beta = 1.0f - alpha;
        for (int i = 0; i < total; ++i) {
            g_sm = alpha * g_sm + beta * g_target;
            io[i] *= g_sm;
        }
        h->rev_g_sm = (fabsf(g_sm) < 1e-15f) ? 0.0f : g_sm;
    } else {
        h->rev_g_sm = 1.0f;
    }
}
