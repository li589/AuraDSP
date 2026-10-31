#pragma once
//
// VizSilence.h — 桥层静音门控的 viz 帧兜底（P3 收口，2026-10-30）
//
// 背景：桥层 SilenceGate 一旦 GATED 就不再调用 auradsp_process，引擎的 viz
// SPSC ring 不再产出新帧。Dart 侧只有 1.5s stale 守卫（补一帧 -90dB 全零），
// 表现为 UI 先冻结 1.5s 再回落。桥在「整桥静音」时补一帧**合法静音帧**：
//   · spectrum / eq_in_spectrum 全 0（不是 0 dBFS：归一化 [0,1]，0 = 无能量）
//   · level_l/r、stage_levels_l/r、channel_levels、stage_ch_levels 全 -120dB
//   · GR 槽（stage 24..29）为 0（增益衰减量，静音时无衰减；不能写 -120）
// 简单 memset(0) 会让所有 dBFS 字段变成 0.0 = 0 dBFS 满电平，UI 会读成满格。
//
// 布局与 engine/auradsp_engine.h 的 auradsp_viz_frame（ABI v2）逐字段一致。
// 桥与引擎保持运行期解耦（只 GetProcAddress，不链接），此处镜像布局并用
// static_assert 钉住 1600B；引擎 viz 布局代际变化时必须同步本文件，并递增
// 各桥 <prefix>_abi / ab_abi_version 让 Dart 在加载时拒绝错位帧。
//
// 线程模型：本文件只允许控制线程调用（viz_read 由 Dart isolate 串行调用），
// SilentVizEmitter 的计数器无需原子；绝不要放进 RT 回调。
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace aurabridge {

constexpr size_t kVizFrameBytes = 1600;
constexpr int kVizBands = 32;
constexpr int kVizStageMax = 32;
constexpr int kVizChannelMax = 8;
constexpr int kVizGrFirst = 24;  // Limiter GR
constexpr int kVizGrLast = 29;   // Dyneq High GR

struct VizFrameMirror {
    uint64_t seq;
    double timestamp_ms;
    float spectrum[kVizBands];
    float eq_in_spectrum[kVizBands];
    float level_l_dbfs;
    float level_r_dbfs;
    float stage_levels_l[kVizStageMax];
    float stage_levels_r[kVizStageMax];
    uint32_t channel_count;
    float channel_levels[kVizChannelMax];
    float stage_ch_levels[kVizStageMax][kVizChannelMax];
};

static_assert(sizeof(VizFrameMirror) == kVizFrameBytes,
              "VizFrameMirror must match auradsp_viz_frame ABI v2 (1600B)");
static_assert(offsetof(VizFrameMirror, level_l_dbfs) == 272,
              "viz frame v1 prefix layout changed");
static_assert(offsetof(VizFrameMirror, channel_count) == 536,
              "viz frame v2 append layout changed");

/// 合成帧 seq 的高位标记：与引擎自增 seq 区分，日志/排障一眼可见是桥补帧。
/// UI 不比较 seq（只透传），因此高位标记不会造成消费端行为差异。
constexpr uint64_t kSyntheticVizSeqTag = 0xF000000000000000ull;

/// 在 [out] 的第 [index] 帧位置写入一帧静音帧。
/// [channels] 按桥当前处理声道数填（2/6/8；越界钳到 2..8）。
inline void FillSilentVizFrame(void* out, int index, uint64_t seq,
                               double timestamp_ms, int channels) {
    if (!out || index < 0) return;
    unsigned char* p = static_cast<unsigned char*>(out) +
                       static_cast<size_t>(index) * sizeof(VizFrameMirror);
    VizFrameMirror* f = reinterpret_cast<VizFrameMirror*>(p);
    memset(f, 0, sizeof(*f));

    f->seq = seq;
    f->timestamp_ms = timestamp_ms;
    f->level_l_dbfs = -120.0f;
    f->level_r_dbfs = -120.0f;
    for (int i = 0; i < kVizStageMax; ++i) {
        f->stage_levels_l[i] = -120.0f;
        f->stage_levels_r[i] = -120.0f;
    }
    // GR 槽是「衰减了多少 dB」（>=0），静音时无衰减 = 0，不能写 -120。
    for (int i = kVizGrFirst; i <= kVizGrLast; ++i) {
        f->stage_levels_l[i] = 0.0f;
        f->stage_levels_r[i] = 0.0f;
    }
    const int ch = channels < 2 ? 2 : (channels > kVizChannelMax ? kVizChannelMax : channels);
    f->channel_count = (uint32_t)ch;
    for (int c = 0; c < kVizChannelMax; ++c) f->channel_levels[c] = -120.0f;
    for (int i = 0; i < kVizStageMax; ++i) {
        for (int c = 0; c < kVizChannelMax; ++c) {
            f->stage_ch_levels[i][c] = -120.0f;
        }
    }
}

/// 每桥一个实例（viz_read 串行调用）。Emits 返回 1 = 写入 1 帧。
class SilentVizEmitter {
  public:
    int Emit(void* out, int index, int channels) {
        const uint64_t n = ++counter_;
        const uint64_t seq =
            kSyntheticVizSeqTag | (n & 0x0FFFFFFFFFFFFFFFull);
        // 时间戳沿用引擎的相对时间口径（viz 默认 30Hz），仅诊断用。
        FillSilentVizFrame(out, index, seq, (double)n * (1000.0 / 30.0),
                           channels);
        return 1;
    }

  private:
    uint64_t counter_ = 0;
};

}  // namespace aurabridge
