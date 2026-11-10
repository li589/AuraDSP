// ApoEngineHost.cpp — 见 ApoEngineHost.h 头注（设计 P2）。
#include "ApoEngineHost.h"

#include <sddl.h>
#include <cmath>
#include <cstring>
#include <vector>

namespace {

// 本 DLL 模块目录（APO 自身所在目录 = 安装布局的 driver/）。
bool SelfModuleDir(std::wstring& out) {
    HMODULE hMod = nullptr;
    if (!GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCWSTR)&SelfModuleDir, &hMod))
        return false;
    wchar_t path[MAX_PATH * 2] = {0};
    DWORD n = GetModuleFileNameW(hMod, path, (DWORD)(sizeof(path) / sizeof(path[0])));
    if (n == 0 || n >= sizeof(path) / sizeof(path[0])) return false;
    out.assign(path, n);
    size_t slash = out.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return false;
    out.resize(slash + 1);
    return true;
}

std::wstring ParentDir(const std::wstring& dir) {
    if (dir.size() <= 3) return dir;  // 盘根
    std::wstring d = dir.substr(0, dir.size() - 1);  // 去尾斜杠
    size_t slash = d.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return dir;
    return d.substr(0, slash + 1);
}

HANDLE CreateSharedMapping(const wchar_t* name, DWORD bytes) {
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            AURA_APO_SHARED_SDDL, SDDL_REVISION_1, &sd, nullptr))
        return nullptr;
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = sd;
    sa.bInheritHandle = FALSE;
    HANDLE h = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, bytes, name);
    LocalFree(sd);
    return h;
}

bool OwnerAlive(DWORD pid) {
    if (pid == 0) return false;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return false;
    DWORD code = 0;
    bool alive = GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
    CloseHandle(h);
    return alive;
}

}  // namespace

ApoEngineHost::~ApoEngineHost() { Stop(); }

// ---------------------------------------------------------------------------
// 座位（telemetry 块 CAS；设计 D3 + R4  stale 回收）
// ---------------------------------------------------------------------------
bool ApoEngineHost::OpenTelemetry() {
    if (tele_) return true;
    hTeleMap_ = CreateSharedMapping(AuraApoTelemetryName(), APO_TELEMETRY_BYTES);
    if (!hTeleMap_) return false;
    void* v = MapViewOfFile(hTeleMap_, FILE_MAP_ALL_ACCESS, 0, 0, APO_TELEMETRY_BYTES);
    if (!v) {
        CloseHandle(hTeleMap_);
        hTeleMap_ = nullptr;
        return false;
    }
    tele_ = (ApoTelemetryBlock*)v;
    if (tele_->magic != APO_TELEMETRY_MAGIC) {
        // 首建（或旧块）：整块初始化。并发首建写同值，无害。
        memset(tele_, 0, sizeof(*tele_));
        tele_->magic = APO_TELEMETRY_MAGIC;
        tele_->version = APO_TELEMETRY_VERSION;
    }
    return true;
}

bool ApoEngineHost::ClaimSeat() {
    if (!OpenTelemetry()) return false;
    if (InterlockedCompareExchange(&tele_->seatState, 1, 0) == 0) {
        seatOwner_ = true;
        return true;
    }
    // 座位被占：旧 owner 进程已死（audiodg 崩溃重启等）时走回收
    // 协议——先把状态拨到 2（回收中）者胜出接管，其余退让。
    DWORD owner = tele_->ownerPid;
    if (owner != 0 && owner != GetCurrentProcessId() && !OwnerAlive(owner)) {
        if (InterlockedCompareExchange(&tele_->seatState, 2, 1) == 1) {
            tele_->ownerPid = GetCurrentProcessId();
            InterlockedExchange(&tele_->seatState, 1);
            seatOwner_ = true;
            return true;
        }
    }
    InterlockedIncrement((volatile LONG*)&tele_->seatTaken);
    return false;
}

void ApoEngineHost::ReleaseSeat() {
    if (tele_ && seatOwner_) {
        tele_->ownerPid = 0;
        InterlockedExchange(&tele_->seatState, 0);
    }
    seatOwner_ = false;
}

// ---------------------------------------------------------------------------
// 引擎加载（D1 搜索序：纪律版同目录 → 主引擎同目录 → 主引擎上一级）
// ---------------------------------------------------------------------------
bool ApoEngineHost::LoadEngine() {
    std::wstring dir;
    if (!SelfModuleDir(dir)) return false;
    const std::wstring parent = ParentDir(dir);
    const std::wstring candidates[3] = {
        dir + L"auradsp_engine_apo.dll",
        dir + L"auradsp_engine.dll",
        parent + L"auradsp_engine.dll",
    };
    for (const auto& path : candidates) {
        HMODULE h = LoadLibraryW(path.c_str());
        if (!h) continue;
        auto fnAbi = (FnAbi)GetProcAddress(h, "auradsp_abi");
        fnCreate_ = (FnCreate)GetProcAddress(h, "auradsp_create");
        fnDestroy_ = (FnDestroy)GetProcAddress(h, "auradsp_destroy");
        fnProcess_ = (FnProcess)GetProcAddress(h, "auradsp_process");
        fnSetParam_ = (FnSetParam)GetProcAddress(h, "auradsp_set_param");
        fnLatency_ = (FnGetLatencyMs)GetProcAddress(h, "auradsp_get_latency_ms");
        fnVizRead_ = (FnVizRead)GetProcAddress(h, "auradsp_viz_read");
        if (fnAbi && fnAbi() == 2 && fnCreate_ && fnDestroy_ && fnProcess_ &&
            fnSetParam_ && fnLatency_ && fnVizRead_) {
            hEngineDll_ = h;
            return true;
        }
        fnCreate_ = fnDestroy_ = nullptr;
        fnProcess_ = nullptr;
        fnSetParam_ = nullptr;
        fnLatency_ = nullptr;
        fnVizRead_ = nullptr;
        FreeLibrary(h);
    }
    return false;
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------
bool ApoEngineHost::TryStart(UINT32 rate, UINT32 streamChannels) {
    if (active_.load()) return true;
    rate_ = rate;
    streamCh_ = streamChannels ? streamChannels : 2;
    // 声道决议（D8）：引擎只认 {2,4,6,8}。
    if (streamCh_ == 2 || streamCh_ == 4 || streamCh_ == 6 || streamCh_ == 8) {
        engCh_ = streamCh_;
        adapt_ = false;
    } else {
        engCh_ = 2;  // mono 复制 / 宽声道取前二，步长适配
        adapt_ = true;
    }
    if (!ClaimSeat()) return false;
    if (!LoadEngine()) {
        ReleaseSeat();
        return false;
    }
    engine_ = fnCreate_((float)rate_, kMaxBlock);
    if (!engine_) {
        FreeLibrary(hEngineDll_);
        hEngineDll_ = nullptr;
        ReleaseSeat();
        return false;
    }
    // 流声道是几何真相，压过参数块里的 channels.count（块侧该项
    // 在 worker diff 中跳过，见 ApplySnapshot）。
    int32_t cnt = (int32_t)engCh_;
    fnSetParam_(engine_, "channels.count", &cnt, sizeof(cnt));

    // 参数块由本进程（LocalService，有 Global 创建权）创建并
    // 持句柄保活：标准用户的 App 进程无 SeCreateGlobalPrivilege
    // 建不了 Global 对象，只能 Open 既有块（发布者口径）。块建
    // 不出时引擎照常跑（参数保持默认，applied 恒 0 可见）。
    hParamMap_ = CreateSharedMapping(AuraApoParamsName(), APO_BLOCK_MAPPING_BYTES);
    if (hParamMap_) {
        const void* v = MapViewOfFile(hParamMap_, FILE_MAP_READ, 0, 0,
                                      APO_BLOCK_MAPPING_BYTES);
        if (v) {
            paramView_ = (const uint8_t*)v;
        } else {
            CloseHandle(hParamMap_);
            hParamMap_ = nullptr;
        }
    }

    inBuf_ = new float[(size_t)kMaxBlock * engCh_];
    outBuf_ = new float[(size_t)kMaxBlock * engCh_];

    // telemetry 座位信息（App 面板/读者据此判定引擎在位）。
    tele_->ownerPid = GetCurrentProcessId();
    tele_->sampleRate = rate_;
    tele_->channels = streamCh_;
    tele_->paramsApplied = 0;
    tele_->fault = 0;
    appliedTotal_ = 0;
    snapshotValid_ = false;
    fault_.store(false);
    bypass_.store(false);

    hStop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    hThread_ = CreateThread(nullptr, 0, &ApoEngineHost::WorkerMain, this, 0, nullptr);
    if (!hThread_) {
        Stop();
        return false;
    }
    active_.store(true);
    return true;
}

void ApoEngineHost::Stop() {
    active_.store(false);
    if (hThread_) {
        if (hStop_) SetEvent(hStop_);
        WaitForSingleObject(hThread_, 3000);
        CloseHandle(hThread_);
        hThread_ = nullptr;
    }
    if (hStop_) {
        CloseHandle(hStop_);
        hStop_ = nullptr;
    }
    if (paramView_) {
        UnmapViewOfFile(paramView_);
        paramView_ = nullptr;
    }
    if (hParamMap_) {
        CloseHandle(hParamMap_);
        hParamMap_ = nullptr;
    }
    if (engine_) {
        if (fnDestroy_) fnDestroy_(engine_);
        engine_ = nullptr;
    }
    if (hEngineDll_) {
        FreeLibrary(hEngineDll_);
        hEngineDll_ = nullptr;
    }
    delete[] inBuf_;
    inBuf_ = nullptr;
    delete[] outBuf_;
    outBuf_ = nullptr;
    ReleaseSeat();
    if (tele_) {
        UnmapViewOfFile(tele_);
        tele_ = nullptr;
    }
    if (hTeleMap_) {
        CloseHandle(hTeleMap_);
        hTeleMap_ = nullptr;
    }
}

// ---------------------------------------------------------------------------
// RT 处理（SEH 闩锁；本函数体内不得有带析构的 C++ 对象，防 C2712）
// ---------------------------------------------------------------------------
bool ApoEngineHost::Process(const float* src, float* dst, UINT32 frames) {
    if (!active_.load(std::memory_order_acquire) ||
        fault_.load(std::memory_order_relaxed) ||
        bypass_.load(std::memory_order_relaxed) ||
        !src || !dst || frames == 0)
        return false;
    return ProcessGuarded(src, dst, frames);
}

bool ApoEngineHost::ProcessGuarded(const float* src, float* dst, UINT32 frames) {
    __try {
        ProcessDirect(src, dst, frames);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        fault_.store(true);
        if (tele_) tele_->fault = 1;
        return false;
    }
}

void ApoEngineHost::ProcessDirect(const float* src, float* dst, UINT32 frames) {
    UINT32 done = 0;
    while (done < frames) {
        UINT32 n = frames - done;
        if (n > (UINT32)kMaxBlock) n = (UINT32)kMaxBlock;
        const float* s = src + (size_t)done * streamCh_;
        float* d = dst + (size_t)done * streamCh_;
        if (!adapt_) {
            fnProcess_(engine_, s, d, (int)n);
        } else if (streamCh_ == 1) {
            for (UINT32 i = 0; i < n; i++) {
                inBuf_[i * 2] = s[i];
                inBuf_[i * 2 + 1] = s[i];
            }
            fnProcess_(engine_, inBuf_, outBuf_, (int)n);
            for (UINT32 i = 0; i < n; i++) d[i] = outBuf_[i * 2];
        } else {
            // 宽声道取前二：其余声道先原样落 dst，再覆盖前二。
            memcpy(d, s, (size_t)n * streamCh_ * sizeof(float));
            for (UINT32 i = 0; i < n; i++) {
                inBuf_[i * 2] = s[i * streamCh_];
                inBuf_[i * 2 + 1] = s[i * streamCh_ + 1];
            }
            fnProcess_(engine_, inBuf_, outBuf_, (int)n);
            for (UINT32 i = 0; i < n; i++) {
                d[i * streamCh_] = outBuf_[i * 2];
                d[i * streamCh_ + 1] = outBuf_[i * 2 + 1];
            }
        }
        done += n;
    }
}

double ApoEngineHost::LatencyMs() {
    if (!active_.load() || !engine_ || !fnLatency_) return 0.0;
    return fnLatency_(engine_);
}

// ---------------------------------------------------------------------------
// worker：参数应用（seqlock 快照 → diff → set_param）+ viz 泵
// ---------------------------------------------------------------------------
DWORD WINAPI ApoEngineHost::WorkerMain(LPVOID ctx) {
    ((ApoEngineHost*)ctx)->WorkerLoop();
    return 0;
}

void ApoEngineHost::WorkerLoop() {
    std::vector<uint8_t> snap(APO_BLOCK_MAPPING_BYTES);
    while (WaitForSingleObject(hStop_, 50) == WAIT_TIMEOUT) {
        // 参数块视图在 TryStart 已建（本进程创建并保活）；App 侧
        // 写入经 seqlock 校验后才采信，撕裂帧下轮重试。
        if (paramView_) {
            const auto* hdr = (const ApoParamBlockHeader*)paramView_;
            uint32_t s1 = hdr->writeSeq;
            if ((s1 & 1u) == 0 && hdr->magic == APO_PARAMS_MAGIC &&
                hdr->version == APO_PARAMS_VERSION) {
                memcpy(snap.data(), paramView_, APO_BLOCK_USED_BYTES);
                if (hdr->writeSeq == s1) ApplySnapshot(snap.data(), (const uint32_t*)snap.data());
            }
        }
        // viz 泵：抽干积压帧，只报最后一帧（telemetry 是状态面非流）。
        if (engine_ && fnVizRead_) {
            uint32_t n = fnVizRead_(engine_, vizFrames_, 4);
            if (n > 0) {
                const auradsp_viz_frame& f = vizFrames_[n - 1];
                tele_->levelLDb = f.level_l_dbfs;
                tele_->levelRDb = f.level_r_dbfs;
                auto db2lin = [](float db) {
                    if (db <= -120.0f) return 0.0f;
                    if (db > 0.0f) db = 0.0f;
                    return powf(10.0f, db / 20.0f);
                };
                tele_->peakOutL = db2lin(f.level_l_dbfs);
                tele_->peakOutR = db2lin(f.level_r_dbfs);
                // peakIn 无独立来源（viz 帧只有输出侧电平）：以输出
                // 峰值同值填报，面板 peakIn/Out 对比在 APO 面暂不
                // 具判别力（设计 P2 注记，勿据此判输入侧故障）。
                tele_->peakInL = tele_->peakOutL;
                tele_->peakInR = tele_->peakOutR;
                memcpy(tele_->spectrum, f.spectrum, sizeof(tele_->spectrum));
                tele_->updateSeq++;
            }
        }
    }
}

void ApoEngineHost::ApplySnapshot(const uint8_t* snap, const uint32_t* hdr) {
    const uint32_t* values = (const uint32_t*)(snap + APO_BLOCK_VALUES_OFFSET);
    const uint8_t* mask = snap + APO_BLOCK_MASK_OFFSET;
    auto bitSet = [&](uint32_t bit) { return (mask[bit / 8] >> (bit % 8)) & 1u; };
    bypass_.store(hdr[3] != 0);
    uint32_t applied = 0;
    for (uint32_t i = 0; i < APO_NUM_PARAM_COUNT; i++) {
        // 有效位未置：App 从未写过此参数——保持引擎默认值，
        // 严禁用块内零值覆盖（位图语义见 ApoShared.h）。
        if (!bitSet(i)) continue;
        if (snapshotValid_ && appliedNum_[i] == values[i]) continue;
        const char* id = kApoNumParamIds[i];
        // channels.count 由流几何决议（TryStart 已设），块侧跳过。
        if (strcmp(id, "channels.count") == 0) {
            appliedNum_[i] = values[i];
            continue;
        }
        uint32_t v = values[i];
        if (fnSetParam_(engine_, id, &v, sizeof(v)) == 0) applied++;
        appliedNum_[i] = values[i];
    }
    for (uint32_t s = 0; s < APO_STR_SLOT_COUNT; s++) {
        if (!bitSet(APO_NUM_PARAM_COUNT + s)) continue;  // 同上，有效位门
        uint32_t used = hdr[5 + s];
        const char* base = (const char*)(snap + kApoStrSlotOffsets[s]);
        if (used > kApoStrSlotCaps[s]) used = kApoStrSlotCaps[s];
        std::string cur;
        if (used > 0) cur.assign(base, strnlen(base, used));
        if (!snapshotValid_ || appliedStr_[s] != cur) {
            if (fnSetParam_(engine_, kApoStrSlotIds[s], cur.c_str(),
                            (uint32_t)cur.size() + 1) == 0)
                applied++;
            appliedStr_[s] = cur;
        }
    }
    snapshotValid_ = true;
    if (applied > 0) {
        appliedTotal_ += applied;
        if (tele_) tele_->paramsApplied = appliedTotal_;
    }
}
