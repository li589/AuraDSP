/* 多声道 EEL 脚本级宿主实现（liveprog.mc，方案 B，2026-11-09）。
 *
 * 结构与并发纪律逐条平移 legacy liveprogWrapper.c 的 P-016 影子槽
 * 实现（该文件保持不动）：3 槽独立 VM、控制线程影子编译、原子换
 * 活动指针、在途守卫双条件（in-flight==0 或 procCount>=retiredAt）、
 * 无槽时 500ms 有界等待返回 -4。差异只有三处，均为本级的语义本质：
 *   1. 样本寄存器是 spl0..spl7（8 路），处理对象是交织多声道缓冲；
 *   2. 越界声道（c >= channels）每采样预置 0 且不写回；
 *   3. 写回逐声道非有限卫士（本级位于引擎链尾，无下游卫士兜底）。
 *
 * RT 路径（mc_liveprog_process）：零分配、零锁、零系统调用；
 * VM 执行本身与立体声 LiveProgProcess 同量级（每采样帧一次）。 */
#include "dsp_mc_liveprog.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "legacy/jdsp/jdsp_header.h" /* NSEEL API + compileContext + aura_eel_ram_clear */

namespace {

constexpr int kMcSlots = 3;
constexpr int kMcChannels = 8;
constexpr int kMcSliders = 64;
constexpr double kSlotWaitMs = 500.0;

struct McSlot {
    NSEEL_VMCTX vm = nullptr;
    NSEEL_CODEHANDLE codehandleInit = nullptr;
    NSEEL_CODEHANDLE codehandleSlider = nullptr;
    NSEEL_CODEHANDLE codehandleProcess = nullptr;
    float* vmFs = nullptr;
    float* vmDevFs = nullptr;
    float* vmNumCh = nullptr;
    float* vmNch = nullptr;
    float* inputs[kMcChannels] = {};
    float* sliders[kMcSliders] = {};
    uint64_t appliedSliderGen[kMcSliders] = {};
    std::atomic<int> compileOk{0};
    uint64_t retiredAt = 0;
};

} // namespace

struct McLiveProgHost {
    McSlot slots[kMcSlots];
    std::atomic<McSlot*> active{nullptr};
    std::atomic<uint64_t> procCount{0};
    std::atomic<long> inFlight{0};
    std::atomic<int> enabled{0};
    std::atomic<float> fs{48000.0f};
    std::atomic<int> channels{2};
    std::atomic<float> sliders[kMcSliders]{};
    std::atomic<uint64_t> sliderGen[kMcSliders]{};
};

namespace {

/* 在途计数：std::atomic seq_cst 全序语义与 liveprogWrapper 的
 * lock 前缀计数等价（换槽守卫只依赖「换指针后读到 0 ⇒ 无在途调用
 * 持有旧快照」与计数单调性）。核心层零 OS API（平台隔离门禁口径），
 * 故不用 legacy 的平台内建写法。 */
long mc_inflight_inc(std::atomic<long>* p) {
    return p->fetch_add(1, std::memory_order_seq_cst) + 1;
}
long mc_inflight_dec(std::atomic<long>* p) {
    return p->fetch_sub(1, std::memory_order_seq_cst) - 1;
}
long mc_inflight_load(std::atomic<long>* p) {
    return p->load(std::memory_order_seq_cst);
}
double mc_now_ms() {
    using namespace std::chrono;
    return (double)duration_cast<microseconds>(
               steady_clock::now().time_since_epoch())
               .count() /
           1000.0;
}
void mc_sleep_ms(unsigned int ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

void mc_slot_init_vm(McLiveProgHost* host, McSlot* s) {
    s->compileOk.store(0, std::memory_order_relaxed);
    s->codehandleInit = nullptr;
    s->codehandleSlider = nullptr;
    s->codehandleProcess = nullptr;
    s->retiredAt = 0;
    s->vmFs = nullptr;
    s->vmDevFs = nullptr;
    s->vmNumCh = nullptr;
    s->vmNch = nullptr;
    for (int c = 0; c < kMcChannels; ++c) s->inputs[c] = nullptr;
    for (int i = 0; i < kMcSliders; ++i) s->sliders[i] = nullptr;
    const float fs = host->fs.load(std::memory_order_relaxed);
    const int channels = host->channels.load(std::memory_order_relaxed);
    s->vm = NSEEL_VM_alloc();
    if (!s->vm) return; /* OOM：槽不可用，编译时自然跳过 */
    /* P-053（2026-11-24 审查 H1）：拒绝 sleep 等阻塞内建（编译期校验）。 */
    NSEEL_VM_SetFunctionValidator(s->vm, NSEEL_aura_default_validator, nullptr);
    s->vmFs = NSEEL_VM_regvar(s->vm, "srate");
    if (s->vmFs) *s->vmFs = fs;
    s->vmDevFs = NSEEL_VM_regvar(s->vm, "dev_srate");
    if (s->vmDevFs) *s->vmDevFs = fs;
    s->vmNumCh = NSEEL_VM_regvar(s->vm, "num_ch");
    if (s->vmNumCh) *s->vmNumCh = (float)channels;
    s->vmNch = NSEEL_VM_regvar(s->vm, "nch");
    if (s->vmNch) *s->vmNch = (float)channels;
    for (int c = 0; c < kMcChannels; ++c) {
        char nm[8];
        std::snprintf(nm, sizeof(nm), "spl%d", c);
        s->inputs[c] = NSEEL_VM_regvar(s->vm, nm);
    }
}

/* 在指定槽上完整编译（平移 LiveProgCompileInto）：只动影子槽；
 * 失败清本槽残留 handle。返回 1=成功，<0=失败（错误码口径不变）。 */
int mc_compile_into(McLiveProgHost* host, McSlot* s, char* codeInit,
                    char* codeSlider, char* codeProcess) {
    if (!s->vm) return -1;
    s->compileOk.store(0, std::memory_order_relaxed);
    const float fs = host->fs.load(std::memory_order_relaxed);
    const int channels = host->channels.load(std::memory_order_relaxed);
    compileContext* ctx = (compileContext*)s->vm;
    NSEEL_VM_freevars(s->vm);
    NSEEL_init_memRegion(s->vm);
    /* P-045 同口径：只清已提交前缀（惰性分配器保证未提交页为零）。 */
    if (ctx->ram_state) aura_eel_ram_clear(ctx->ram_state);
    s->vmFs = NSEEL_VM_regvar(s->vm, "srate");
    if (s->vmFs) *s->vmFs = fs;
    s->vmDevFs = NSEEL_VM_regvar(s->vm, "dev_srate");
    if (s->vmDevFs) *s->vmDevFs = fs;
    s->vmNumCh = NSEEL_VM_regvar(s->vm, "num_ch");
    if (s->vmNumCh) *s->vmNumCh = (float)channels;
    s->vmNch = NSEEL_VM_regvar(s->vm, "nch");
    if (s->vmNch) *s->vmNch = (float)channels;
    for (int c = 0; c < kMcChannels; ++c) {
        char nm[8];
        std::snprintf(nm, sizeof(nm), "spl%d", c);
        s->inputs[c] = NSEEL_VM_regvar(s->vm, nm);
    }
    /* 滑块 slider1..64：只同步宿主显式变更过的代号，保留脚本 @init / @slider 自身默认值。 */
    for (int i = 1; i <= kMcSliders; ++i) {
        char nm[16];
        std::snprintf(nm, sizeof(nm), "slider%d", i);
        float* v = NSEEL_VM_regvar(s->vm, nm);
        s->sliders[i - 1] = v;
        s->appliedSliderGen[i - 1] = 0;
        if (v && host->sliderGen[i - 1].load(std::memory_order_acquire) != 0)
            *v = host->sliders[i - 1].load(std::memory_order_relaxed);
    }
    if (s->codehandleInit) { NSEEL_code_free(s->codehandleInit); s->codehandleInit = nullptr; }
    if (s->codehandleSlider) { NSEEL_code_free(s->codehandleSlider); s->codehandleSlider = nullptr; }
    if (s->codehandleProcess) { NSEEL_code_free(s->codehandleProcess); s->codehandleProcess = nullptr; }
    ctx->functions_common = 0;
    s->codehandleInit = NSEEL_code_compile_ex(s->vm, codeInit, 0, 1);
    if (!s->codehandleInit) { s->compileOk.store(0, std::memory_order_relaxed); return -1; }
    NSEEL_aura_budget_arm(s->codehandleInit, 4000000); /* P-053 托管预算 */
    NSEEL_code_execute(s->codehandleInit);
    if (codeSlider && codeSlider[0]) {
        s->codehandleSlider = NSEEL_code_compile(s->vm, codeSlider, 0);
        if (!s->codehandleSlider) {
            s->compileOk.store(0, std::memory_order_relaxed);
            NSEEL_code_free(s->codehandleInit);
            s->codehandleInit = nullptr;
            return -5;
        }
        NSEEL_aura_budget_arm(s->codehandleSlider, 4000000); /* P-053 */
        /* [PATCHED-AuraDSP P-059] 编译路径会额外初跑一次 @slider；
         * 该次也遵守 @init-only 契约，@init 本身仍在 guard 外。 */
        aura_eel_rt_guard compile_slider_guard;
        NSEEL_code_execute(s->codehandleSlider);
    }
    s->codehandleProcess = NSEEL_code_compile(s->vm, codeProcess, 0);
    if (!s->codehandleProcess) {
        s->compileOk.store(0, std::memory_order_relaxed);
        if (s->codehandleInit) { NSEEL_code_free(s->codehandleInit); s->codehandleInit = nullptr; }
        if (s->codehandleSlider) { NSEEL_code_free(s->codehandleSlider); s->codehandleSlider = nullptr; }
        return -3;
    }
    s->compileOk.store(1, std::memory_order_release);
    return 1;
}

/* 选编译目标槽（平移 LiveProgPickSlot）：非活动 + VM 可用 + 在途
 * 守卫双条件任一满足。无可用槽返回 nullptr。 */
McSlot* mc_pick_slot(McLiveProgHost* host) {
    const long inFlight = mc_inflight_load(&host->inFlight);
    McSlot* active = host->active.load(std::memory_order_acquire);
    const uint64_t procCount = host->procCount.load(std::memory_order_seq_cst);
    for (int i = 0; i < kMcSlots; ++i) {
        McSlot* s = &host->slots[i];
        if (s == active || !s->vm) continue;
        if (inFlight != 0 && procCount < s->retiredAt) continue;
        return s;
    }
    return nullptr;
}

int mc_compile_and_swap(McLiveProgHost* host, char* codeInit,
                        char* codeSlider, char* codeProcess) {
    McSlot* target = mc_pick_slot(host);
    if (!target) {
        const double deadline = mc_now_ms() + kSlotWaitMs;
        for (;;) {
            mc_sleep_ms(1);
            target = mc_pick_slot(host);
            if (target) break;
            if (mc_now_ms() >= deadline) return -4;
        }
    }
    const int rc = mc_compile_into(host, target, codeInit, codeSlider, codeProcess);
    if (rc != 1) return rc;
    McSlot* prev = host->active.load(std::memory_order_relaxed);
    host->active.store(target, std::memory_order_release);
    target->retiredAt = 0;
    if (prev && prev != target)
        prev->retiredAt = host->procCount.load(std::memory_order_seq_cst) + 1;
    return 1;
}

/* ---- 分段解析（平移 liveprogWrapper 的 P-039 口径） ---- */
const char* mc_find_sec_hdr(const char* code, const char* secName) {
    const size_t nameLen = std::strlen(secName);
    const char* p = code;
    while ((p = std::strstr(p, secName)) != nullptr) {
        const char* lineStart = p;
        while (lineStart > code && (lineStart[-1] == ' ' || lineStart[-1] == '\t'))
            lineStart--;
        if (lineStart == code || lineStart[-1] == '\n' || lineStart[-1] == '\r') {
            const char next = p[nameLen];
            if (next == 0 || next == '\r' || next == '\n' || next == ' ' || next == '\t')
                return p;
        }
        p += nameLen;
    }
    return nullptr;
}

const char* mc_sec_skip_line(const char* hdr, size_t nameLen) {
    const char* p = hdr + nameLen;
    while (*p && *p != '\n') p++;
    if (*p == '\n') p++;
    return p;
}

struct McSecItem {
    const char* name;
    const char* hdr;
    size_t nameLen;
    const char* bodyStart;
    size_t bodyLen;
};

} // namespace

McLiveProgHost* mc_liveprog_create(float sampleRate, int channels) {
    McLiveProgHost* host = new (std::nothrow) McLiveProgHost();
    if (!host) return nullptr;
    host->fs.store((sampleRate > 0.0f) ? sampleRate : 48000.0f,
                   std::memory_order_relaxed);
    host->channels.store((channels > 0) ? channels : 2, std::memory_order_relaxed);
    for (int i = 0; i < kMcSliders; ++i) {
        host->sliders[i].store(0.0f, std::memory_order_relaxed);
        host->sliderGen[i].store(0, std::memory_order_relaxed);
    }
    for (int i = 0; i < kMcSlots; ++i) mc_slot_init_vm(host, &host->slots[i]);
    host->active.store(&host->slots[0], std::memory_order_release);
    host->procCount.store(0, std::memory_order_relaxed);
    host->inFlight.store(0, std::memory_order_relaxed);
    return host;
}

void mc_liveprog_destroy(McLiveProgHost* host) {
    if (!host) return;
    for (int i = 0; i < kMcSlots; ++i) {
        McSlot* s = &host->slots[i];
        if (s->vm) {
            NSEEL_code_free(s->codehandleInit);
            NSEEL_code_free(s->codehandleSlider);
            NSEEL_code_free(s->codehandleProcess);
            NSEEL_VM_free(s->vm);
            s->vm = nullptr;
        }
    }
    delete host;
}

int mc_liveprog_load(McLiveProgHost* host, const char* code) {
    if (!host || !code) return -1;
    const long long strLen = (long long)std::strlen(code);
    const char* initHdr = mc_find_sec_hdr(code, "@init");
    if (!initHdr) return 0;
    const char* sampleHdr = mc_find_sec_hdr(code, "@sample");
    if (!sampleHdr) return -2;
    const char* sliderHdr = mc_find_sec_hdr(code, "@slider");
    const char* blockHdr = mc_find_sec_hdr(code, "@block");

    McSecItem secs[4];
    int numSecs = 0;
    secs[numSecs++] = {"@init", initHdr, 5, nullptr, 0};
    secs[numSecs++] = {"@sample", sampleHdr, 7, nullptr, 0};
    if (sliderHdr) secs[numSecs++] = {"@slider", sliderHdr, 7, nullptr, 0};
    if (blockHdr) secs[numSecs++] = {"@block", blockHdr, 6, nullptr, 0};
    for (int i = 0; i < numSecs - 1; ++i)
        for (int j = 0; j < numSecs - 1 - i; ++j)
            if (secs[j].hdr > secs[j + 1].hdr) {
                McSecItem tmp = secs[j];
                secs[j] = secs[j + 1];
                secs[j + 1] = tmp;
            }
    for (int i = 0; i < numSecs; ++i) {
        secs[i].bodyStart = mc_sec_skip_line(secs[i].hdr, secs[i].nameLen);
        const char* nextHdr = (i + 1 < numSecs) ? secs[i + 1].hdr : (code + strLen);
        secs[i].bodyLen = (nextHdr > secs[i].bodyStart)
                              ? (size_t)(nextHdr - secs[i].bodyStart) : 0;
    }
    char* codeInit = (char*)std::malloc((size_t)strLen + 1);
    char* codeSlider = (char*)std::malloc((size_t)strLen + 1);
    char* codeProcess = (char*)std::malloc((size_t)strLen + 1);
    if (!codeInit || !codeSlider || !codeProcess) {
        std::free(codeInit);
        std::free(codeSlider);
        std::free(codeProcess);
        return -3;
    }
    codeInit[0] = 0;
    codeSlider[0] = 0;
    codeProcess[0] = 0;
    for (int i = 0; i < numSecs; ++i) {
        if (std::strcmp(secs[i].name, "@init") == 0) {
            if (secs[i].bodyLen > 0) {
                std::memcpy(codeInit, secs[i].bodyStart, secs[i].bodyLen);
                codeInit[secs[i].bodyLen] = 0;
            }
        } else if (std::strcmp(secs[i].name, "@sample") == 0) {
            if (secs[i].bodyLen > 0) {
                std::memcpy(codeProcess, secs[i].bodyStart, secs[i].bodyLen);
                codeProcess[secs[i].bodyLen] = 0;
            }
        } else { /* @slider / @block 合并为每块前置段 */
            if (secs[i].bodyLen > 0) {
                size_t curLen = std::strlen(codeSlider);
                if (curLen > 0) codeSlider[curLen++] = '\n';
                std::memcpy(codeSlider + curLen, secs[i].bodyStart, secs[i].bodyLen);
                codeSlider[curLen + secs[i].bodyLen] = 0;
            }
        }
    }
    const int rc = mc_compile_and_swap(host, codeInit, codeSlider, codeProcess);
    std::free(codeInit);
    std::free(codeSlider);
    std::free(codeProcess);
    return rc;
}

void mc_liveprog_unload(McLiveProgHost* host) {
    if (!host) return;
    McSlot* active = host->active.load(std::memory_order_acquire);
    if (active) active->compileOk.store(0, std::memory_order_release);
}

void mc_liveprog_set_enabled(McLiveProgHost* host, int enabled) {
    if (!host) return;
    host->enabled.store(enabled ? 1 : 0, std::memory_order_relaxed);
}

int mc_liveprog_get_enabled(const McLiveProgHost* host) {
    if (!host) return 0;
    return host->enabled.load(std::memory_order_relaxed);
}

void mc_liveprog_set_sample_rate(McLiveProgHost* host, float sampleRate) {
    if (!host || !(sampleRate > 0.0f)) return;
    host->fs.store(sampleRate, std::memory_order_release);
}

void mc_liveprog_set_channels(McLiveProgHost* host, int channels) {
    if (!host || channels <= 0) return;
    host->channels.store(channels, std::memory_order_release);
}

void mc_liveprog_set_slider(McLiveProgHost* host, int index1Based, float value) {
    if (!host || index1Based < 1 || index1Based > kMcSliders) return;
    host->sliders[index1Based - 1].store(value, std::memory_order_relaxed);
    host->sliderGen[index1Based - 1].fetch_add(1, std::memory_order_release);
}

void mc_liveprog_process(McLiveProgHost* host, float* buf, int frames,
                         int channels) {
    if (!host || !buf || frames <= 0 || channels <= 0) return;
    /* [PATCHED-AuraDSP P-059] slider/block/sample 均在 RT guard 内执行。 */
    aura_eel_rt_guard rt_guard;
    /* 在途守卫双计数（平移 LiveProgProcess）：与 enable 无关，
     * 停用期间块边界也要放行影子槽复用。 */
    host->procCount.fetch_add(1, std::memory_order_seq_cst);
    mc_inflight_inc(&host->inFlight);
    if (host->enabled.load(std::memory_order_relaxed)) {
        McSlot* s = host->active.load(std::memory_order_acquire);
        if (s && s->compileOk.load(std::memory_order_acquire) &&
            s->codehandleProcess) {
            bool inputsOk = true;
            for (int c = 0; c < kMcChannels; ++c)
                if (!s->inputs[c]) { inputsOk = false; break; }
            if (inputsOk) {
                const float fs = host->fs.load(std::memory_order_relaxed);
                const int channelCount = host->channels.load(std::memory_order_relaxed);
                if (s->vmFs) *s->vmFs = fs;
                if (s->vmDevFs) *s->vmDevFs = fs;
                if (s->vmNumCh) *s->vmNumCh = (float)channelCount;
                if (s->vmNch) *s->vmNch = (float)channelCount;
                for (int i = 0; i < kMcSliders; ++i) {
                    const uint64_t g = host->sliderGen[i].load(std::memory_order_acquire);
                    if (g != s->appliedSliderGen[i] && s->sliders[i]) {
                        *s->sliders[i] = host->sliders[i].load(std::memory_order_relaxed);
                        s->appliedSliderGen[i] = g;
                    }
                }
                /* P-053 托管预算按块补给（slider/process 各 400 万次）。 */
                if (s->codehandleSlider) {
                    NSEEL_aura_budget_arm(s->codehandleSlider, 4000000);
                    NSEEL_code_execute(s->codehandleSlider);
                }
                NSEEL_aura_budget_arm(s->codehandleProcess, 4000000);
                int nch = channels;
                if (nch > kMcChannels) nch = kMcChannels;
                for (int i = 0; i < frames; ++i) {
                    float* frame = buf + (size_t)i * (size_t)channels;
                    for (int c = 0; c < kMcChannels; ++c)
                        *s->inputs[c] = (c < nch) ? (double)frame[c] : 0.0;
                    NSEEL_code_execute(s->codehandleProcess);
                    for (int c = 0; c < nch; ++c) {
                        const double v = *s->inputs[c];
                        /* [审查 M2 2026-11-24] 卫士须在 float 域复判：
                         * double 域 finite 的大值（1e300）cast 后成 Inf
                         * 仍会被旧写回放行，且无 ±10 钳位。先 cast、
                         * 再判 finite、再钳 ±10，与链尾卫士同口径。 */
                        float fv = (float)v;
                        if (!std::isfinite(fv)) fv = 0.0f;
                        else if (fv > 10.0f) fv = 10.0f;
                        else if (fv < -10.0f) fv = -10.0f;
                        frame[c] = fv;
                    }
                }
            }
        }
    }
    mc_inflight_dec(&host->inFlight);
}
