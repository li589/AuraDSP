/*
 * engine_param_table.h — AuraDSP 参数引擎表驱动分发系统
 *
 * 核心目标：
 *   将 auradsp_set_param 与 auradsp_get_param 中 ~950 行级联 if (!strcmp)
 *   替换为 O(1) 表驱动分发管线，同时 100% 保持既有 C ABI、原子安全性与语义一致。
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string_view>
#include <unordered_map>

#include "auradsp_engine.h"
#include "engine_internal.h"

enum class ParamType : uint8_t {
    kFloat,
    kInt32,
    kBool
};

using ParamHookFn = void (*)(auradsp_handle h);
using CustomSetFn = auradsp_status (*)(auradsp_handle h, const void* value, uint32_t bytes);
using CustomGetFn = auradsp_status (*)(auradsp_handle h, void* out_value, uint32_t bytes);

inline constexpr size_t kNoOffset = static_cast<size_t>(-1);

struct EngineParamDesc {
    const char* id;
    ParamType   type;
    size_t      offset_in_p;
    float       min_val;
    float       max_val;
    ParamHookFn set_hook;
    CustomSetFn custom_set;
    CustomGetFn custom_get;
};

/* ========================================================================= */
/*                          后置更新钩子 (Set Hooks)                         */
/* ========================================================================= */

static void hook_bass_enable(auradsp_handle h) {
    if (h->open.load()) apply_bass(h);
}

static void hook_bass_gain(auradsp_handle h) {
    if (h->open.load() && h->p.bass_enable.load()) {
        BassBoostSetParam(&h->jdsp, h->p.bass_gain.load());
    }
}

static void hook_stereo_enable(auradsp_handle h) {
    if (h->open.load()) apply_stereo(h);
}

static void hook_stereo_mix(auradsp_handle h) {
    h->p.stereo_band_used.store(0);
    if (h->open.load()) {
        StereoEnhancementUseUnifiedMix(&h->jdsp);
        apply_stereo(h);
    }
}

static void hook_stereo_band_used(auradsp_handle h) {
    if (h->open.load()) {
        if (h->p.stereo_band_used.load()) {
            apply_stereo(h);
        } else {
            StereoEnhancementUseUnifiedMix(&h->jdsp);
            apply_stereo(h);
        }
    }
}

static void hook_eq_enable(auradsp_handle h) {
    if (h->open.load()) apply_eq(h);
}

static void hook_limiter_enable(auradsp_handle h) {
    h->jdsp.limiterEnabled = h->p.limiter_enable.load();
}

static void hook_post_gain(auradsp_handle h) {
    if (h->open.load()) apply_post(h);
}

static void hook_fx_gains(auradsp_handle h) {
    if (h->open.load()) apply_fx_gains(h);
}

static void hook_reverb_autogain(auradsp_handle h) {
    if (h->open.load()) {
        h->rev_ag_in = h->rev_ag_out = 0.0;
        h->rev_ag_comp = 1.0;
    }
}

static void hook_gate_autogain(auradsp_handle h) {
    if (h->open.load()) {
        h->gate_ag_in = h->gate_ag_out = 0.0;
        h->gate_ag_comp = 1.0;
    }
}

static void hook_dyneq_attack(auradsp_handle h) {
    const float att = h->p.dyneq_attack.load(std::memory_order_relaxed);
    h->p.dyneq_b1_attack.store(att, std::memory_order_relaxed);
    h->p.dyneq_b2_attack.store(att, std::memory_order_relaxed);
    h->p.dyneq_b3_attack.store(att, std::memory_order_relaxed);
}

static void hook_dyneq_release(auradsp_handle h) {
    const float rel = h->p.dyneq_release.load(std::memory_order_relaxed);
    h->p.dyneq_b1_release.store(rel, std::memory_order_relaxed);
    h->p.dyneq_b2_release.store(rel, std::memory_order_relaxed);
    h->p.dyneq_b3_release.store(rel, std::memory_order_relaxed);
}

static void hook_filter_recalc(auradsp_handle h) {
    filter_recalc(h);
}

static void hook_shelf_recalc(auradsp_handle h) {
    shelf_recalc(h);
}

static void hook_liveprog_enable(auradsp_handle h) {
    if (h->open.load()) apply_liveprog(h);
}

static void hook_tube_enable(auradsp_handle h) {
    if (h->open.load()) apply_tube(h);
}

static void hook_tube_gain(auradsp_handle h) {
    if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed)) {
        VacuumTubeSetGain(&h->jdsp, (double)h->p.tube_gain.load());
    }
}

static void hook_tube_style(auradsp_handle h) {
    if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed)) {
        VacuumTubeSetCharacter(&h->jdsp, (int)h->p.tube_style.load());
    }
}

static void hook_tube_mix(auradsp_handle h) {
    if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed)) {
        VacuumTubeSetDryWet(&h->jdsp, h->p.tube_mix.load());
    }
}

static void hook_tube_compensation(auradsp_handle h) {
    if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed)) {
        VacuumTubeSetOutComp(&h->jdsp, (double)h->p.tube_compensation.load());
    }
}

static void hook_comp_enable(auradsp_handle h) {
    if (h->open.load()) apply_comp(h);
    compute_latency(h, &h->latency_ms);
}

static void hook_comp_update(auradsp_handle h) {
    if (h->open.load() && h->p.comp_enable.load(std::memory_order_relaxed)) {
        apply_comp(h);
    }
}

static void hook_spatial_enable(auradsp_handle h) {
    spatial_reset(h);
    compute_latency(h, &h->latency_ms);
}

static void hook_spatial_style(auradsp_handle h) {
    const int32_t v = h->p.spatial_style.load();
    if (v == 0) {  // Dolby 房
        h->p.spatial_room.store(0.7f);
        h->p.spatial_width.store(1.0f);
        h->p.spatial_center.store(0.8f);
    } else if (v == 1) {  // DTS 定位
        h->p.spatial_room.store(0.25f);
        h->p.spatial_width.store(1.1f);
        h->p.spatial_center.store(0.5f);
    } else {  // 中性
        h->p.spatial_room.store(0.0f);
        h->p.spatial_width.store(1.0f);
        h->p.spatial_center.store(0.5f);
    }
}

static void hook_spatial_autogain(auradsp_handle h) {
    h->spat_ag_in = h->spat_ag_out = 0.0;
    h->spat_ag_comp = 1.0;
}

static void hook_freeverb_enable(auradsp_handle h) {
    compute_latency(h, &h->latency_ms);
}

static void hook_freeverb_roomsize(auradsp_handle h) {
    fv_retune(h, (double)h->p.fv_roomsize.load());
}

static void hook_crossfeed_enable(auradsp_handle h) {
    if (h->open.load()) apply_crossfeed(h);
    compute_latency(h, &h->latency_ms);
}

static void hook_crossfeed_mode(auradsp_handle h) {
    if (h->open.load() && h->p.xfeed_enable.load()) apply_crossfeed(h);
}

static void hook_crossfeed_custom(auradsp_handle h) {
    if (h->open.load() && h->p.xfeed_enable.load() && h->p.xfeed_mode.load() == 3) {
        apply_crossfeed(h);
    }
}

/* ========================================================================= */
/*                   自定义 Set / Get 逻辑 (Custom Handlers)                  */
/* ========================================================================= */

static auradsp_status set_bass_intensity(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    float intensity = *(const float*)value;
    if (intensity < 0.0f) intensity = 0.0f;
    if (intensity > 1.0f) intensity = 1.0f;
    float gain = intensity * 15.0f;
    h->p.bass_gain.store(gain);
    if (h->open.load() && h->p.bass_enable.load()) {
        BassBoostSetParam(&h->jdsp, gain);
    }
    return AURADSP_OK;
}

static auradsp_status get_bass_intensity(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    float gain = h->p.bass_gain.load();
    float intensity = gain / 15.0f;
    if (intensity < 0.0f) intensity = 0.0f;
    if (intensity > 1.0f) intensity = 1.0f;
    *(float*)out_value = intensity;
    return AURADSP_OK;
}

static auradsp_status set_reverb_preset(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value;
    /* 18 = SF_REVERB_PRESET_LONGREVERB2（sf_presetreverb 最高分支）。
     * 越界会落到 switch default，comb/delay size 保持 0，下一音频块
     * (pos+1)%size 整数模零 → SIGFPE；VM/AIDL/预设恢复均可触达。 */
    if (v < -2 || v > 18) return AURADSP_E_PARAM;
    if (v != h->p.reverb_preset.load(std::memory_order_relaxed)) {
        h->p.reverb_preset.store(v);
        compute_latency(h, &h->latency_ms);
    }
    if (h->open.load()) apply_reverb(h);
    compute_latency(h, &h->latency_ms);
    return AURADSP_OK;
}

static auradsp_status set_convolver_enable(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value ? 1 : 0;
    h->p.conv_enable.store(v);
    if (h->open.load()) apply_convolver(h);
    compute_latency(h, &h->latency_ms);
    return AURADSP_OK;
}

static auradsp_status set_convolver_mix(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    float v = *(const float*)value;
    if (v < 0.0f) v = 0.0f; if (v > 1.0f) v = 1.0f;
    h->p.conv_mix.store(v);
    h->jdsp.auraConvWet = v;
    h->jdsp.auraConvDry = 1.0f - v;
    h->jdsp.auraConvMixUsed = (v < 0.999f) ? 1 : 0;
    return AURADSP_OK;
}

static auradsp_status set_convolver_ir_path(auradsp_handle h, const void* value, uint32_t bytes) {
    if (!h->open.load()) { set_error(h, "convolver.ir.path: engine closed"); return AURADSP_E_STATE; }
    if (bytes == 0 || bytes > 4096) {
        set_error(h, "convolver.ir.path: invalid length");
        return AURADSP_E_PARAM;
    }
    char* pbuf = (char*)malloc((size_t)bytes + 1);
    if (!pbuf) { set_error(h, "convolver.ir.path: out of memory"); return AURADSP_E_IO; }
    memcpy(pbuf, value, bytes);
    pbuf[bytes] = 0;
    const auradsp_status st = load_ir_file(h, pbuf);
    free(pbuf);
    if (st != AURADSP_OK) return st;
    if (h->p.conv_enable.load(std::memory_order_relaxed) && h->open.load())
        apply_convolver(h);
    return AURADSP_OK;
}

static auradsp_status set_convolver_clear(auradsp_handle h, const void* /*value*/, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    h->p.conv_enable.store(0);
    h->ir_ready.store(false);
    h->ir_frames.store(0);
    h->ir_channels.store(0);
    h->ir_src_rate.store(0);
    h->ir_peak.store(0.0f);
    memset(h->ir_spectrum, 0, sizeof(h->ir_spectrum));
    if (h->open.load()) apply_convolver(h);
    return AURADSP_OK;
}

static auradsp_status get_convolver_ready(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->ir_ready.load() ? 1 : 0;
    return AURADSP_OK;
}

static auradsp_status get_convolver_ir_frames(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->ir_frames.load();
    return AURADSP_OK;
}

static auradsp_status get_convolver_ir_channels(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->ir_channels.load();
    return AURADSP_OK;
}

static auradsp_status get_convolver_ir_src_rate(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->ir_src_rate.load();
    return AURADSP_OK;
}

static auradsp_status get_convolver_ir_peak(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(float*)out_value = h->ir_peak.load();
    return AURADSP_OK;
}

static auradsp_status get_convolver_ir_spectrum(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (!h->ir_ready.load()) return AURADSP_E_STATE;
    const int ch = h->ir_channels.load();
    if (ch <= 0 || ch > 8) return AURADSP_E_STATE;
    const size_t req = (size_t)ch * AURADSP_VIZ_BANDS * sizeof(float);
    if (bytes < req) {
        set_error(h, "convolver.ir.spectrum: buffer too small");
        return AURADSP_E_PARAM;
    }
    memcpy(out_value, h->ir_spectrum, req);
    return AURADSP_OK;
}

static auradsp_status set_arbmag_enable(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value ? 1 : 0;
    h->p.arbmag_enable.store(v);
    if (h->open.load()) apply_arbmag(h);
    compute_latency(h, &h->latency_ms);
    return AURADSP_OK;
}

/* vendor 的 strtof/get_floatArb 会接受 nan/inf（errno 不报），随后
 * gainAtLogGrid/NodesSorter 会把非有限值带进 FIR/卷积状态。legacy 只读，
 * 因此在入口按“可解析数字必须是有限值”逐 token 拒绝。 */
static bool arbmag_numeric_finite(const char* s) {
    if (!s) return false;
    for (const char* p = s; *p;) {
        const char c = *p;
        const bool maybeNum = (c >= '0' && c <= '9') || c == '+' || c == '-' ||
                              c == '.' || c == 'n' || c == 'N' ||
                              c == 'i' || c == 'I';
        if (maybeNum) {
            char* end = nullptr;
            const double v = strtod(p, &end);
            if (end != p) {
                if (!std::isfinite(v)) return false;
                p = end;
                continue;
            }
        }
        ++p;
    }
    return true;
}

static auradsp_status set_arbmag_string(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes == 0 || bytes > 256 * 1024) {
        set_error(h, "arbmag.string: invalid length (1..256KiB)");
        return AURADSP_E_PARAM;
    }
    char* buf = (char*)malloc((size_t)bytes + 1);
    if (!buf) { set_error(h, "arbmag.string: out of memory"); return AURADSP_E_IO; }
    memcpy(buf, value, bytes);
    buf[bytes] = 0;
    if (!arbmag_numeric_finite(buf)) {
        free(buf);
        set_error(h, "arbmag.string: parse failed (non-finite numeric token)");
        return AURADSP_E_PARAM;
    }
    ArbitraryResponseEqualizerStringParser(&h->jdsp, buf);
    free(buf);
    const int nodes = (int)h->jdsp.arbMag.instance.coeffGen.nodesCount;
    h->p.arbmag_nodes.store(nodes);
    h->p.arbmag_ready.store(nodes > 0 ? 1 : 0);
    if (h->open.load() && h->p.arbmag_enable.load(std::memory_order_relaxed)) {
        apply_arbmag(h);
    }
    char* arbmag_new = (char*)malloc((size_t)bytes + 1);
    if (!arbmag_new) { set_error(h, "arbmag.string: out of memory (copy)"); return AURADSP_E_IO; }
    memcpy(arbmag_new, value, bytes);
    arbmag_new[bytes] = 0;
    free(h->arbmag_string);
    h->arbmag_string = arbmag_new;
    h->arbmag_string_len = (size_t)bytes;
    return AURADSP_OK;
}

static auradsp_status get_arbmag_string(auradsp_handle h, void* out_value, uint32_t bytes) {
    /* S-10 修复：无副本分支也写 1 字节终末符，bytes<1 即理论越写。 */
    if (bytes < 1) return AURADSP_E_PARAM;
    if (!h->arbmag_string) { *(char*)out_value = 0; return AURADSP_OK; }
    if (bytes < h->arbmag_string_len + 1) { set_error(h, "arbmag.string: buffer too small"); return AURADSP_E_PARAM; }
    memcpy(out_value, h->arbmag_string, h->arbmag_string_len + 1);
    return AURADSP_OK;
}

static auradsp_status get_arbmag_ready(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->p.arbmag_ready.load();
    return AURADSP_OK;
}

static auradsp_status get_arbmag_node_count(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->p.arbmag_nodes.load();
    return AURADSP_OK;
}

static auradsp_status set_ddc_load(auradsp_handle h, const void* value, uint32_t bytes) {
    if (!h->open.load()) { set_error(h, "ddc.load: engine closed"); return AURADSP_E_STATE; }
    if (bytes == 0 || bytes > 4096) {
        set_error(h, "ddc.load: invalid path (length)");
        return AURADSP_E_PARAM;
    }
    char* pbuf = (char*)malloc((size_t)bytes + 1);
    if (!pbuf) { set_error(h, "ddc.load: out of memory"); return AURADSP_E_IO; }
    memcpy(pbuf, value, bytes);
    pbuf[bytes] = 0;
    auradsp_status st = AURADSP_OK;
    char* content = read_text_file(h, pbuf, 4 * 1024 * 1024, &st);
    free(pbuf);
    if (!content) return st;
    const int rc = DDCStringParser(&h->jdsp, content);
    free(content);
    if (rc < 0) {
        h->p.ddc_ready.store(0);
        set_error(h, "ddc.load: parse failed (need SR_44100/SR_48000 coeffs)");
        return AURADSP_E_PARAM;
    }
    h->p.ddc_ready.store(1);
    if (h->open.load() && h->p.ddc_enable.load(std::memory_order_relaxed)) {
        DDCEnable(&h->jdsp, 1);
    }
    return AURADSP_OK;
}

static auradsp_status set_ddc_enable(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value ? 1 : 0;
    h->p.ddc_enable.store(v);
    if (v && h->p.ddc_ready.load(std::memory_order_relaxed)) {
        const int rc = DDCEnable(&h->jdsp, 1);
        if (rc != 1) {
            h->p.ddc_enable.store(0);
            set_error(h, "ddc.enable: rejected");
            return AURADSP_E_STATE;
        }
    } else {
        DDCDisable(&h->jdsp);
    }
    return AURADSP_OK;
}

static auradsp_status get_ddc_ready(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->p.ddc_ready.load();
    return AURADSP_OK;
}

static auradsp_status set_channels_mode(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value;
    if (v != 0 && v != 1) {
        set_error(h, "channels.mode: out of range (0=matrix, 1=discrete)");
        return AURADSP_E_PARAM;
    }
    h->p.channels_mode.store(v);
    /* 模式切换会改变 spatial 的输入布局/状态语义；清空 ring/history/pinna/FDN，
     * 避免直播切换读到旧布局的延迟线。 */
    spatial_reset(h);
    return AURADSP_OK;
}

static auradsp_status set_channels_count(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value;
    if (v != 2 && v != 4 && v != 6 && v != 8) {
        set_error(h, "channels.count: out of range (2/4/6/8 only)");
        return AURADSP_E_PARAM;
    }
    h->channel_count.store(v);
    /* 声道数变化同样改变 spatial 输入布局，复位其 RT 状态。 */
    spatial_reset(h);
    return AURADSP_OK;
}

static auradsp_status get_channels_count(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->channel_count.load();
    return AURADSP_OK;
}

static auradsp_status set_gate_max_ir_seconds(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    float v = *(const float*)value;
    if (v < 0.1f) v = 0.1f;
    if (v > 600.0f) v = 600.0f;
    h->gate_max_ir_seconds.store(v);
    return AURADSP_OK;
}

static auradsp_status get_gate_max_ir_seconds(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(float*)out_value = h->gate_max_ir_seconds.load();
    return AURADSP_OK;
}

static auradsp_status set_gate_max_file_mb(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    float v = *(const float*)value;
    if (v < 1.0f) v = 1.0f;
    if (v > 4096.0f) v = 4096.0f;
    h->gate_max_file_mb.store(v);
    return AURADSP_OK;
}

static auradsp_status get_gate_max_file_mb(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(float*)out_value = h->gate_max_file_mb.load();
    return AURADSP_OK;
}

static auradsp_status set_viz_fft_size(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    const int32_t v = *(const int32_t*)value;
    if (v < 1024 || v > kVizFftMax || (v & (v - 1)) != 0) {
        set_error(h, "viz.fftSize: out of range (power of two within [1024, 8192])");
        return AURADSP_E_PARAM;
    }
    if (h->viz_emitted.load(std::memory_order_relaxed)) {
        set_error(h, "viz.fftSize: rejected (only changeable before the first viz frame)");
        return AURADSP_E_STATE;
    }
    rebuild_hann(h, (int)v);
    h->viz_fft_size.store((int)v);
    return AURADSP_OK;
}

static auradsp_status get_viz_fft_size(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->viz_fft_size.load();
    return AURADSP_OK;
}

static auradsp_status set_mode_latency(auradsp_handle h, const void* /*value*/, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    set_error(h, "mode.latency: unsupported (removed by ADR-006, latency is measurement-only)");
    return AURADSP_E_PARAM;
}

static auradsp_status get_mode_latency(auradsp_handle /*h*/, void* /*out_value*/, uint32_t /*bytes*/) {
    return AURADSP_E_PARAM;
}

static auradsp_status set_eq_curve(auradsp_handle h, const void* value, uint32_t bytes) {
    if (!h->open.load()) { set_error(h, "eq.curve: engine closed"); return AURADSP_E_STATE; }
    if (bytes == 0 || bytes > 4096) {
        set_error(h, "eq.curve: invalid length");
        return AURADSP_E_PARAM;
    }
    char* txt = (char*)malloc((size_t)bytes + 1);
    if (!txt) { set_error(h, "eq.curve: out of memory"); return AURADSP_E_IO; }
    memcpy(txt, value, bytes);
    txt[bytes] = 0;
    double freqAx[NUMPTS], gainAx[NUMPTS];
    int interp = 1, op = 0;
    const int n = build_eq_axis(txt, h->sample_rate, freqAx, gainAx, &interp, &op);
    free(txt);
    if (n < 2) {
        set_error(h, "eq.curve: invalid length (need >= 2 points, f:g;f:g;...)");
        return AURADSP_E_PARAM;
    }
    MultimodalEqualizerAxisInterpolation(&h->jdsp, interp, op, freqAx, gainAx);
    char* eq_curve_new = (char*)malloc((size_t)bytes + 1);
    if (!eq_curve_new) { set_error(h, "eq.curve: out of memory (copy)"); return AURADSP_E_IO; }
    memcpy(eq_curve_new, value, bytes);
    eq_curve_new[bytes] = 0;
    free(h->eq_curve);
    h->eq_curve = eq_curve_new;
    h->eq_curve_len = (size_t)bytes;
    return AURADSP_OK;
}

static auradsp_status get_eq_curve(auradsp_handle h, void* out_value, uint32_t bytes) {
    /* S-10 修复：无副本分支也写 1 字节终末符，bytes<1 即理论越写。 */
    if (bytes < 1) return AURADSP_E_PARAM;
    if (!h->eq_curve) { *(char*)out_value = 0; return AURADSP_OK; }
    if (bytes < h->eq_curve_len + 1) { set_error(h, "eq.curve: buffer too small"); return AURADSP_E_PARAM; }
    memcpy(out_value, h->eq_curve, h->eq_curve_len + 1);
    return AURADSP_OK;
}

static auradsp_status set_liveprog_code(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes == 0 || bytes > 256 * 1024) {
        set_error(h, "liveprog.code: invalid length (1..256KiB)");
        return AURADSP_E_PARAM;
    }
    char* buf = (char*)malloc((size_t)bytes + 1);
    if (!buf) { set_error(h, "liveprog.code: out of memory"); return AURADSP_E_IO; }
    memcpy(buf, value, bytes);
    buf[bytes] = 0;
    const int rc = LiveProgStringParser(&h->jdsp, buf);
    free(buf);
    if (rc != 1) {
        h->lp_status = rc;
        set_error(h, checkErrorCode(rc));
        return AURADSP_E_PARAM;
    }
    lp_refresh_sliders(h);
    h->lp_status = 1;
    char* lp_new = (char*)malloc((size_t)bytes + 1);
    if (!lp_new) { set_error(h, "liveprog.code: out of memory (copy)"); return AURADSP_E_IO; }
    memcpy(lp_new, value, bytes);
    lp_new[bytes] = 0;
    free(h->lp_code);
    h->lp_code = lp_new;
    h->lp_code_len = bytes;
    if (h->open.load() && h->p.lp_enable.load(std::memory_order_relaxed))
        LiveProgEnable(&h->jdsp);
    return AURADSP_OK;
}

static auradsp_status get_liveprog_code(auradsp_handle h, void* out_value, uint32_t bytes) {
    /* S-10 修复：无副本分支也写 1 字节终末符，bytes<1 即理论越写。 */
    if (bytes < 1) return AURADSP_E_PARAM;
    if (!h->lp_code) { *(char*)out_value = 0; return AURADSP_OK; }
    if (bytes < h->lp_code_len + 1) { set_error(h, "liveprog.code: buffer too small"); return AURADSP_E_PARAM; }
    memcpy(out_value, h->lp_code, h->lp_code_len + 1);
    return AURADSP_OK;
}

static auradsp_status set_liveprog_unload(auradsp_handle h, const void* /*value*/, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    h->p.lp_enable.store(0);
    h->jdsp.eel.compileSucessfully = 0;
    h->lp_status = 0;
    if (h->open.load()) apply_liveprog(h);
    return AURADSP_OK;
}

static auradsp_status get_liveprog_status(auradsp_handle h, void* out_value, uint32_t bytes) {
    if (bytes < 4) return AURADSP_E_PARAM;
    *(int32_t*)out_value = h->lp_status;
    return AURADSP_OK;
}

static auradsp_status set_graph_order(auradsp_handle h, const void* value, uint32_t bytes) {
    if (bytes < 16) return AURADSP_E_PARAM;
    char* ord = (char*)malloc((size_t)bytes + 1);
    if (!ord) { set_error(h, "graph.order: out of memory"); return AURADSP_E_IO; }
    memcpy(ord, value, bytes);
    ord[bytes] = 0;
    char filtered[512];
    const int flen = JamesDSPFilterVendorOrder(ord, filtered, (int)sizeof(filtered));
    free(ord);
    if (flen <= 0 || !strcmp(filtered, "output")) {
        set_error(h, "graph.order: parse failed (no vendor stage id found)");
        return AURADSP_E_PARAM;
    }
    const int rc = JamesDSPRebuildChain(&h->jdsp, filtered);
    if (rc != 0) {
        set_error(h, "graph.order: parse failed (invalid list, need all 12 stages exactly once)");
        return AURADSP_E_PARAM;
    }
    return AURADSP_OK;
}

static auradsp_status get_graph_effects(auradsp_handle /*h*/, void* out_value, uint32_t bytes) {
    if (bytes < 2048) return AURADSP_E_PARAM;
    const char* reg =
        "["
        "{\"id\":\"tube\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"bass\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"eq\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"convolver\",\"tier\":2,\"exposed\":true},"
        "{\"id\":\"liveprog\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"crossfeed\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"stereo\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"reverb\",\"tier\":2,\"exposed\":true},"
        "{\"id\":\"post\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"limiter\",\"tier\":0,\"exposed\":true},"
        "{\"id\":\"comp\",\"tier\":2,\"exposed\":true},"
        "{\"id\":\"bassmono\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"haas\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"exciter\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"gate\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"filter\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"dyneq\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"loudness\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"arbmag\",\"tier\":2,\"exposed\":true},"
        "{\"id\":\"ddc\",\"tier\":1,\"exposed\":true},"
        "{\"id\":\"spatial\",\"tier\":1,\"exposed\":true}"
        "]";
    snprintf((char*)out_value, bytes, "%s", reg);
    return AURADSP_OK;
}

/* ========================================================================= */
/*                          动态索引参数处理 (Indexed)                        */
/* ========================================================================= */

static auradsp_status handle_indexed_param_set(auradsp_handle h, const char* id, const void* value, uint32_t bytes) {
    if (!strncmp(id, "stereo.band", 11) && bytes >= 4) {
        const char d = id[11];
        if (d < '1' || d > '5' || id[12] != 0) { set_error(h, "param: unsupported (unknown param id)"); return AURADSP_E_PARAM; }
        const int idx = d - '1';
        float v = *(const float*)value;
        if (v < 0.0f) v = 0.0f; if (v > 1.0f) v = 1.0f;
        h->p.stereo_band[idx].store(v, std::memory_order_relaxed);
        h->p.stereo_band_used.store(1);
        if (h->open.load()) apply_stereo(h);
        return AURADSP_OK;
    }
    if (!strncmp(id, "input.balance.", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) { set_error(h, "param: unsupported (unknown input balance channel)"); return AURADSP_E_PARAM; }
        const int idx = d - '1';
        float v = *(const float*)value;
        if (v < 0.0f) v = 0.0f; if (v > 2.0f) v = 2.0f;
        h->p.input_ch_gain[idx].store(v, std::memory_order_relaxed);
        return AURADSP_OK;
    }
    if (!strncmp(id, "liveprog.param", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) { set_error(h, "param: unsupported (unknown param id)"); return AURADSP_E_PARAM; }
        const int idx = d - '1';
        h->p.lp_param[idx].store(*(const float*)value, std::memory_order_relaxed);
        if (h->lp_slider_ptr[idx])
            *h->lp_slider_ptr[idx] = *(const float*)value;
        return AURADSP_OK;
    }
    set_error(h, "param: unsupported (unknown param id)");
    return AURADSP_E_PARAM;
}

static auradsp_status handle_indexed_param_get(auradsp_handle h, const char* id, void* out_value, uint32_t bytes) {
    if (!strncmp(id, "stereo.band", 11) && bytes >= 4) {
        const char d = id[11];
        if (d < '1' || d > '5' || id[12] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.stereo_band[d - '1'].load();
        return AURADSP_OK;
    }
    if (!strncmp(id, "input.balance.", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.input_ch_gain[d - '1'].load();
        return AURADSP_OK;
    }
    if (!strncmp(id, "liveprog.param", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.lp_param[d - '1'].load();
        return AURADSP_OK;
    }
    return AURADSP_E_PARAM;
}

static auradsp_status get_gr_limiter(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    *(float*)out = h->gr_limiter.load(std::memory_order_relaxed);
    return AURADSP_OK;
}

static auradsp_status get_gr_comp(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    *(float*)out = h->gr_comp.load(std::memory_order_relaxed);
    return AURADSP_OK;
}

static auradsp_status get_gr_gate(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    *(float*)out = h->gr_gate.load(std::memory_order_relaxed);
    return AURADSP_OK;
}

static auradsp_status get_gr_dyneq(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    float g0 = h->gr_dyneq[0].load(std::memory_order_relaxed);
    float g1 = h->gr_dyneq[1].load(std::memory_order_relaxed);
    float g2 = h->gr_dyneq[2].load(std::memory_order_relaxed);
    float max_gr = g0 > g1 ? (g0 > g2 ? g0 : g2) : (g1 > g2 ? g1 : g2);
    *(float*)out = max_gr;
    return AURADSP_OK;
}

static auradsp_status get_gr_dyneq_b1(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    *(float*)out = h->gr_dyneq[0].load(std::memory_order_relaxed);
    return AURADSP_OK;
}

static auradsp_status get_gr_dyneq_b2(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    *(float*)out = h->gr_dyneq[1].load(std::memory_order_relaxed);
    return AURADSP_OK;
}

static auradsp_status get_gr_dyneq_b3(auradsp_handle h, void* out, uint32_t bytes) {
    if (!h || !out || bytes != 4) return AURADSP_E_PARAM;
    *(float*)out = h->gr_dyneq[2].load(std::memory_order_relaxed);
    return AURADSP_OK;
}

/* ========================================================================= */
/*                          宏展开构建静态描述表                              */
/* ========================================================================= */

#define PARAM_FLOAT(id, member, min_val, max_val, hook) \
    { (id), ParamType::kFloat, offsetof(Params, member), (float)(min_val), (float)(max_val), (hook), nullptr, nullptr }

#define PARAM_INT(id, member, min_val, max_val, hook) \
    { (id), ParamType::kInt32, offsetof(Params, member), (float)(min_val), (float)(max_val), (hook), nullptr, nullptr }

#define PARAM_BOOL(id, member, hook) \
    { (id), ParamType::kBool, offsetof(Params, member), 0.0f, 1.0f, (hook), nullptr, nullptr }

#define PARAM_CUSTOM(id, custom_set_fn, custom_get_fn) \
    { (id), ParamType::kInt32, kNoOffset, 0.0f, 0.0f, nullptr, (custom_set_fn), (custom_get_fn) }

#define PARAM_CUSTOM_SET_ONLY(id, custom_set_fn) \
    { (id), ParamType::kInt32, kNoOffset, 0.0f, 0.0f, nullptr, (custom_set_fn), nullptr }

#define PARAM_CUSTOM_GET_ONLY(id, custom_get_fn) \
    { (id), ParamType::kInt32, kNoOffset, 0.0f, 0.0f, nullptr, nullptr, (custom_get_fn) }

#define PARAM_CUSTOM_SET_STANDARD_GET(id, member, type, custom_set_fn) \
    { (id), (type), offsetof(Params, member), 0.0f, 0.0f, nullptr, (custom_set_fn), nullptr }

static const EngineParamDesc kEngineParamTable[] = {
    // 01 电子管 (Tube)
    PARAM_BOOL("tube.enable", tube_enable, hook_tube_enable),
    PARAM_FLOAT("tube.gain", tube_gain, -3.0f, 12.0f, hook_tube_gain),
    PARAM_INT("tube.style", tube_style, 0, 2, hook_tube_style),
    PARAM_FLOAT("tube.mix", tube_mix, 0.0f, 1.0f, hook_tube_mix),
    PARAM_FLOAT("tube.compensation", tube_compensation, -12.0f, 12.0f, hook_tube_compensation),
    PARAM_FLOAT("tube.outgain", tube_outgain, -12.0f, 6.0f, hook_fx_gains),
    PARAM_BOOL("tube.autogain", tube_autogain, hook_fx_gains),
    PARAM_INT("tube.channels", tube_channels, 0, 255, nullptr),
    PARAM_INT("tube.channel_mask", tube_channels, 0, 255, nullptr),
    PARAM_BOOL("tube.oversample", tube_oversample, nullptr),

    // 02 动态压限 (Compressor)
    PARAM_BOOL("comp.enable", comp_enable, hook_comp_enable),
    PARAM_FLOAT("comp.timeconstant", comp_timeconstant, 0.02f, 0.5f, hook_comp_update),
    PARAM_INT("comp.granularity", comp_granularity, 0, 4, hook_comp_update),
    PARAM_INT("comp.tfresolution", comp_tfresolution, 0, 3, hook_comp_update),
    PARAM_FLOAT("comp.freq1", comp_freq[0], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.freq2", comp_freq[1], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.freq3", comp_freq[2], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.freq4", comp_freq[3], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.freq5", comp_freq[4], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.freq6", comp_freq[5], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.freq7", comp_freq[6], 20.0f, 20000.0f, hook_comp_update),
    PARAM_FLOAT("comp.gain1", comp_gain[0], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.gain2", comp_gain[1], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.gain3", comp_gain[2], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.gain4", comp_gain[3], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.gain5", comp_gain[4], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.gain6", comp_gain[5], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.gain7", comp_gain[6], -1.2f, 1.2f, hook_comp_update),
    PARAM_FLOAT("comp.outgain", comp_outgain, -12.0f, 6.0f, hook_fx_gains),
    PARAM_BOOL("comp.autogain", comp_autogain, hook_fx_gains),
    PARAM_INT("comp.channels", comp_channels, 0, 255, nullptr),
    PARAM_INT("comp.channel_mask", comp_channels, 0, 255, nullptr),

    // 03 卷积混响 (Convolver)
    PARAM_CUSTOM_SET_STANDARD_GET("convolver.enable", conv_enable, ParamType::kBool, set_convolver_enable),
    PARAM_CUSTOM_SET_STANDARD_GET("convolver.mix", conv_mix, ParamType::kFloat, set_convolver_mix),
    PARAM_CUSTOM_SET_ONLY("convolver.ir.path", set_convolver_ir_path),
    PARAM_CUSTOM_SET_ONLY("convolver.clear", set_convolver_clear),
    PARAM_CUSTOM_GET_ONLY("convolver.ready", get_convolver_ready),
    PARAM_CUSTOM_GET_ONLY("convolver.ir.frames", get_convolver_ir_frames),
    PARAM_CUSTOM_GET_ONLY("convolver.ir.channels", get_convolver_ir_channels),
    PARAM_CUSTOM_GET_ONLY("convolver.ir.srcRate", get_convolver_ir_src_rate),
    PARAM_CUSTOM_GET_ONLY("convolver.ir.peak", get_convolver_ir_peak),
    PARAM_CUSTOM_GET_ONLY("convolver.ir.spectrum", get_convolver_ir_spectrum),

    // 04 空间校正 (VDC / DDC)
    PARAM_CUSTOM_SET_ONLY("ddc.load", set_ddc_load),
    PARAM_CUSTOM_SET_STANDARD_GET("ddc.enable", ddc_enable, ParamType::kBool, set_ddc_enable),
    PARAM_CUSTOM_GET_ONLY("ddc.ready", get_ddc_ready),

    // 05 任意响应 EQ (ArbMag)
    PARAM_CUSTOM_SET_STANDARD_GET("arbmag.enable", arbmag_enable, ParamType::kBool, set_arbmag_enable),
    PARAM_CUSTOM("arbmag.string", set_arbmag_string, get_arbmag_string),
    PARAM_FLOAT("arbmag.outgain", arbmag_outgain, -12.0f, 6.0f, hook_fx_gains),
    PARAM_BOOL("arbmag.autogain", arbmag_autogain, hook_fx_gains),
    PARAM_CUSTOM_GET_ONLY("arbmag.ready", get_arbmag_ready),
    PARAM_CUSTOM_GET_ONLY("arbmag.nodeCount", get_arbmag_node_count),
    PARAM_INT("arbmag.channels", arbmag_channels, 0, 255, nullptr),
    PARAM_INT("arbmag.channel_mask", arbmag_channels, 0, 255, nullptr),

    // 06 心理声学低音 (Bass Boost & Harmonics)
    PARAM_BOOL("bass.enable", bass_enable, hook_bass_enable),
    PARAM_FLOAT("bass.gain", bass_gain, 0.0f, 15.0f, hook_bass_gain),
    PARAM_CUSTOM("bass.intensity", set_bass_intensity, get_bass_intensity),
    PARAM_FLOAT("bass.outgain", bass_outgain, -12.0f, 6.0f, hook_fx_gains),
    PARAM_BOOL("bass.autogain", bass_autogain, hook_fx_gains),
    PARAM_FLOAT("bass.harmonics", bass_harmonics, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("bass.harmonicblend", bass_harmonicblend, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("bass.subfreq", bass_subfreq, 10.0f, 40.0f, nullptr),
    PARAM_FLOAT("bass.cutoff", bass_cutoff_f, 30.0f, 300.0f, nullptr),
    PARAM_BOOL("bass.oversample", bass_oversample, nullptr),

    // 07 多模态均衡 (Multimodal EQ)
    PARAM_BOOL("eq.enable", eq_enable, hook_eq_enable),
    PARAM_CUSTOM("eq.curve", set_eq_curve, get_eq_curve),
    PARAM_FLOAT("eq.outgain", eq_outgain, -12.0f, 6.0f, hook_fx_gains),
    PARAM_BOOL("eq.autogain", eq_autogain, hook_fx_gains),
    PARAM_INT("eq.channels", eq_channels, 0, 255, nullptr),
    PARAM_INT("eq.channel_mask", eq_channels, 0, 255, nullptr),

    // 08 混响 (Reverb / Freeverb)
    PARAM_CUSTOM_SET_STANDARD_GET("reverb.preset", reverb_preset, ParamType::kInt32, set_reverb_preset),
    PARAM_FLOAT("reverb.outgain", reverb_outgain, -12.0f, 6.0f, nullptr),
    PARAM_BOOL("reverb.autogain", reverb_autogain, hook_reverb_autogain),
    PARAM_BOOL("freeverb.enable", fv_enable, hook_freeverb_enable),
    PARAM_FLOAT("freeverb.decay", fv_decay, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("freeverb.damp", fv_damp, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("freeverb.wet", fv_wet, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("freeverb.dry", fv_dry, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("freeverb.roomsize", fv_roomsize, 0.5f, 2.5f, hook_freeverb_roomsize),
    PARAM_FLOAT("freeverb.width", fv_width, 0.2f, 2.0f, nullptr),

    // 09 动态均衡 (Dynamic EQ)
    PARAM_BOOL("dyneq.enable", dyneq_enable, nullptr),
    PARAM_FLOAT("dyneq.attack", dyneq_attack, 0.1f, 100.0f, hook_dyneq_attack),
    PARAM_FLOAT("dyneq.release", dyneq_release, 10.0f, 1000.0f, hook_dyneq_release),
    PARAM_FLOAT("dyneq.b1.attack", dyneq_b1_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.b1.release", dyneq_b1_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.b2.attack", dyneq_b2_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.b2.release", dyneq_b2_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.b3.attack", dyneq_b3_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.b3.release", dyneq_b3_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.low.attack", dyneq_b1_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.low.release", dyneq_b1_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.mid.attack", dyneq_b2_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.mid.release", dyneq_b2_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.high.attack", dyneq_b3_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.high.release", dyneq_b3_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.band1.attack", dyneq_b1_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.band1.release", dyneq_b1_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.band2.attack", dyneq_b2_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.band2.release", dyneq_b2_release, 10.0f, 1000.0f, nullptr),
    PARAM_FLOAT("dyneq.band3.attack", dyneq_b3_attack, 0.1f, 100.0f, nullptr),
    PARAM_FLOAT("dyneq.band3.release", dyneq_b3_release, 10.0f, 1000.0f, nullptr),
    PARAM_BOOL("dyneq.low.enable", dyneq_l_enable, nullptr),
    PARAM_FLOAT("dyneq.low.freq", dyneq_l_freq, 20.0f, 500.0f, nullptr),
    PARAM_FLOAT("dyneq.low.q", dyneq_l_q, 0.5f, 2.0f, nullptr),
    PARAM_FLOAT("dyneq.low.gain", dyneq_l_gain, -12.0f, 12.0f, nullptr),
    PARAM_FLOAT("dyneq.low.range", dyneq_l_range, 0.0f, 24.0f, nullptr),
    PARAM_FLOAT("dyneq.low.threshold", dyneq_l_threshold, -60.0f, 0.0f, nullptr),
    PARAM_BOOL("dyneq.mid.enable", dyneq_m_enable, nullptr),
    PARAM_FLOAT("dyneq.mid.freq", dyneq_m_freq, 200.0f, 8000.0f, nullptr),
    PARAM_FLOAT("dyneq.mid.q", dyneq_m_q, 0.3f, 10.0f, nullptr),
    PARAM_FLOAT("dyneq.mid.gain", dyneq_m_gain, -12.0f, 12.0f, nullptr),
    PARAM_FLOAT("dyneq.mid.range", dyneq_m_range, 0.0f, 24.0f, nullptr),
    PARAM_FLOAT("dyneq.mid.threshold", dyneq_m_threshold, -60.0f, 0.0f, nullptr),
    PARAM_BOOL("dyneq.high.enable", dyneq_h_enable, nullptr),
    PARAM_FLOAT("dyneq.high.freq", dyneq_h_freq, 2000.0f, 20000.0f, nullptr),
    PARAM_FLOAT("dyneq.high.q", dyneq_h_q, 0.5f, 2.0f, nullptr),
    PARAM_FLOAT("dyneq.high.gain", dyneq_h_gain, -12.0f, 12.0f, nullptr),
    PARAM_FLOAT("dyneq.high.range", dyneq_h_range, 0.0f, 24.0f, nullptr),
    PARAM_FLOAT("dyneq.high.threshold", dyneq_h_threshold, -60.0f, 0.0f, nullptr),
    PARAM_INT("dyneq.channels", dyneq_channels, 0, 255, nullptr),
    PARAM_INT("dyneq.channel_mask", dyneq_channels, 0, 255, nullptr),

    // 10 空间立体声与声场 (Stereo & Spatial)
    PARAM_BOOL("stereo.enable", stereo_enable, hook_stereo_enable),
    PARAM_FLOAT("stereo.mix", stereo_mix, 0.0f, 1.0f, hook_stereo_mix),
    PARAM_BOOL("stereo.bandUsed", stereo_band_used, hook_stereo_band_used),
    PARAM_BOOL("haas.enable", haas_enable, nullptr),
    PARAM_FLOAT("haas.delay", haas_delay_ms, 0.0f, 25.0f, nullptr),
    PARAM_FLOAT("haas.mix", haas_mix, 0.0f, 1.0f, nullptr),
    PARAM_INT("haas.side", haas_side, 0, 1, nullptr),
    PARAM_BOOL("crossfeed.enable", xfeed_enable, hook_crossfeed_enable),
    PARAM_INT("crossfeed.mode", xfeed_mode, 0, 3, hook_crossfeed_mode),
    PARAM_FLOAT("crossfeed.fcut", xfeed_fcut, 300.0f, 2000.0f, hook_crossfeed_custom),
    PARAM_FLOAT("crossfeed.feed", xfeed_feed, 1.0f, 15.0f, hook_crossfeed_custom),
    PARAM_BOOL("spatial.enable", spatial_enable, hook_spatial_enable),
    PARAM_INT("spatial.style", spatial_style, 0, 2, hook_spatial_style),
    PARAM_FLOAT("spatial.room", spatial_room, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("spatial.width", spatial_width, 0.5f, 1.5f, nullptr),
    PARAM_FLOAT("spatial.center", spatial_center, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("spatial.outgain", spatial_outgain, -12.0f, 6.0f, nullptr),
    PARAM_BOOL("spatial.autogain", spatial_autogain, hook_spatial_autogain),
    PARAM_FLOAT("spatial.mix", spatial_mix, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("spatial.elevation", spatial_elevation, -30.0f, 30.0f, nullptr),
    PARAM_BOOL("spatial.binaural", spatial_binaural, nullptr),
    PARAM_BOOL("spatial.fdn", spatial_fdn, nullptr),
    PARAM_FLOAT("spatial.late", spatial_late, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("spatial.headazim", spatial_headazim, -180.0f, 180.0f, nullptr),
    PARAM_BOOL("spatial.headtrack", spatial_headtrack, nullptr),

    // 11 低频与滤波处理 (BassMono, Shelf, Filter)
    PARAM_BOOL("bassmono.enable", bassmono_enable, nullptr),
    PARAM_FLOAT("bassmono.freq", bassmono_freq, 20.0f, 300.0f, nullptr),
    PARAM_BOOL("shelf.enable", shelf_enable, nullptr),
    PARAM_FLOAT("shelf.freq", shelf_freq, 40.0f, 400.0f, hook_shelf_recalc),
    PARAM_FLOAT("shelf.gain", shelf_gain, -15.0f, 15.0f, hook_shelf_recalc),
    PARAM_INT("shelf.channels", shelf_channels, 0, 255, nullptr),
    PARAM_INT("shelf.channel_mask", shelf_channels, 0, 255, nullptr),
    PARAM_BOOL("filter.enable", filter_enable, nullptr),
    PARAM_INT("filter.type", filter_type, 0, 2, hook_filter_recalc),
    PARAM_FLOAT("filter.freq", filter_freq, 20.0f, 20000.0f, hook_filter_recalc),
    PARAM_FLOAT("filter.q", filter_q, 0.3f, 10.0f, hook_filter_recalc),
    PARAM_INT("filter.channels", filter_channels, 0, 255, nullptr),
    PARAM_INT("filter.channel_mask", filter_channels, 0, 255, nullptr),

    // 12 信号与动态修整 (Exciter, Gate, Deesser, Loudness)
    PARAM_BOOL("exciter.enable", exciter_enable, nullptr),
    PARAM_FLOAT("exciter.amount", exciter_amount, 0.0f, 1.0f, nullptr),
    PARAM_FLOAT("exciter.hifreq", exciter_hifreq, 3000.0f, 10000.0f, nullptr),
    PARAM_INT("exciter.channels", exciter_channels, 0, 255, nullptr),
    PARAM_INT("exciter.channel_mask", exciter_channels, 0, 255, nullptr),
    PARAM_BOOL("exciter.oversample", exciter_oversample, nullptr),
    PARAM_BOOL("gate.enable", gate_enable, nullptr),
    PARAM_FLOAT("gate.threshold", gate_threshold, -60.0f, 0.0f, nullptr),
    PARAM_FLOAT("gate.attack", gate_attack, 1.0f, 100.0f, nullptr),
    PARAM_FLOAT("gate.release", gate_release, 10.0f, 500.0f, nullptr),
    PARAM_FLOAT("gate.hysteresis", gate_hysteresis, 0.0f, 12.0f, nullptr),
    PARAM_FLOAT("gate.range", gate_range, -80.0f, 0.0f, nullptr),
    PARAM_FLOAT("gate.hold", gate_hold_ms, 0.0f, 500.0f, nullptr),
    PARAM_FLOAT("gate.hold_ms", gate_hold_ms, 0.0f, 500.0f, nullptr),
    PARAM_BOOL("gate.autogain", gate_autogain, hook_gate_autogain),
    PARAM_INT("gate.channels", gate_channels, 0, 255, nullptr),
    PARAM_INT("gate.channel_mask", gate_channels, 0, 255, nullptr),
    PARAM_BOOL("deesser.enable", deesser_enable, nullptr),
    PARAM_FLOAT("deesser.freq", deesser_freq, 2000.0f, 10000.0f, nullptr),
    PARAM_FLOAT("deesser.amount", deesser_amount, 0.0f, 1.0f, nullptr),
    PARAM_BOOL("loudness.enable", loudness_enable, nullptr),
    PARAM_FLOAT("loudness.amount", loudness_amount, 0.0f, 1.0f, nullptr),
    PARAM_INT("loudness.channels", loudness_channels, 0, 255, nullptr),
    PARAM_INT("loudness.channel_mask", loudness_channels, 0, 255, nullptr),

    // 13 实时可编程 (Liveprog)
    PARAM_BOOL("liveprog.enable", lp_enable, hook_liveprog_enable),
    PARAM_CUSTOM("liveprog.code", set_liveprog_code, get_liveprog_code),
    PARAM_CUSTOM_SET_ONLY("liveprog.unload", set_liveprog_unload),
    PARAM_CUSTOM_GET_ONLY("liveprog.status", get_liveprog_status),

    // 14 输入输出与全局配置 (Input, Post Gain, Limiter, System)
    PARAM_FLOAT("input.gain", input_gain, -15.0f, 15.0f, nullptr),
    PARAM_FLOAT("post.gain", post_gain, -15.0f, 15.0f, hook_post_gain),
    PARAM_BOOL("limiter.enable", limiter_enable, hook_limiter_enable),
    PARAM_INT("limiter.channels", limiter_channels, 0, 255, nullptr),
    PARAM_INT("limiter.channel_mask", limiter_channels, 0, 255, nullptr),
    PARAM_FLOAT("limiter.release", limiter_release_ms, 10.0f, 500.0f, nullptr),
    PARAM_FLOAT("limiter.release_ms", limiter_release_ms, 10.0f, 500.0f, nullptr),
    PARAM_FLOAT("limiter.threshold", limiter_threshold, -24.0f, 0.0f, nullptr),
    PARAM_BOOL("limiter.link", limiter_link, nullptr),
    PARAM_BOOL("limiter.lookahead", limiter_lookahead, nullptr),
    PARAM_CUSTOM_GET_ONLY("gr.limiter", get_gr_limiter),
    PARAM_CUSTOM_GET_ONLY("gr.comp", get_gr_comp),
    PARAM_CUSTOM_GET_ONLY("gr.gate", get_gr_gate),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq", get_gr_dyneq),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq.low", get_gr_dyneq_b1),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq.mid", get_gr_dyneq_b2),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq.high", get_gr_dyneq_b3),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq.b1", get_gr_dyneq_b1),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq.b2", get_gr_dyneq_b2),
    PARAM_CUSTOM_GET_ONLY("gr.dyneq.b3", get_gr_dyneq_b3),
    PARAM_CUSTOM("channels.count", set_channels_count, get_channels_count),
    PARAM_CUSTOM_SET_STANDARD_GET("channels.mode", channels_mode, ParamType::kInt32, set_channels_mode),
    PARAM_CUSTOM("gate.maxIrSeconds", set_gate_max_ir_seconds, get_gate_max_ir_seconds),
    PARAM_CUSTOM("gate.maxFileMb", set_gate_max_file_mb, get_gate_max_file_mb),
    PARAM_CUSTOM("viz.fftSize", set_viz_fft_size, get_viz_fft_size),
    PARAM_CUSTOM("mode.latency", set_mode_latency, get_mode_latency),
    PARAM_CUSTOM_SET_ONLY("graph.order", set_graph_order),
    PARAM_CUSTOM_GET_ONLY("graph.effects", get_graph_effects),
};

#undef PARAM_FLOAT
#undef PARAM_INT
#undef PARAM_BOOL
#undef PARAM_CUSTOM
#undef PARAM_CUSTOM_SET_ONLY
#undef PARAM_CUSTOM_GET_ONLY
#undef PARAM_CUSTOM_SET_STANDARD_GET

/* ========================================================================= */
/*                          O(1) 哈希快速查找                                 */
/* ========================================================================= */

inline const EngineParamDesc* find_param_desc(std::string_view id) {
    static const auto& param_map = []() {
        std::unordered_map<std::string_view, const EngineParamDesc*> m;
        m.reserve(sizeof(kEngineParamTable) / sizeof(kEngineParamTable[0]));
        for (const auto& desc : kEngineParamTable) {
            m[desc.id] = &desc;
        }
        return m;
    }();
    auto it = param_map.find(id);
    return (it != param_map.end()) ? it->second : nullptr;
}
