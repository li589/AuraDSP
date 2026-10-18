/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"
#include <cstdint> /* INT32_MAX（S-11 钳位） */
#include "legacy/jdsp/Effects/eel2/dr_wav.h"
#include "legacy/jdsp/Effects/eel2/dr_flac.h"


/* ---- IR 文件加载 + 统一文件门卫（M4，规划 §5.2）----
 * 防线：L1 magic 嗅探（不信任扩展名）→ L2 尺寸限额 → L3 本函数在控制线程
 * （调用方不持锁，解码失败不连坐音频）→ L4 解码后健全性（NaN/Inf/声道/长度）。
 * 采样率不匹配 → JamesDSPOfflineResampling 重采样到引擎 fs（44.1↔48 等）。
 * 成功 → Convolver1DLoadImpulseResponse(updateOld=1) 持久化到 vendor 存储。 */
/* 通用 UTF-8 路径文本读入（R-1 修复：Windows 走 _wfopen，避免 ANSI 代码页）。
 * 成功返回 malloc 的 NUL 结尾内容，失败置 error 返回 nullptr。 */
char* read_text_file(auradsp_handle h, const char* path, long max_bytes,
                     auradsp_status* st) {
    *st = AURADSP_OK;
    if (!path || !path[0]) { set_error(h, "path: empty"); *st = AURADSP_E_PARAM; return nullptr; }
#ifdef _WIN32
    const int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
    if (wlen <= 0) { set_error(h, "path: invalid encoding"); *st = AURADSP_E_PARAM; return nullptr; }
    wchar_t* wpath = (wchar_t*)malloc((size_t)wlen * sizeof(wchar_t));
    if (!wpath) { set_error(h, "path: OOM"); *st = AURADSP_E_IO; return nullptr; }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wlen);
    FILE* fp = _wfopen(wpath, L"rb");
    free(wpath);
#else
    FILE* fp = fopen(path, "rb");
#endif
    if (!fp) { set_error(h, "file: cannot open"); *st = AURADSP_E_IO; return nullptr; }
    fseek(fp, 0, SEEK_END);
    const long sz = ftell(fp);
    if (sz <= 0 || sz > max_bytes) {
        fclose(fp);
        set_error(h, "file: empty or too large");
        *st = AURADSP_E_PARAM;
        return nullptr;
    }
    rewind(fp);
    char* buf = (char*)malloc((size_t)sz + 1);
    if (!buf) { fclose(fp); set_error(h, "file: OOM"); *st = AURADSP_E_IO; return nullptr; }
    const size_t got = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);
    if (got != (size_t)sz) {
        free(buf);
        set_error(h, "file: read failed");
        *st = AURADSP_E_IO;
        return nullptr;
    }
    buf[sz] = 0;
    return buf;
}


/* 离线计算 IR 多声道频谱包络（复用 viz FFT 基建：WDL_real_fft + 32 对数带） */
void compute_ir_spectrum(auradsp_handle h, const float* data, size_t frames, int ch) {
    if (!h || !data || frames == 0 || ch <= 0) return;
    const int safe_ch = ch > 8 ? 8 : ch;
    memset(h->ir_spectrum, 0, sizeof(h->ir_spectrum));

    const int kN = kVizFftDefault;
    const int half = kN / 2;
    const int nmag = half < 2048 ? half : 2048;
    const int32_t* perm = WDL_fft_permute_tab(half);
    const float bin_hz = h->sample_rate / (float)kN;

    float* buf = (float*)malloc(kN * sizeof(float));
    if (!buf) return;

    for (int c = 0; c < safe_ch; ++c) {
        const size_t take = frames < (size_t)kN ? frames : (size_t)kN;
        // IR 特性：t=0 往往是核心直达声/脉冲尖峰，不能用对称 Hann 窗压制。
        // 采用单侧平顶 Tukey 窗：前段直通 (w=1.0)，仅尾部 64 帧施加平滑余弦衰减防截断跳变。
        const size_t fade_len = take > 128 ? 64 : (take > 4 ? take / 4 : 0);
        const size_t fade_start = take - fade_len;
        for (size_t i = 0; i < take; ++i) {
            float w = 1.0f;
            if (i >= fade_start && fade_len > 0) {
                const float frac = (float)(i - fade_start) / (float)fade_len;
                w = 0.5f * (1.0f + cosf(3.14159265358979f * frac));
            }
            buf[i] = data[i * ch + c] * w;
        }
        for (size_t i = take; i < (size_t)kN; ++i) {
            buf[i] = 0.0f;
        }

        WDL_real_fft(buf, kN, 0);

        float mag[2048];
        float max_m = 1e-9f;
        for (int i = 0; i < nmag; ++i) {
            const int pi = perm ? perm[i] : i;
            const float re = buf[pi * 2];
            const float im = buf[pi * 2 + 1];
            const float m = sqrtf(re * re + im * im);
            mag[i] = m;
            if (m > max_m) max_m = m;
        }

        for (int b = 0; b < AURADSP_VIZ_BANDS; ++b) {
            const int lo = (int)(kBandEdges[b] / bin_hz);
            const int hi = (int)(kBandEdges[b + 1] / bin_hz);
            if (hi <= lo || lo >= nmag) { h->ir_spectrum[c][b] = 0.0f; continue; }
            const int hb = hi > nmag ? nmag : hi;
            float m = 0.0f;
            for (int i = lo; i < hb; ++i) if (mag[i] > m) m = mag[i];
            const float rel = m / max_m;
            float v = 0.0f;
            if (rel > 1e-4f) {
                v = (20.0f * log10f(rel) + 50.0f) * (1.0f / 50.0f);
            }
            h->ir_spectrum[c][b] = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
        }
    }
    free(buf);
}


/* FileGate 文件体积上限（字节）：来自 gate.maxFileMb，兜底 64MiB。
 * 注意兜底判据必须是 "> 0" 而不是 "> 1"——set_param 已把取值夹到 [1,4096]，
 * 用 "> 1" 会把用户显式设置的 1MB 误判成"未设置"而回退到 64MB。
 * 控制线程下发，create 时也会按当时的值生效。 */
static inline long long gate_file_bytes(auradsp_handle h) {
    const float mb = h->gate_max_file_mb.load(std::memory_order_relaxed);
    const double v = (mb > 0.0f) ? (double)mb : 64.0;
    return (long long)(v * 1024.0 * 1024.0);
}


/* 重建汉宁窗。窗长必须**等于**实际 FFT 长度：取长窗的前 kN 个采样会只拿到
 * 上升沿（0→1），那不是窗函数——直流泄漏与旁瓣会直接把最低频带顶满
 * （实测 band0 从 ~0 变成 0.631）。
 * 只能在控制线程调用，且调用方须保证尚未发生过 emit_viz（见 viz.fftSize 参数）。 */
void rebuild_hann(auradsp_handle h, int n) {
    if (n < 2 || n > kVizFftMax) return;
    const double two_pi = 2.0 * 3.14159265358979;
    for (int i = 0; i < n; ++i) {
        h->hann[i] = (float)(0.5 * (1.0 - cos(two_pi * i / (n - 1))));
    }
}


auradsp_status load_ir_file(auradsp_handle h, const char* path) {
    /* L2：路径与文件尺寸限额 */
    if (!path || !path[0]) { set_error(h, "convolver.ir.path: empty path"); return AURADSP_E_PARAM; }
    /* 审查修复 R-1：Windows fopen 走 ANSI 代码页，中文路径必挂——
     * UTF-8 → UTF-16 后走 _wfopen */
#ifdef _WIN32
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
    if (wlen <= 0) { set_error(h, "convolver.ir.path: invalid encoding"); return AURADSP_E_PARAM; }
    wchar_t* wpath = (wchar_t*)malloc((size_t)wlen * sizeof(wchar_t));
    if (!wpath) { set_error(h, "convolver.ir.path: OOM"); return AURADSP_E_IO; }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wlen);
    FILE* fp = _wfopen(wpath, L"rb");
    free(wpath);
#else
    FILE* fp = fopen(path, "rb");
#endif
    if (!fp) { set_error(h, "convolver.ir: cannot open file"); return AURADSP_E_IO; }
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); set_error(h, "convolver.ir: seek failed"); return AURADSP_E_IO; }
    const long fsize = ftell(fp);
    if (fsize <= 44) { fclose(fp); set_error(h, "convolver.ir: file too small"); return AURADSP_E_PARAM; }
    const long long maxFileBytes = gate_file_bytes(h);
    if (fsize > maxFileBytes) {
        fclose(fp);
        set_error(h, "convolver.ir: file too large (exceeds configured gate.maxFileMb)");
        return AURADSP_E_PARAM;
    }
    rewind(fp);
    unsigned char* bytes = (unsigned char*)malloc((size_t)fsize);
    if (!bytes) { fclose(fp); set_error(h, "convolver.ir: OOM"); return AURADSP_E_IO; }
    const size_t got = fread(bytes, 1, (size_t)fsize, fp);
    fclose(fp);
    if (got != (size_t)fsize) { free(bytes); set_error(h, "convolver.ir: read failed"); return AURADSP_E_IO; }

    /* L1：magic 嗅探（RIFF..WAVE / fLaC；不信任扩展名） */
    const unsigned char* b = bytes;
    const bool is_wav = fsize > 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F'
                        && b[8] == 'W' && b[9] == 'A' && b[10] == 'V' && b[11] == 'E';
    const bool is_flac = fsize > 4 && b[0] == 'f' && b[1] == 'L' && b[2] == 'a' && b[3] == 'C';
    unsigned int ch = 0, src_rate = 0;
    size_t frames = 0;
    float* data = nullptr;
    if (is_wav) {
        drwav wav;
        if (!drwav_init_memory(&wav, bytes, (size_t)fsize, nullptr)) {
            free(bytes); set_error(h, "convolver.ir: WAV header corrupt"); return AURADSP_E_PARAM;
        }
        ch = wav.channels; src_rate = (unsigned int)wav.sampleRate; frames = (size_t)wav.totalPCMFrameCount;
        if (ch < 1 || ch > 8 || frames == 0) {
            drwav_uninit(&wav); free(bytes);
            set_error(h, "convolver.ir: invalid WAV channels/frames");
            return AURADSP_E_PARAM;
        }
        /* 审查修复 R-2：总样本量上限（16M 帧 × 8ch 会要 512MB 分配） */
        if (frames > 16u * 1024 * 1024 || (unsigned long long)frames * ch > 64ull * 1024 * 1024) {
            drwav_uninit(&wav); free(bytes);
            set_error(h, "convolver.ir: too long (max 16M frames / 64M samples)");
            return AURADSP_E_PARAM;
        }
        data = (float*)malloc(frames * ch * sizeof(float));
        if (!data) { drwav_uninit(&wav); free(bytes); set_error(h, "convolver.ir: OOM"); return AURADSP_E_IO; }
        const drwav_uint64 rd = drwav_read_pcm_frames_f32(&wav, frames, data);
        drwav_uninit(&wav);
        if (rd != frames) { free(data); free(bytes); set_error(h, "convolver.ir: WAV truncated"); return AURADSP_E_PARAM; }
    } else if (is_flac) {
        drflac* flac = drflac_open_memory(bytes, (size_t)fsize, nullptr);
        if (!flac) { free(bytes); set_error(h, "convolver.ir: FLAC corrupt"); return AURADSP_E_PARAM; }
        ch = flac->channels; src_rate = (unsigned int)flac->sampleRate; frames = (size_t)flac->totalPCMFrameCount;
        if (ch < 1 || ch > 8 || frames == 0 ||
            frames > 16u * 1024 * 1024 ||
            (unsigned long long)frames * ch > 64ull * 1024 * 1024) {
            drflac_close(flac); free(bytes);
            set_error(h, "convolver.ir: invalid FLAC channels/frames/length");
            return AURADSP_E_PARAM;
        }
        data = (float*)malloc(frames * ch * sizeof(float));
        if (!data) { drflac_close(flac); free(bytes); set_error(h, "convolver.ir: OOM"); return AURADSP_E_IO; }
        const drflac_uint64 rd = drflac_read_pcm_frames_f32(flac, frames, data);
        drflac_close(flac);
        if (rd != frames) { free(data); free(bytes); set_error(h, "convolver.ir: FLAC truncated"); return AURADSP_E_PARAM; }
    } else {
        free(bytes);
        set_error(h, "convolver.ir: unknown format (need WAV/FLAC)");
        return AURADSP_E_PARAM;
    }
    free(bytes);

    /* L4：健全性扫描（NaN/Inf 会毒化卷积输出） */
    const size_t n = frames * ch;
    float peak = 0.0f;
    for (size_t i = 0; i < n; ++i) {
        const float v = data[i];
        if (isnan(v) || isinf(v)) {
            free(data);
            set_error(h, "convolver.ir: NaN/Inf samples in file");
            return AURADSP_E_PARAM;
        }
        const float a = fabsf(v);
        if (a > peak) peak = a;
    }
    if (peak == 0.0f) {
        free(data);
        set_error(h, "convolver.ir: all-silent IR");
        return AURADSP_E_PARAM;
    }

    /* 时长门卫：来自 config.maxIrDurationSeconds（gate.maxIrSeconds）。
 * 放在重采样**之前**，按文件自身采样率判定用户感知的时长；
 * 同时保留原有的硬顶（16M 帧 / 64M 样本）作为内存的最后防线。 */
const float maxIrSec = h->gate_max_ir_seconds.load(std::memory_order_relaxed);
    /* S-12 修复：`> 0.1f` 在用户显式设 gate.maxIrSeconds=0.1 时门被跳过
     * （硬顶仍兜底，但用户配置静默失效）；改 >= 让显式 0.1 生效。 */
    if (maxIrSec >= 0.1f && src_rate > 0 &&
        (double)frames > (double)maxIrSec * (double)src_rate) {
        free(data);
        set_error(h, "convolver.ir: too long (exceeds configured gate.maxIrSeconds)");
        return AURADSP_E_PARAM;
    }

    /* 采样率不匹配 → 离线重采样到引擎 fs（诚实回读 src_rate 供 UI 提示） */
    size_t out_frames = frames;
    float* proc = data;
    if (src_rate != 0 && fabs((double)src_rate - h->jdsp.fs) > 0.5) {
        const double ratio = (double)h->jdsp.fs / (double)src_rate;
        out_frames = (size_t)ceil((double)frames * ratio);
        float* res = (float*)malloc(out_frames * ch * sizeof(float));
        if (!res) { free(data); set_error(h, "convolver.ir: OOM (resample)"); return AURADSP_E_IO; }
        memset(res, 0, out_frames * ch * sizeof(float));
        JamesDSPOfflineResampling(data, res, frames, out_frames, (int)ch, ratio);
        free(data);
        proc = res;
    }

    /* 交给 vendor：updateOld=1 → 存入 impulseResponseStorage（fs 变化可重建） */
    const int rc = Convolver1DLoadImpulseResponse(&h->jdsp, proc, ch, out_frames, 1);
    if (rc != 1) {
        free(proc);
        set_error(h, "convolver.ir: vendor load failed (partition select?)");
        return AURADSP_E_STATE;
    }
    compute_ir_spectrum(h, proc, out_frames, (int)ch);
    free(proc);
    h->ir_ready.store(true);
    /* S-11 修复：out_frames 为 size_t，恶意 WAV 声明极低 src_rate 且时长门
     * 被跳过时可 >INT32_MAX，直接强转会回读负帧数（仅显示用途，仍登记
     * 防回归）。三重尺寸门（maxFileMb/maxIrSec/16M 帧硬顶）正常已挡住，
     * 此处钳位是最后一道防线，不依赖门卫永不出错。 */
    h->ir_frames.store(out_frames > (size_t)INT32_MAX
                           ? (int32_t)INT32_MAX
                           : (int32_t)out_frames);
    h->ir_channels.store((int32_t)ch);
    h->ir_src_rate.store((int32_t)src_rate);
    h->ir_peak.store(peak);
    return AURADSP_OK;
}
