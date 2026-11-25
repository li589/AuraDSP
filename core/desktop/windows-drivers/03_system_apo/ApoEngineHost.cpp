// ApoEngineHost.cpp — 见 ApoEngineHost.h 头注（设计 P2）。
#include "ApoEngineHost.h"

#include "chain/channel_map.h"  // 声道适配统一表（第五十五轮）

#include "ApoEndpointProps.h"
#include <sddl.h>
#include <cmath>
#include <cstdio>
#include <cwctype>
#include <cstdlib>  // pluginSnap_ 的 malloc/free（S4 / APO-10）
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

// ---- 文件中转围栏（资源计划 P4）--------------------------------
// 参数块里的文件型路径（convolver.ir.path / ddc.load）只接受
// 中转根 %ProgramData%\AuraDSP\apo-assets 下的路径：App 发布者
// 写块前已换成中转副本（ApoTransit），此处是第二道围栏——参数
// 块写方异常/被劫持时，受保护进程也不得被指去打开任意文件。
// 比较口径：UTF-8→宽字符、斜杠归一、大小写不敏感、前缀 + 路径
// 分隔符边界（防 C:\...\apo-assets-evil 前缀冒充）。
std::wstring NormalizeForCompare(const std::wstring& w) {
    std::wstring out = w;
    for (auto& c : out) {
        if (c == L'/') c = L'\\';
        c = towlower(c);
    }
    return out;
}

bool IsUnderTransitRoot(const std::string& utf8Path) {
    static const std::wstring rootNorm = [] {
        wchar_t buf[MAX_PATH] = {};
        DWORD n = GetEnvironmentVariableW(L"ProgramData", buf, MAX_PATH);
        std::wstring root = (n > 0 && n < MAX_PATH) ? buf : L"C:\\ProgramData";
        root += L"\\AuraDSP\\apo-assets";
        std::wstring norm = NormalizeForCompare(root);
        if (norm.empty() || norm.back() != L'\\') norm += L'\\';
        return norm;
    }();
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8Path.c_str(),
                                  (int)utf8Path.size(), nullptr, 0);
    if (len <= 0) return false;
    std::wstring w((size_t)len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8Path.c_str(), (int)utf8Path.size(),
                        w.data(), len);
    // Canonicalize lexically before the prefix test:
    // GetFullPathNameW resolves "." / ".." segments without
    // touching the filesystem. A raw prefix test passes
    // "apo-assets\..\..\Users\x\evil.dll", which the loader
    // then resolves OUTSIDE the transit root - the fence would
    // be decorative for exactly the paths it exists to reject.
    wchar_t canon[MAX_PATH] = {};
    const DWORD cn = GetFullPathNameW(w.c_str(), MAX_PATH, canon, nullptr);
    if (cn == 0 || cn >= MAX_PATH) return false;
    const std::wstring p = NormalizeForCompare(std::wstring(canon, cn));
    return p.size() > rootNorm.size() &&
           p.compare(0, rootNorm.size(), rootNorm) == 0;
}

HANDLE CreateSharedMapping(const wchar_t* name, DWORD bytes, bool pluginBlock) {
    const wchar_t* primary = AURA_APO_SHARED_SDDL;
    const wchar_t* fallback = AURA_APO_SHARED_SDDL_FALLBACK;
    if (pluginBlock) {
#ifndef AURADSP_APO_PLUGIN_TRUSTED_TEST_ONLY
        primary = AURA_APO_PLUGINS_SDDL;
        fallback = AURA_APO_PLUGINS_SDDL_FALLBACK;
#endif
    }
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            primary, SDDL_REVISION_1, &sd, nullptr) &&
        // Win7 退路（见 ApoShared.h 的 FALLBACK 注）：含
        // AppContainer ACE 的 SDDL 若解析失败，退回 LS/IU 口径。
        !ConvertStringSecurityDescriptorToSecurityDescriptorW(
            fallback, SDDL_REVISION_1, &sd, nullptr))
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
    // 第四十一轮：带令牌端点用分块（块名含端点哈希），座位随块
    // 按端点分；无令牌回落全局块（v1 语义）。
    wchar_t nameBuf[80];
    const wchar_t* name = AuraApoTelemetryName();
    if (!endpointId_.empty()) {
        AuraApoTelemetryNameFor(endpointHash_, nameBuf, 80);
        name = nameBuf;
    }
    hTeleMap_ = CreateSharedMapping(name, APO_TELEMETRY_BYTES, false);
    if (!hTeleMap_) return false;
    void* v = MapViewOfFile(hTeleMap_, FILE_MAP_ALL_ACCESS, 0, 0, APO_TELEMETRY_BYTES);
    if (!v) {
        CloseHandle(hTeleMap_);
        hTeleMap_ = nullptr;
        return false;
    }
    tele_ = (ApoTelemetryBlock*)v;
    if (tele_->magic == APO_TELEMETRY_MAGIC &&
        tele_->version < APO_TELEMETRY_VERSION) {
        // 旧版块复用：追加段在建块时整页零初始化，升版即可用。
        tele_->version = APO_TELEMETRY_VERSION;
    }
    if (tele_->magic != APO_TELEMETRY_MAGIC) {
        // 首建（或旧块）：整块初始化。并发首建写同值，无害。
        memset(tele_, 0, sizeof(*tele_));
        tele_->magic = APO_TELEMETRY_MAGIC;
        tele_->version = APO_TELEMETRY_VERSION;
    }
    if (!endpointId_.empty()) {
        // 身份自证 + 碰撞防护：块内已盖了别的端点的章（FNV 碰撞
        // 或块名被占用）时拒绝使用本块——宁可本端点退回透传，也
        // 不污染另一端点的 telemetry/座位。未盖章则盖上。
        if (tele_->endpointId[0] != 0 &&
            wcscmp(tele_->endpointId, endpointId_.c_str()) != 0) {
            UnmapViewOfFile(tele_);
            tele_ = nullptr;
            CloseHandle(hTeleMap_);
            hTeleMap_ = nullptr;
            return false;
        }
        tele_->endpointHash = endpointHash_;
        wcsncpy_s(tele_->endpointId, endpointId_.c_str(), _TRUNCATE);
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
// 引擎加载（A2 收紧，2026-11-20 user 裁定：仅纪律版同目录一份）
// ---------------------------------------------------------------------------
// 原 D1 三候选序（纪律版同目录 → 主引擎同目录 → 主引擎上一级）会让 APO 在
// 纪律版缺失时回退加载非纪律版主引擎（/MD），与 P0「只有 /MT + /guard:cf
// 纪律版可进 audiodg」的纪律相悖。收紧后只认同目录 auradsp_engine_apo.dll
// 一份：缺失/损坏即加载失败、上层闩锁透传，由 App 侧检出并提示修复安装。
void ApoEngineHost::PublishLoadDiag() {
    if (!tele_) return;
    tele_->loadStage = loadStage_;
    tele_->loadErr = loadErr_;
}

bool ApoEngineHost::LoadEngine() {
    std::wstring dir;
    if (!SelfModuleDir(dir)) {
        loadStage_ = APO_LOAD_STAGE_NO_DIR;
        loadErr_ = GetLastError();
        return false;
    }
    const std::wstring path = dir + L"auradsp_engine_apo.dll";
    {
        HMODULE h = LoadLibraryW(path.c_str());
        if (!h) {
            loadStage_ = APO_LOAD_STAGE_LOAD_FAILED;
            loadErr_ = GetLastError();
            return false;
        }
        auto fnAbi = (FnAbi)GetProcAddress(h, "auradsp_abi");
        fnCreate_ = (FnCreate)GetProcAddress(h, "auradsp_create");
        fnDestroy_ = (FnDestroy)GetProcAddress(h, "auradsp_destroy");
        fnProcessGeometry_ = (FnProcessGeometry)GetProcAddress(
            h, "auradsp_process_geometry");
        fnRequestGeometry_ = (FnRequestGeometry)GetProcAddress(
            h, "auradsp_request_geometry");
        fnGetActiveGeometry_ = (FnGetActiveGeometry)GetProcAddress(
            h, "auradsp_get_active_geometry");
        fnSetParam_ = (FnSetParam)GetProcAddress(h, "auradsp_set_param");
        fnLatency_ = (FnGetLatencyMs)GetProcAddress(h, "auradsp_get_latency_ms");
        fnVizRead_ = (FnVizRead)GetProcAddress(h, "auradsp_viz_read");
        fnGetParam_ = (FnGetParam)GetProcAddress(h, "auradsp_get_param");
        auto pSlotLoad = (FnPluginSlotLoad)GetProcAddress(h, "auradsp_plugin_slot_load");
        auto pSlotUnload = (FnPluginSlot)GetProcAddress(h, "auradsp_plugin_slot_unload");
        auto pSlotBypass = (FnPluginSlotInt)GetProcAddress(h, "auradsp_plugin_slot_set_bypass");
        auto pSlotStage = (FnPluginSlotInt)GetProcAddress(h, "auradsp_plugin_slot_set_insert_stage");
        auto pSlotChannels = (FnPluginSlotInt)GetProcAddress(h, "auradsp_plugin_slot_set_channels");
        auto pSlotLoadPreset = (FnPluginSlotPreset)GetProcAddress(h, "auradsp_plugin_slot_load_preset");
        auto pSlotStatus = (FnPluginSlotStatus)GetProcAddress(h, "auradsp_plugin_slot_get_status");
        auto pSetPdc = (FnPluginFlag)GetProcAddress(h, "auradsp_plugin_set_pdc");
        auto pChainEnabled = (FnPluginFlag)GetProcAddress(h, "auradsp_plugin_chain_set_enabled");
        if (fnAbi && fnAbi() == 2 && fnCreate_ && fnDestroy_ &&
            fnProcessGeometry_ && fnRequestGeometry_ && fnGetActiveGeometry_ &&
            fnSetParam_ &&
            fnLatency_ && fnVizRead_) {
            hEngineDll_ = h;
            // 插件通道是可选能力：符号全齐才启用（纪律版风味
            // 恒齐；若某构建缺符号则整通道静默禁用）。
            fnSlotLoad_ = pSlotLoad;
            fnSlotUnload_ = pSlotUnload;
            fnSlotBypass_ = pSlotBypass;
            fnSlotStage_ = pSlotStage;
            fnSlotChannels_ = pSlotChannels;
            fnSlotLoadPreset_ = pSlotLoadPreset;
            fnSlotStatus_ = pSlotStatus;
            fnSetPdc_ = pSetPdc;
            fnChainEnabled_ = pChainEnabled;
            pluginsOk_ = pSlotLoad && pSlotUnload && pSlotBypass && pSlotStage &&
                         pSlotChannels && pSlotLoadPreset && pSlotStatus &&
                         pSetPdc && pChainEnabled;
            loadStage_ = APO_LOAD_STAGE_READY;
            loadErr_ = 0;
            return true;
        }
        fnCreate_ = nullptr;
        fnDestroy_ = nullptr;
        fnProcessGeometry_ = nullptr;
        fnSetParam_ = nullptr;
        fnGetParam_ = nullptr;
        fnLatency_ = nullptr;
        fnVizRead_ = nullptr;
        FreeLibrary(h);
    }
    // 加载上了但 ABI/符号不符（DLL 缺失/依赖缺失已在上方以
    // LOAD_FAILED + GetLastError 先行返回，二者由此分得清）。
    loadStage_ = APO_LOAD_STAGE_ABI;
    loadErr_ = 0;
    return false;
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------
bool ApoEngineHost::TryStart(UINT32 rate, UINT32 streamChannels,
                             const EndpointContext& ep) {
    if (active_.load()) {
        // 全面复审 S4（APO-8）：已活跃时此前无条件 return true——
        // 同实例被以新格式（率/声道）重新 Lock 时，引擎仍按旧
        // 几何运行、telemetry 却报新几何。几何相符才短路返回；
        // 不符先停旧引擎、落入下方按新几何完整重建。
        if (rate_ == rate &&
            streamCh_ == (streamChannels ? streamChannels : 2)) {
            return true;
        }
        Stop();
    }
    // 端点上下文（第四十一轮）：身份决定座位/telemetry 分块，
    // 覆写决定本端点声道族的有效值来源（压过全局参数块）。
    endpointId_ = ep.endpointId ? ep.endpointId : L"";
    endpointHash_ = AuraEndpointIdHash(endpointId_.c_str());
    epModeValid_ = ep.modeValid;
    epMode_ = ep.mode;
    epFillValid_ = ep.fillValid;
    epFill_ = ep.fill;
    appliedEpMode_ = -1;
    appliedEpFill_ = -1;
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
    // 安全初值仅为 create 的契约几何；真实 active 快照在 create 后查询，
    // 请求中的流宽度绝不提前发布给 RT。
    liveEngCh_.store(2);
    liveTrunc_.store(false);
    if (!ClaimSeat()) return false;
    if (!LoadEngine()) {
        PublishLoadDiag();  // 失败结局先落 telemetry 再放座（S3）
        ReleaseSeat();
        return false;
    }
    engine_ = fnCreate_((float)rate_, kMaxBlock);
    if (!engine_) {
        loadStage_ = APO_LOAD_STAGE_CREATE;
        loadErr_ = 0;
        PublishLoadDiag();
        FreeLibrary(hEngineDll_);
        hEngineDll_ = nullptr;
        ReleaseSeat();
        return false;
    }
    // create 的 active 几何是 RT 的唯一初始真相；先发布这份完整请求基线，
    // 再单独发布流宽度/端点模式请求。RT 仅在完整 active==request 后切步进。
    const UINT32 initialWant = engCh_;
    auradsp_geometry initialActive{0, 0, 0};
    if (!fnGetActiveGeometry_ ||
        fnGetActiveGeometry_(engine_, &initialActive) != AURADSP_OK ||
        !aurahost::ValidGeometry({initialActive.generation, initialActive.channels,
                                  initialActive.mode})) {
        loadStage_ = APO_LOAD_STAGE_CREATE;
        loadErr_ = 0;
        PublishLoadDiag();
        fnDestroy_(engine_);
        engine_ = nullptr;
        FreeLibrary(hEngineDll_);
        hEngineDll_ = nullptr;
        ReleaseSeat();
        return false;
    }
    requestedGeometry_.Reset();
    if (!requestedGeometry_.Publish({initialActive.generation,
                                     initialActive.channels,
                                     initialActive.mode})) {
        loadStage_ = APO_LOAD_STAGE_CREATE;
        loadErr_ = 0;
        PublishLoadDiag();
        fnDestroy_(engine_);
        engine_ = nullptr;
        FreeLibrary(hEngineDll_);
        hEngineDll_ = nullptr;
        ReleaseSeat();
        return false;
    }
    engCh_ = (UINT32)initialActive.channels;
    liveEngCh_.store((UINT32)initialActive.channels, std::memory_order_relaxed);
    liveTrunc_.store(initialActive.mode == 1, std::memory_order_relaxed);
    const int32_t initialMode = epModeValid_ ? epMode_ : initialActive.mode;
    if ((UINT32)initialActive.channels != initialWant ||
        initialActive.mode != initialMode) {
        uint64_t generation = 0;
        if (fnRequestGeometry_(engine_, (int32_t)initialWant, initialMode,
                               &generation) == AURADSP_OK) {
            (void)requestedGeometry_.Publish(
                {generation, (int32_t)initialWant, initialMode});
        }
    }
    aurahost::GeometrySnapshot requested{};
    if (epModeValid_ && requestedGeometry_.Load(&requested) &&
        requested.mode == initialMode) {
        appliedEpMode_ = initialMode;
    }
    if (epFillValid_) {
        int32_t f = epFill_;
        if (fnSetParam_(engine_, "channels.upmix_fill", &f, sizeof(f)) == 0)
            appliedEpFill_ = epFill_;
    }

    // 参数块由本进程（LocalService，有 Global 创建权）创建并
    // 持句柄保活：标准用户的 App 进程无 SeCreateGlobalPrivilege
    // 建不了 Global 对象，只能 Open 既有块（发布者口径）。块建
    // 不出时引擎照常跑（参数保持默认，applied 恒 0 可见）。
    hParamMap_ = CreateSharedMapping(AuraApoParamsName(), APO_BLOCK_MAPPING_BYTES,
                                     false);
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

    // 插件块（Part I Q2）：与参数块同一创建口径（本进程创建、
    // 持句柄保活）；建不出时通道禁用，引擎照常跑。
    hPluginMap_ = CreateSharedMapping(AuraApoPluginsName(), APO_PLUGIN_BLOCK_BYTES,
                                      true);
    if (hPluginMap_) {
        const void* v = MapViewOfFile(hPluginMap_, FILE_MAP_READ, 0, 0,
                                      APO_PLUGIN_BLOCK_BYTES);
        if (v) {
            pluginView_ = (const uint8_t*)v;
        } else {
            CloseHandle(hPluginMap_);
            hPluginMap_ = nullptr;
        }
    }
    for (auto& ap : appliedPlugins_) ap = AppliedPlugin{};
    pluginHdrSeen_ = false;
    {
        wchar_t tmp[MAX_PATH];
        DWORD n = GetTempPathW(MAX_PATH, tmp);
        pluginTempDir_ = (n > 0 && n < MAX_PATH) ? tmp : L"";
    }

    // 缓冲按流宽分配：运行中 engCh 可在 [2, streamCh_] 内
    // 随参数块变化（第四十六轮 S2），不得按初始 engCh_ 收窄。
    inBuf_ = new float[(size_t)kMaxBlock * (streamCh_ > 2 ? streamCh_ : 2)];
    outBuf_ = new float[(size_t)kMaxBlock * (streamCh_ > 2 ? streamCh_ : 2)];

    // telemetry 座位信息（App 面板/读者据此判定引擎在位）。
    tele_->ownerPid = GetCurrentProcessId();
    tele_->sampleRate = rate_;
    tele_->channels = streamCh_;
    tele_->paramsApplied = 0;
    tele_->engChHost = liveEngCh_.load();
    tele_->engChEngine = liveEngCh_.load();
    tele_->effChannelsMode = liveTrunc_.load() ? 1u : 0u;
    tele_->effValid = 0;
    tele_->fault = 0;
    tele_->loadStage = APO_LOAD_STAGE_READY;
    tele_->loadErr = 0;
    for (auto& p : tele_->plugins) p = ApoTelemetryBlock::PluginSlot{};
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
    if (pluginView_) {
        UnmapViewOfFile(pluginView_);
        pluginView_ = nullptr;
    }
    if (pluginSnap_) {
        free(pluginSnap_);
        pluginSnap_ = nullptr;
    }
    if (hPluginMap_) {
        CloseHandle(hPluginMap_);
        hPluginMap_ = nullptr;
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

UINT32 ApoEngineHost::ResolveEngCh() const {
    // 天花板 = 流宽；参数块 channels.count 合法时再封顶。
    // 流宽非法（mono/3/5/7）维持 stereo 决议（D8 旧口径）。
    if (!(streamCh_ == 2 || streamCh_ == 4 || streamCh_ == 6 ||
          streamCh_ == 8)) {
        return 2;
    }
    UINT32 cap = streamCh_;
    if ((userCh_ == 2 || userCh_ == 4 || userCh_ == 6 || userCh_ == 8) &&
        userCh_ < cap) {
        cap = userCh_;
    }
    return cap;
}

uint32_t ApoEngineHost::ApplyEngChResolution() {
    if (!engine_ || !fnRequestGeometry_) return 0;
    const UINT32 want = ResolveEngCh();
    const int32_t mode = effMode_;
    aurahost::GeometrySnapshot current{};
    if (!requestedGeometry_.Load(&current)) return 0;
    if ((uint32_t)current.channels == want && current.mode == mode) return 0;
    uint64_t generation = 0;
    if (fnRequestGeometry_(engine_, (int32_t)want, mode, &generation) !=
        AURADSP_OK) {
        return 0;  // 失败保留上一份完整 pending/active 几何。
    }
    const aurahost::GeometrySnapshot next{generation, (int32_t)want, mode};
    if (!requestedGeometry_.Publish(next)) return 0;
    engCh_ = want;
    uint32_t applied = 0;
    if ((uint32_t)current.channels != want) applied |= 1u;
    if (current.mode != mode) applied |= 2u;
    return applied;
}

// 矩阵模式的折叠 gather（系数与 VAIO 桥 RemapInterleavedAudio
// 同表）：把 srcCh 宽折成 engCh 宽再喂引擎，引擎内再折到
// 立体声处理——内容不丢。离散模式不走这里（顺序截断）。
static void FoldGather(const float* s, float* in, UINT32 srcCh, UINT32 engCh,
                       UINT32 n) {
    // 折叠表已收编至 engine/chain/channel_map.h（第五十五轮，
    // 全宿主单一真相；8→4 主次为 r47 S2 定案：BL/BR 为主、
    // SL/SR 折入）。此处只委托，数值由 channel_map_test 守。
    chmap_fold(s, (int)srcCh, in, (int)engCh, (int)n);
}

// 引擎声道 → 流内位置映射（第四十七轮 S2 立表：eng=4 时引擎
// BL/BR 对流的后环绕位）已于第五十五轮收编至
// engine/chain/channel_map.h 的 chmap_stream_pos，本文件经
// chmap_gather_discrete / chmap_scatter_discrete 直接使用。

void ApoEngineHost::ProcessDirect(const float* src, float* dst, UINT32 frames) {
    auradsp_geometry active{0, 0, 0};
    if (fnGetActiveGeometry_(engine_, &active) != AURADSP_OK) {
        ZeroMemory(dst, (size_t)frames * streamCh_ * sizeof(float));
        return;
    }
    aurahost::GeometrySnapshot requestedSnapshot{};
    const bool haveRequested = requestedGeometry_.Load(&requestedSnapshot);
    const auradsp_geometry requested{requestedSnapshot.generation,
                                     requestedSnapshot.channels,
                                     requestedSnapshot.mode};
    if (!haveRequested || active.generation != requested.generation ||
        active.channels != requested.channels || active.mode != requested.mode) {
        // 过渡块只推进完整 active/request，不发布新步进。固定 scratch
        // 无分配/锁；请求发布中则用旧 active 安全推进。
        const auradsp_geometry* advance = haveRequested ? &requested : &active;
        float scratchIn[256 * 8];
        float scratchOut[256 * 8];
        UINT32 left = frames;
        while (left > 0) {
            const UINT32 chunk = left > 256 ? 256 : left;
            ZeroMemory(scratchIn, sizeof(scratchIn));
            (void)fnProcessGeometry_(engine_, scratchIn, scratchOut, (int)chunk,
                                     advance);
            left -= chunk;
        }
        ZeroMemory(dst, (size_t)frames * streamCh_ * sizeof(float));
        return;
    }
    liveEngCh_.store((UINT32)active.channels, std::memory_order_relaxed);
    liveTrunc_.store(active.mode == 1, std::memory_order_relaxed);
    const UINT32 eng = (UINT32)active.channels;
    const bool trunc = active.mode == 1;
    const UINT32 strm = streamCh_;
    UINT32 done = 0;
    while (done < frames) {
        UINT32 n = frames - done;
        if (n > (UINT32)kMaxBlock) n = (UINT32)kMaxBlock;
        const float* s = src + (size_t)done * strm;
        float* d = dst + (size_t)done * strm;
        if (eng == strm) {
            (void)fnProcessGeometry_(engine_, s, d, (int)n, &active);
        } else if (strm == 1) {
            // mono 流：复制成立体声喂引擎（eng 恒 2），回写取 L。
            for (UINT32 i = 0; i < n; i++) {
                inBuf_[i * 2] = s[i];
                inBuf_[i * 2 + 1] = s[i];
            }
            (void)fnProcessGeometry_(engine_, inBuf_, outBuf_, (int)n, &active);
            for (UINT32 i = 0; i < n; i++) d[i] = outBuf_[i * 2];
        } else {
            // eng < strm（设置封顶或奇数流宽决议）：gather 到
            // 引擎宽 → 处理 → scatter 回引擎声道对应的流位置，
            // 其余位置清零（第四十六轮 S2：多出的声道丢弃/无
            // 声，旧 stereo adapt 的原样直通已废；第四十七轮
            // S2：位置经 chmap_stream_pos 映射，eng=4 不再顺序
            // 对位）。离散 = 位置截断；矩阵 = 折叠 gather（折
            // 叠表按引擎声道序产出，scatter 同走位置映射）。
            if (trunc) {
                chmap_gather_discrete(s, (int)strm, inBuf_, (int)eng, (int)n);
            } else {
                FoldGather(s, inBuf_, strm, eng, n);
            }
            (void)fnProcessGeometry_(engine_, inBuf_, outBuf_, (int)n, &active);
            chmap_scatter_discrete(outBuf_, (int)eng, d, (int)strm, (int)n);
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
        // 插件块应用（Part I Q2）：与参数同周期；通道不可用自跳过。
        ApplyPlugins();
        // active 可能由 RT 过渡块推进；即使参数块尚无效也要刷新生效遥测。
        ReadbackEffective();
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
                memcpy(tele_->eqInSpectrum, f.eq_in_spectrum,
                       sizeof(tele_->eqInSpectrum));
                memcpy(tele_->stageLevelsL, f.stage_levels_l,
                       sizeof(tele_->stageLevelsL));
                memcpy(tele_->stageLevelsR, f.stage_levels_r,
                       sizeof(tele_->stageLevelsR));
                // v5（多声道计划 W3）：逐声道电平同帧带出——帧自带
                // channel_count/channel_levels/stage_ch_levels，口径
                // 见 auradsp_engine.h；App 据此展开主页与输入门控的
                // 多声道电平（v4 及以前只有 L/R，App 按立体声上报）。
                tele_->channelCount = f.channel_count;
                memcpy(tele_->channelLevels, f.channel_levels,
                       sizeof(tele_->channelLevels));
                for (int s = 0; s < 21; ++s) {
                    memcpy(tele_->stageChLevels[s], f.stage_ch_levels[s],
                           sizeof(tele_->stageChLevels[s]));
                }
                tele_->updateSeq++;
            }
        }
    }
}

void ApoEngineHost::ApplySnapshot(const uint8_t* snap, const uint32_t* hdr) {
    const uint32_t* values = (const uint32_t*)(snap + APO_BLOCK_VALUES_OFFSET);
    const uint8_t* mask = snap + APO_BLOCK_MASK_OFFSET;
    // 有效覆写（第四十一轮）：参数块 v3 分端点覆写表（实时）优先，
    // FX 属性集覆写（Initialize 时读到）兜底；两者皆无则跟随参数块。
    bool modeOvr = epModeValid_;
    int32_t modeOvrVal = epMode_;
    bool fillOvr = epFillValid_;
    int32_t fillOvrVal = epFill_;
    if (hdr[1] >= 3 && endpointHash_ != 0) {
        const auto* tab = (const ApoEndpointOverride*)(snap + APO_EP_OVERRIDE_OFFSET);
        for (int i = 0; i < APO_EP_OVERRIDE_COUNT; i++) {
            if (tab[i].idHash == endpointHash_) {
                if (tab[i].flags & 1u) {
                    modeOvr = true;
                    modeOvrVal = tab[i].mode;
                }
                if (tab[i].flags & 2u) {
                    fillOvr = true;
                    fillOvrVal = tab[i].fill;
                }
                break;
            }
        }
    }
    // 覆写撤除沿：上轮有覆写、本轮全无 → 引擎须回落参数块值；
    // 而块值 diff 基线在覆写期间只记账未下发，须强制全量重应用
    // 一轮（snapshotValid_ 清零），否则引擎停在旧覆写值。
    if (ovrWasActive_ && !modeOvr && !fillOvr) snapshotValid_ = false;
    ovrWasActive_ = modeOvr || fillOvr;
    auto bitSet = [&](uint32_t bit) { return (mask[bit / 8] >> (bit % 8)) & 1u; };
    bypass_.store(hdr[3] != 0);
    uint32_t applied = 0;
    for (uint32_t i = 0; i < APO_NUM_PARAM_COUNT; i++) {
        // 有效位未置：App 从未写过此参数——保持引擎默认值，
        // 严禁用块内零值覆盖（位图语义见 ApoShared.h）。
        if (!bitSet(i)) continue;
        if (snapshotValid_ && appliedNum_[i] == values[i]) continue;
        const char* id = kApoNumParamIds[i];
        // channels.count（第四十六轮 S2）：不再跳过——记账后
        // 由循环后 ApplyEngChResolution 与流宽合成生效宽并
        // 统一对引擎下发（引擎侧的 count 只经决议路径变更）。
        if (strcmp(id, "channels.count") == 0) {
            userCh_ = values[i];
            appliedNum_[i] = values[i];
            continue;
        }
        // mode 与 count 只能在循环后的同代几何请求中下发，避免跨代拼接。
        if (strcmp(id, "channels.mode") == 0) {
            if (!modeOvr) lastBlockMode_ = (int32_t)values[i];
            appliedNum_[i] = values[i];
            continue;
        }
        if (fillOvr && strcmp(id, "channels.upmix_fill") == 0) {
            appliedNum_[i] = values[i];
            continue;
        }
        uint32_t v = values[i];
        if (fnSetParam_(engine_, id, &v, sizeof(v)) == 0) applied++;
        appliedNum_[i] = values[i];
    }
    // 覆写对齐：块从未写过 mode/fill（有效位未置、上面的循环没
    // 覆盖到）时，覆写仍须生效——与已下发哨兵比对后补下发；覆写
    // 值变化（实时表改值）时哨兵失配、自动重新下发。
    // mode 覆写由 ApplyEngChResolution 与 count 同代下发。
    if (fillOvr && appliedEpFill_ != fillOvrVal) {
        int32_t f = fillOvrVal;
        if (fnSetParam_(engine_, "channels.upmix_fill", &f, sizeof(f)) == 0) {
            appliedEpFill_ = fillOvrVal;
            applied++;
        }
    }
    // 生效宽决议（第四十六轮 S2）：有效 mode 定 gather 风格，
    // 块 count 与流宽定引擎宽；每轮快照后统一收敛（无变化
    // 时仅原子发布，零引擎调用）。
    effMode_ = modeOvr ? modeOvrVal : lastBlockMode_;
    const uint32_t geometryApplied = ApplyEngChResolution();
    if (geometryApplied & 1u) applied++;
    if (geometryApplied & 2u) {
        applied++;
        if (modeOvr) appliedEpMode_ = modeOvrVal;
    }
    for (uint32_t s = 0; s < APO_STR_SLOT_COUNT; s++) {
        if (!bitSet(APO_NUM_PARAM_COUNT + s)) continue;  // 同上，有效位门
        uint32_t used = hdr[5 + s];
        const char* base = (const char*)(snap + kApoStrSlotOffsets[s]);
        if (used > kApoStrSlotCaps[s]) used = kApoStrSlotCaps[s];
        std::string cur;
        if (used > 0) cur.assign(base, strnlen(base, used));
        if (!snapshotValid_ || appliedStr_[s] != cur) {
            // 中转围栏（P4）：文件型路径非空且不在中转根下 → 拒写
            // 引擎（记已处理避免逐快照重试；不计 applied）。
            const char* sid = kApoStrSlotIds[s];
            if ((strcmp(sid, "convolver.ir.path") == 0 ||
                 strcmp(sid, "ddc.load") == 0) &&
                !cur.empty() && !IsUnderTransitRoot(cur)) {
                appliedStr_[s] = cur;
                continue;
            }
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

// 引擎生效值回读（第三十五轮，telemetry v6）：应用计数变化时
// （另每 ~1s 兜底）经 auradsp_get_param 回读座位引擎的声道模式
// 与铺满开关，写入 telemetry 尾段。App 面板据此展示引擎真实
// 生效值，与「设置里选了什么」分开——两者不一致时以回读为准。
// fnGetParam_ 为可选符号（旧引擎 DLL 无此导出时整段不写，
// effValid 恒 0，读者据此显示「未知」而非误报 0 值）。
void ApoEngineHost::ReadbackEffective() {
    if (!tele_ || !engine_) return;
    // 宿主步进仍只由完整 active==request 的 RT 块发布；引擎生效值
    // 则读取完整 active 快照，避免通用 getter 的 pending 值冒充生效值。
    tele_->engChHost = liveEngCh_.load(std::memory_order_relaxed);
    tele_->userChSeen = userCh_;
    auradsp_geometry active{0, 0, 0};
    const bool okActive =
        fnGetActiveGeometry_(engine_, &active) == AURADSP_OK;
    if (!okActive) {
        tele_->engChEngine = 0;
        tele_->effValid = 0;
        return;
    }
    tele_->engChEngine = (uint32_t)active.channels;
    tele_->effChannelsMode = (uint32_t)active.mode;
    if (!fnGetParam_) return;
    if (appliedTotal_ == effReadbackApplied_ && ++effReadbackTick_ < 20)
        return;
    effReadbackTick_ = 0;
    effReadbackApplied_ = appliedTotal_;
    int32_t fill = 0;
    const bool okFill = fnGetParam_(engine_, "channels.upmix_fill", &fill,
                                    sizeof(fill)) == 0;
    if (okFill) {
        tele_->effUpmixFill = (uint32_t)fill;
        tele_->effValid = 1;
    } else {
        tele_->effValid = 0;
    }
}

// ---------------------------------------------------------------------------
// Part I Q2：插件块应用（worker 线程）
// ---------------------------------------------------------------------------
namespace {

// 槽状态 JSON 的宽容提取（telemetry 是状态面：解析失败按缺省，
// 不让格式漂移波及 worker）。键以 "key": 形态精确定位。
const char* JsonFind(const char* json, const char* key) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char* p = strstr(json, pat);
    return p ? p + strlen(pat) : nullptr;
}
bool JsonBool(const char* json, const char* key) {
    const char* p = JsonFind(json, key);
    return p && strncmp(p, "true", 4) == 0;
}
double JsonNum(const char* json, const char* key) {
    const char* p = JsonFind(json, key);
    return p ? strtod(p, nullptr) : 0.0;
}
void JsonStr(const char* json, const char* key, char* out, size_t cap) {
    out[0] = '\0';
    const char* p = JsonFind(json, key);
    if (!p || *p != '"') return;
    p++;
    size_t n = 0;
    while (*p && *p != '"' && n + 1 < cap) out[n++] = *p++;
    out[n] = '\0';
}
uint8_t FaultCategoryCode(const char* name) {
    // 与引擎 PluginFaultCategory 数值一一对应（plugin_host.h）。
    if (strcmp(name, "not_found") == 0) return 1;
    if (strcmp(name, "unreadable") == 0) return 2;
    if (strcmp(name, "load_failed") == 0) return 3;
    if (strcmp(name, "entry_missing") == 0) return 4;
    if (strcmp(name, "arch_mismatch") == 0) return 5;
    if (strcmp(name, "init_crash") == 0) return 6;
    if (strcmp(name, "process_crash") == 0) return 7;
    return 0;
}

}  // namespace

bool ApoEngineHost::ApplyPluginState(int slot, const uint8_t* state,
                                     uint32_t bytes) {
    if (pluginTempDir_.empty() || !fnSlotLoadPreset_) return false;
    wchar_t path[MAX_PATH];
    swprintf(path, MAX_PATH, L"%sauradsp_apo_state_%d.bin",
             pluginTempDir_.c_str(), slot);
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    bool ok = WriteFile(h, state, bytes, &written, nullptr) &&
              written == bytes;
    CloseHandle(h);
    if (!ok) return false;
    char u8[MAX_PATH * 3];
    if (WideCharToMultiByte(CP_UTF8, 0, path, -1, u8, sizeof(u8), nullptr,
                            nullptr) <= 0)
        return false;
    return fnSlotLoadPreset_(engine_, slot, u8) == 1;
}

void ApoEngineHost::ApplyPlugins() {
    if (!pluginView_ || !pluginsOk_ || !engine_) return;
    const auto* hdr = (const ApoPluginBlockHeader*)pluginView_;
    uint32_t s1 = hdr->writeSeq;
    if ((s1 & 1u) != 0 || hdr->magic != APO_PLUGINS_MAGIC ||
        hdr->version != APO_PLUGINS_VERSION)
        return;
    ApoPluginBlockHeader h{};
    ApoPluginSlotHeader sh[APO_PLUGIN_SLOTS];
    memcpy(&h, pluginView_, sizeof(h));
    for (uint32_t i = 0; i < APO_PLUGIN_SLOTS; i++) {
        memcpy(&sh[i],
               pluginView_ + APO_PLUGIN_BLOCK_HEADER_BYTES +
                   i * APO_PLUGIN_SLOT_STRIDE,
               sizeof(ApoPluginSlotHeader));
    }
    if (hdr->writeSeq != s1) return;  // 撕裂帧：下轮重试

    // 全面复审 S4（APO-10）：载荷（path/id/state）此前在头快照后
    // 仍直读活映射——发布者并发写可让载荷与已消费的代次撕裂
    // （按新 loadGen 加载到一半被改写的 state）。整槽区先快照并
    // 复核 writeSeq 未变（变了整轮放弃、下轮重试），此后本轮的
    // 全部载荷读都走快照，与参数路径的整块快照口径一致。
    if (!pluginSnap_) {
        pluginSnap_ = (uint8_t*)malloc((size_t)APO_PLUGIN_SLOTS *
                                       APO_PLUGIN_SLOT_STRIDE);
        if (!pluginSnap_) return;
    }
    memcpy(pluginSnap_, pluginView_ + APO_PLUGIN_BLOCK_HEADER_BYTES,
           (size_t)APO_PLUGIN_SLOTS * APO_PLUGIN_SLOT_STRIDE);
    if (hdr->writeSeq != s1) return;  // 拷贝期间被写：下轮重试

    if (!pluginHdrSeen_ || h.chainEnabled != appliedChainEnabled_) {
        fnChainEnabled_(engine_, (int)h.chainEnabled);
        appliedChainEnabled_ = h.chainEnabled;
    }
    if (!pluginHdrSeen_ || h.pdcEnabled != appliedPdc_) {
        fnSetPdc_(engine_, (int)h.pdcEnabled);
        appliedPdc_ = h.pdcEnabled;
    }
    pluginHdrSeen_ = true;

    char statusBuf[8192];
    for (uint32_t slot = 0; slot < APO_PLUGIN_SLOTS; slot++) {
        AppliedPlugin& ap = appliedPlugins_[slot];
        const ApoPluginSlotHeader& want = sh[slot];
        const uint8_t* base = pluginSnap_ + slot * APO_PLUGIN_SLOT_STRIDE;
        if (!ap.seen || want.loadGen != ap.loadGen) {
            // 身份代次变化（含首见）：按块内身份重载该槽。
            if (want.format == 0 || want.pathBytes == 0) {
                if (ap.loaded) fnSlotUnload_(engine_, (int)slot);
                ap.loaded = false;
                ap.loadGen = want.loadGen;
                ap.stateGen = want.stateGen;
            } else {
#ifndef AURADSP_APO_PLUGIN_TRUSTED_TEST_ONLY
                // C2 fail-closed boundary: production never loads a DLL from
                // this user-influenced channel. Keep this before every path
                // check and fnSlotLoad_ call; restoring the capability needs
                // an authenticated proxy/out-of-process design.
                ap.loaded = false;
                ap.loadGen = want.loadGen;
                ap.stateGen = want.stateGen;
#else
                char path[APO_PLUGIN_PATH_BYTES + 1];
                uint32_t pn = (uint32_t)strnlen(
                    (const char*)(base + APO_PLUGIN_SLOT_HEADER_BYTES),
                    want.pathBytes < APO_PLUGIN_PATH_BYTES
                        ? want.pathBytes
                        : APO_PLUGIN_PATH_BYTES);
                memcpy(path, base + APO_PLUGIN_SLOT_HEADER_BYTES, pn);
                path[pn] = '\0';
                char id[APO_PLUGIN_ID_BYTES + 1];
                uint32_t in = (uint32_t)strnlen(
                    (const char*)(base + APO_PLUGIN_SLOT_HEADER_BYTES +
                                  APO_PLUGIN_PATH_BYTES),
                    APO_PLUGIN_ID_BYTES);
                memcpy(id, base + APO_PLUGIN_SLOT_HEADER_BYTES +
                               APO_PLUGIN_PATH_BYTES,
                       in);
                id[in] = '\0';
                // 中转围栏（2026-11-22 审查 N1 裁定，与文件效果
                // 同口径）：插件二进制路径必须在中转根下才准加载
                // ——发布侧（App）先经 ApoTransit 把插件复制进
                // %ProgramData%\AuraDSP\apo-assets 再下发路径；
                // 块里出现根外路径一律拒绝（视为本代次加载失败，
                // telemetry 如实回传），防任意写块者令 LocalService
                // 加载任意 DLL。
                int rc = IsUnderTransitRoot(path)
                    ? fnSlotLoad_(engine_, (int)slot, path, id)
                    : -1;
                ap.loadGen = want.loadGen;
                if (rc == 1) {
                    ap.loaded = true;
                    fnSlotStage_(engine_, (int)slot, (int)want.insertStage);
                    fnSlotChannels_(engine_, (int)slot, (int)want.channelMask);
                    fnSlotBypass_(engine_, (int)slot, (int)want.bypass);
                    ap.stage = want.insertStage;
                    ap.mask = want.channelMask;
                    ap.bypass = want.bypass;
                    if (want.stateBytes > 0 &&
                        want.stateBytes <= APO_PLUGIN_STATE_BYTES &&
                        ApplyPluginState(
                            (int)slot,
                            base + APO_PLUGIN_SLOT_HEADER_BYTES +
                                APO_PLUGIN_PATH_BYTES + APO_PLUGIN_ID_BYTES,
                            want.stateBytes)) {
                        ap.stateGen = want.stateGen;
                    } else if (want.stateBytes == 0) {
                        ap.stateGen = want.stateGen;
                    }
                    // 状态应用失败时 stateGen 不前进：下轮重试
                    // （身份已就位，重试只是再 loadPreset 一次）。
                } else {
                    // 加载失败：引擎已闩锁故障（Q1），telemetry 会
                    // 如实回传；本代次不再重试（发布侧重试点击会
                    // 再 bump loadGen）。stateGen 不前进，待加载
                    // 成功后补应用。
                    ap.loaded = false;
                }
#endif
            }
            ap.seen = true;
        } else if (ap.loaded) {
            // 身份未变：旁路/级/掩码的独立 diff + 状态代次应用。
            if (want.bypass != ap.bypass) {
                fnSlotBypass_(engine_, (int)slot, (int)want.bypass);
                ap.bypass = want.bypass;
            }
            if (want.insertStage != ap.stage) {
                fnSlotStage_(engine_, (int)slot, (int)want.insertStage);
                ap.stage = want.insertStage;
            }
            if (want.channelMask != ap.mask) {
                fnSlotChannels_(engine_, (int)slot, (int)want.channelMask);
                ap.mask = want.channelMask;
            }
            if (want.stateGen != ap.stateGen && want.stateBytes > 0 &&
                want.stateBytes <= APO_PLUGIN_STATE_BYTES &&
                ApplyPluginState(
                    (int)slot,
                    base + APO_PLUGIN_SLOT_HEADER_BYTES +
                        APO_PLUGIN_PATH_BYTES + APO_PLUGIN_ID_BYTES,
                    want.stateBytes)) {
                ap.stateGen = want.stateGen;
            } else if (want.stateGen != ap.stateGen &&
                       want.stateBytes == 0) {
                ap.stateGen = want.stateGen;
            }
        }

        // telemetry v3 插件段：以引擎槽状态 JSON 为真相回填。
        if (tele_ && fnSlotStatus_) {
            statusBuf[0] = '\0';
            // 注意：slot_get_status 返回 JSON 长度（>0 为成功），
            // 不是其余 slot ABI 的 1/0 口径。
            if (fnSlotStatus_(engine_, (int)slot, statusBuf,
                              sizeof(statusBuf)) > 0) {
                auto& t = tele_->plugins[slot];
                char cat[32];
                JsonStr(statusBuf, "faultCategory", cat, sizeof(cat));
                t.loaded = JsonBool(statusBuf, "hasActive") ? 1 : 0;
                t.bypass = JsonBool(statusBuf, "bypassed") ? 1 : 0;
                t.fault = JsonBool(statusBuf, "fault") ? 1 : 0;
                t.faultCategory = FaultCategoryCode(cat);
                t.latencySamples =
                    (uint32_t)JsonNum(statusBuf, "latency");
                t.inRms = (float)JsonNum(statusBuf, "inRms");
                t.outRms = (float)JsonNum(statusBuf, "outRms");
                t.processCalls =
                    (uint32_t)JsonNum(statusBuf, "processCalls");
                t.appliedLoadGen = ap.loadGen;
                t.appliedStateGen = ap.stateGen;
            }
        }
    }
}
