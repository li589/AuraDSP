/* engine_audiofile.cpp — 测试放音用的音频文件解码（WAV 之外）。
 *
 * MP3：engine/legacy 自带的 dr_mp3.h 在此单实例化（全仓唯一 DRMP3_IMPLEMENTATION；
 * legacy 源码零修改，只是用头文件——与 dr_wav/dr_flac 用法同模式）。
 * RT 无关：isolate 线程一次性调用，允许分配；失败返回 nullptr。
 * 路径：UTF-8 → wide（CJK 路径；read_text_file 同模式 R-1），再整文件读内存解。
 * 输出恒为 stereo interleave float32（drmp3_config.channels=2），与 Dart
 * FileSource 的数据契约一致；内存归属权移交调用方，用 auradsp_free_audio_buffer 释放
 * （同 CRT 堆，配对 free，跨 DLL 边界安全）。
 * 上限：源文件 64MB（约 27 分钟 @320kbps；测试放音足够，防畸形文件爆内存）。 */
#define DRMP3_IMPLEMENTATION
#include "legacy/jdsp/Effects/eel2/dr_mp3.h"

#include "platform/port/fs.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

constexpr size_t kMaxMp3Bytes = 64u * 1024u * 1024u;
/* 审查 L17：解码帧数硬顶（1<<25 帧 ≈ 12.7 分钟@44.1k，立体声 float
 * 解码缓冲 ≤256MiB）。只有输入字节上限时，低码率长文件可让 drmp3
 * 尝试分配数 GB；解码前先 init 探帧数、超顶直接拒绝。 */
constexpr uint64_t kMaxMp3Frames = 1ull << 25;

/* 二进制整文件读入（UTF-8 路径经平台端口；成功返回 malloc 缓冲 + 大小）。 */
unsigned char* read_bin_file(const char* utf8path, size_t* out_size) {
    *out_size = 0;
    if (!utf8path || !utf8path[0]) return nullptr;
    FILE* fp = auradsp::platform::fopen_utf8(utf8path, "rb");
    if (!fp) return nullptr;
    fseek(fp, 0, SEEK_END);
    const long sz = ftell(fp);
    if (sz <= 0 || (size_t)sz > kMaxMp3Bytes) {
        fclose(fp);
        return nullptr;
    }
    rewind(fp);
    unsigned char* buf = (unsigned char*)malloc((size_t)sz);
    if (!buf) {
        fclose(fp);
        return nullptr;
    }
    const size_t got = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);
    if (got != (size_t)sz) {
        free(buf);
        return nullptr;
    }
    *out_size = (size_t)sz;
    return buf;
}

}  // namespace

extern "C" {

float* auradsp_decode_audio_file(const char* utf8path, int* out_rate, uint64_t* out_frames) {
    if (out_rate) *out_rate = 0;
    if (out_frames) *out_frames = 0;
    if (!utf8path || !out_rate || !out_frames) return nullptr;
    size_t size = 0;
    unsigned char* bytes = read_bin_file(utf8path, &size);
    if (!bytes) return nullptr;
    {
        drmp3 probe;
        if (drmp3_init_memory(&probe, bytes, size, nullptr)) {
            const drmp3_uint64 est = drmp3_get_pcm_frame_count(&probe);
            drmp3_uninit(&probe);
            if (est > kMaxMp3Frames) {
                free(bytes);
                return nullptr;
            }
        }
    }
    drmp3_config cfg;
    cfg.channels = 2; /* 恒输出 stereo interleave（单声道源自动双声道复制） */
    cfg.sampleRate = 0; /* 保持源采样率（Dart FileSource 按 ratio 重采样播放） */
    drmp3_uint64 total = 0;
    float* pcm = drmp3_open_memory_and_read_pcm_frames_f32(bytes, size, &cfg, &total, nullptr);
    free(bytes);
    if (!pcm || total == 0) return nullptr;
    /* 有限性清洗（与 Dart decodeWavFile 同契约：有限钳位 ±1）。 */
    const size_t n = (size_t)total * 2;
    for (size_t i = 0; i < n; ++i) {
        const float v = pcm[i];
        if (v >= 1.0f)
            pcm[i] = 1.0f;
        else if (v <= -1.0f)
            pcm[i] = -1.0f;
        else if (v != v)
            pcm[i] = 0.0f;
    }
    *out_rate = (int)cfg.sampleRate;
    *out_frames = (uint64_t)total;
    return pcm;
}

void auradsp_free_audio_buffer(void* p) {
    free(p);
}

}  // extern "C"
