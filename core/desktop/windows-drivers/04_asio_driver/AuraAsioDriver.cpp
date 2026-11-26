// AuraAsioDriver.cpp — AuraDSP 虚拟 ASIO 驱动实现
#include "AuraAsioDriver.h"
#include "AuraAsioDriverGuid.h"
#include "chain/channel_map.h"  // 声道适配统一表（第五十五轮）

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <new>
#include <sddl.h>

std::atomic<long> AuraAsioDriver::s_instanceCount{0};

namespace {

// 从 "id=value;..." 参数串里取整数参数；缺失/非法返回 def。
// 与引擎 ApplyParamsString 同一分隔口径（';' 分条、'=' 分值）。
int ParseParamInt(const std::string& s, const char* id, int def) {
    if (s.empty() || !id || !*id) return def;
    const size_t idLen = std::strlen(id);
    size_t pos = 0;
    while (pos < s.size()) {
        const size_t semi = s.find(';', pos);
        const size_t end = (semi == std::string::npos) ? s.size() : semi;
        if (end > pos + idLen && s.compare(pos, idLen, id) == 0 &&
            s[pos + idLen] == '=') {
            return std::atoi(s.c_str() + pos + idLen + 1);
        }
        if (semi == std::string::npos) break;
        pos = semi + 1;
    }
    return def;
}

// 引擎宽度合法区间：1..8（与 AuraAsioDriver::kMaxChannels 同值；
// 匿名命名空间在类外，取字面量并在此注明来源）。
int ClampEngineChannels(int ch) {
    if (ch < 1) return 1;
    if (ch > 8) return 8;
    return ch;
}

}  // namespace

AuraAsioDriver::AuraAsioDriver() {
    s_instanceCount.fetch_add(1, std::memory_order_relaxed);
    m_errorMessage[0] = '\0';
}

AuraAsioDriver::~AuraAsioDriver() {
    stop();
    disposeBuffers();
    m_engineLoader.Unload();
    s_instanceCount.fetch_sub(1, std::memory_order_relaxed);
}

// ---------------- IUnknown ----------------

HRESULT STDMETHODCALLTYPE AuraAsioDriver::QueryInterface(REFIID riid, void** ppvObject) {
    if (!ppvObject) return E_POINTER;
    // Steinberg ASIO SDK asiolist.cpp line 230:
    // CoCreateInstance(lpdrv->clsid, 0, CLSCTX_INPROC_SERVER, lpdrv->clsid, asiodrv);
    // 宿主请求 riid == CLSID_AuraAsioDriver 或 riid == IID_IUnknown
    if (riid == IID_IUnknown || riid == CLSID_AuraAsioDriver) {
        *ppvObject = static_cast<IASIO*>(this);
        AddRef();
        return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE AuraAsioDriver::AddRef() {
    return (ULONG)m_refCount.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG STDMETHODCALLTYPE AuraAsioDriver::Release() {
    long prev = m_refCount.fetch_sub(1, std::memory_order_release);
    if (prev == 1) {
        std::atomic_thread_fence(std::memory_order_acquire);
        delete this;
        return 0;
    }
    return (ULONG)(prev - 1);
}

// ---------------- IASIO 接口实现 ----------------

ASIOBool AuraAsioDriver::init(void* /*sysHandle*/) {
    m_active = true;
    m_errorMessage[0] = '\0';
    // App 先写注册表再发布 token；init 先捕 token 再读档位，避免
    // 「旧宽度 + 新 token」的跨面竞争被误认为请求已生效。
    CaptureChannelRequestSeq();
    LoadConfiguredChannels();
    m_engineLoader.Load();
    return ASIOTrue;
}

// B2c：从注册表读取通道档位。优先 HKCU\SOFTWARE\AuraDSP\AsioDriver\Channels，
// 其次 HKCR\CLSID\{...}\Channels；缺省或非法值回落 2（保持历史立体声行为）。
void AuraAsioDriver::LoadConfiguredChannels() {
    DWORD val = 0;
    DWORD sz = sizeof(val);
    const std::wstring clsidKey =
        std::wstring(L"CLSID\\") + kAuraAsioClsidString;
    if (RegGetValueW(HKEY_CURRENT_USER, ASIO_DRIVER_REG_KEY,
                     ASIO_DRIVER_REG_CHANNELS, RRF_RT_REG_DWORD, nullptr, &val, &sz) == ERROR_SUCCESS ||
        RegGetValueW(HKEY_CLASSES_ROOT, clsidKey.c_str(),
                     ASIO_DRIVER_REG_CHANNELS, RRF_RT_REG_DWORD, nullptr, &val, &sz) == ERROR_SUCCESS) {
        if (IsValidChannelCount((long)val)) {
            m_channels = (long)val;
            return;
        }
    }
    m_channels = 2;
}

// 请求代号与注册表 Channels 必须在同一 init 时点快照：DAW 只有重新
// 创建实例才会重新读取档位。若在 start()/pump 重捕，同实例 stop/start
// 会把后来发布的新 token 误当成自身身份，App 因而误确认档位请求。
void AuraAsioDriver::CaptureChannelRequestSeq() {
    m_channelRequestSeq = 0;
    OpenParams();
    if (!m_params) return;  // App 未运行：token 0，v4 遥测仍可安全返回
    const long s1 = m_params->writeSeq;
    if ((s1 & 1) == 0) {
        const uint32_t requestSeq = m_params->reserved1[1];
        if (m_params->writeSeq != s1) {
            CloseParams();
            return;  // 写入窗口交叉：本次实例保持 token 0，不猜读半写值
        }
        m_channelRequestSeq = requestSeq;
    }
    CloseParams();
}

void AuraAsioDriver::getDriverName(char* name) {
    if (name) {
        strncpy_s(name, 32, kAuraAsioDriverName, _TRUNCATE);
    }
}

long AuraAsioDriver::getDriverVersion() {
    return 1;
}

void AuraAsioDriver::getErrorMessage(char* string) {
    if (string) {
        strncpy_s(string, 124, m_errorMessage, _TRUNCATE);
    }
}

ASIOError AuraAsioDriver::getChannels(long* numInputChannels, long* numOutputChannels) {
    if (!numInputChannels || !numOutputChannels) return ASE_InvalidParameter;
    *numInputChannels = m_channels;   // B2c：2/4/6/8 档（默认 2）
    *numOutputChannels = m_channels;
    return ASE_OK;
}

ASIOError AuraAsioDriver::getLatencies(long* inputLatency, long* outputLatency) {
    if (inputLatency) *inputLatency = m_bufferSize;
    if (outputLatency) *outputLatency = m_bufferSize * 2;
    return ASE_OK;
}

ASIOError AuraAsioDriver::getBufferSize(long* minSize, long* maxSize,
                                        long* preferredSize, long* granularity) {
    if (!minSize || !maxSize || !preferredSize || !granularity) return ASE_InvalidParameter;
    *minSize = 64;
    *maxSize = 2048;
    *preferredSize = 256;
    *granularity = -1;  // 2 的幂次阶跃
    return ASE_OK;
}

ASIOError AuraAsioDriver::canSampleRate(ASIOSampleRate sampleRate) {
    if (sampleRate == 44100.0 || sampleRate == 48000.0 ||
        sampleRate == 88200.0 || sampleRate == 96000.0 ||
        sampleRate == 176400.0 || sampleRate == 192000.0) {
        return ASE_OK;
    }
    return ASE_NoClock;
}

ASIOError AuraAsioDriver::getSampleRate(ASIOSampleRate* sampleRate) {
    if (!sampleRate) return ASE_InvalidParameter;
    *sampleRate = m_sampleRate;
    return ASE_OK;
}

void AuraAsioDriver::FinishEngineSetup() {
    if (!m_engine) return;
    if (!m_pendingParamString.empty()) {
        m_engineLoader.ApplyParamsString(m_engine, m_pendingParamString.c_str());
    }
    // W6：不再把 channels.count 钉成流宽——App 的 4.0/2.0 档位要让
    // 引擎按窄宽度处理，宽度不一致由泵内 chmap 适配层承担（gather/
    // fold/scatter）。参数串未下发时按流宽起步，避免引擎默认 2 声道
    // 误读 8 宽流；参数串已下发则以 App 值为准（幂等重放一次）。
    const int fromParams =
        ParseParamInt(m_pendingParamString, "channels.count", 0);
    m_engineCh = (fromParams > 0) ? ClampEngineChannels(fromParams)
                                  : ClampEngineChannels((int)m_channels);
    m_channelMode = ParseParamInt(m_pendingParamString, "channels.mode", 0);
    int nCh = m_engineCh;
    m_engineLoader.SetParam(m_engine, "channels.count", &nCh, (uint32_t)sizeof(nCh));
}

ASIOError AuraAsioDriver::setSampleRate(ASIOSampleRate sampleRate) {
    if (canSampleRate(sampleRate) != ASE_OK) return ASE_NoClock;
    if (m_started) return ASE_InvalidMode;
    m_sampleRate = sampleRate;
    if (m_engine) {
        m_engineLoader.DestroyEngine(m_engine);
        m_engine = m_engineLoader.CreateEngine((float)m_sampleRate, (int)m_bufferSize);
        FinishEngineSetup();
    }
    if (m_callbacks && m_callbacks->sampleRateDidChange) {
        m_callbacks->sampleRateDidChange(m_sampleRate);
    }
    return ASE_OK;
}

ASIOError AuraAsioDriver::getClockSources(ASIOClockSource* clocks, long* numSources) {
    if (!clocks || !numSources || *numSources < 1) return ASE_InvalidParameter;
    clocks[0].index = 0;
    clocks[0].associatedChannel = -1;
    clocks[0].associatedGroup = -1;
    clocks[0].isCurrentSource = ASIOTrue;
    strncpy_s(clocks[0].name, sizeof(clocks[0].name), "Internal", _TRUNCATE);
    *numSources = 1;
    return ASE_OK;
}

ASIOError AuraAsioDriver::setClockSource(long reference) {
    if (reference == 0) return ASE_OK;
    return ASE_NotPresent;
}

ASIOError AuraAsioDriver::getSamplePosition(ASIOSamples* sPos, ASIOTimeStamp* tStamp) {
    if (!sPos || !tStamp) return ASE_InvalidParameter;

    LARGE_INTEGER qpcFreq, qpcNow;
    QueryPerformanceFrequency(&qpcFreq);
    QueryPerformanceCounter(&qpcNow);

    uint64_t ns = 0;
    if (qpcFreq.QuadPart > 0) {
        ns = (uint64_t)((qpcNow.QuadPart * 1000000000ULL) / qpcFreq.QuadPart);
    }

    tStamp->lo = (unsigned long)(ns & 0xFFFFFFFF);
    tStamp->hi = (unsigned long)((ns >> 32) & 0xFFFFFFFF);

    sPos->lo = (unsigned long)(m_samplePosition & 0xFFFFFFFF);
    sPos->hi = (unsigned long)((m_samplePosition >> 32) & 0xFFFFFFFF);
    return ASE_OK;
}

ASIOError AuraAsioDriver::getChannelInfo(ASIOChannelInfo* info) {
    if (!info) return ASE_InvalidParameter;
    if (info->channel < 0 || info->channel >= m_channels) return ASE_InvalidParameter;

    info->type = ASIOSTFloat32LSB;
    info->channelGroup = 0;

    // B2c：1/2 声道保留人可读 L/R 名；>=3 声道使用通用 "In/Out N" 以便 DAW 路由。
    const long ch = info->channel;
    char name[32];
    if (ch == 0) {
        strncpy_s(name, sizeof(name), info->isInput ? "In 1 (L)" : "Out 1 (L)", _TRUNCATE);
    } else if (ch == 1) {
        strncpy_s(name, sizeof(name), info->isInput ? "In 2 (R)" : "Out 2 (R)", _TRUNCATE);
    } else {
        sprintf_s(name, sizeof(name), info->isInput ? "In %ld" : "Out %ld", ch + 1);
    }
    strncpy_s(info->name, sizeof(info->name), name, _TRUNCATE);

    info->isActive = (info->isInput ? m_inputActive[ch] : m_outputActive[ch])
                         ? ASIOTrue : ASIOFalse;
    return ASE_OK;
}

ASIOError AuraAsioDriver::createBuffers(ASIOBufferInfo* bufferInfos, long numChannels,
                                        long bufferSize, ASIOCallbacks* callbacks) {
    if (!bufferInfos || numChannels <= 0 || !callbacks) return ASE_InvalidParameter;
    if (bufferSize < 64 || bufferSize > 2048) return ASE_InvalidMode;

    disposeBuffers();

    m_bufferSize = bufferSize;
    m_callbacks = callbacks;

    const long ch = m_channels;

    // 分配 Phase 3 实时中间与交织缓冲（B2c：按 m_channels 档位交织）
    const size_t interBytes = (size_t)bufferSize * (size_t)ch * sizeof(float);
    const size_t pairBytes = (size_t)bufferSize * sizeof(float);
    m_interleavedIn = static_cast<float*>(_aligned_malloc(interBytes, 64));
    m_interleavedOut = static_cast<float*>(_aligned_malloc(interBytes, 64));
    m_proc = static_cast<float*>(_aligned_malloc(interBytes, 64));
    m_foldL = static_cast<float*>(_aligned_malloc(pairBytes, 64));
    m_foldR = static_cast<float*>(_aligned_malloc(pairBytes, 64));
    const size_t multiBytes =
        (size_t)bufferSize * (size_t)kMaxChannels * sizeof(float);
    m_multiOut = static_cast<float*>(_aligned_malloc(multiBytes, 64));
    // W6：宽度适配缓冲按上限一次分配，运行期切声道不再分配。
    m_engIn = static_cast<float*>(_aligned_malloc(multiBytes, 64));
    m_engOut = static_cast<float*>(_aligned_malloc(multiBytes, 64));
    if (!m_interleavedIn || !m_interleavedOut || !m_proc || !m_foldL ||
        !m_foldR || !m_multiOut || !m_engIn || !m_engOut) {
        disposeBuffers();
        return ASE_NoMemory;
    }
    memset(m_interleavedIn, 0, interBytes);
    memset(m_interleavedOut, 0, interBytes);
    memset(m_proc, 0, interBytes);
    memset(m_foldL, 0, pairBytes);
    memset(m_foldR, 0, pairBytes);
    memset(m_multiOut, 0, multiBytes);
    memset(m_engIn, 0, multiBytes);
    memset(m_engOut, 0, multiBytes);

    // 引擎句柄实例化（按协商后的采样率与缓冲大小创建）
    if (!m_engineLoader.IsLoaded()) {
        m_engineLoader.Load();
    }
    if (m_engineLoader.IsLoaded()) {
        m_engine = m_engineLoader.CreateEngine((float)m_sampleRate, (int)m_bufferSize);
        FinishEngineSetup();
    }

    for (long i = 0; i < numChannels; ++i) {
        ASIOBufferInfo& info = bufferInfos[i];
        if (info.channelNum < 0 || info.channelNum >= ch) {
            disposeBuffers();
            return ASE_InvalidParameter;
        }

        const size_t allocBytes = (size_t)bufferSize * 2 * sizeof(float);
        float* pBuf = static_cast<float*>(_aligned_malloc(allocBytes, 64));
        if (!pBuf) {
            disposeBuffers();
            return ASE_NoMemory;
        }
        memset(pBuf, 0, allocBytes);

        if (info.isInput) {
            m_inputActive[info.channelNum] = true;
            m_inBuffers[info.channelNum][0] = pBuf;
            m_inBuffers[info.channelNum][1] = pBuf + bufferSize;
            info.buffers[0] = m_inBuffers[info.channelNum][0];
            info.buffers[1] = m_inBuffers[info.channelNum][1];
        } else {
            m_outputActive[info.channelNum] = true;
            m_outBuffers[info.channelNum][0] = pBuf;
            m_outBuffers[info.channelNum][1] = pBuf + bufferSize;
            info.buffers[0] = m_outBuffers[info.channelNum][0];
            info.buffers[1] = m_outBuffers[info.channelNum][1];
        }
    }

    if (m_callbacks->asioMessage) {
        m_timeInfoMode = (m_callbacks->asioMessage(kAsioSupportsTimeInfo, 0, nullptr, nullptr) == 1);
    } else {
        m_timeInfoMode = false;
    }

    m_buffersAllocated = true;
    return ASE_OK;
}

ASIOError AuraAsioDriver::disposeBuffers() {
    stop();
    m_wasapiSink.Close();

    if (m_engine) {
        m_engineLoader.DestroyEngine(m_engine);
        m_engine = nullptr;
    }

    if (m_interleavedIn) {
        _aligned_free(m_interleavedIn);
        m_interleavedIn = nullptr;
    }
    if (m_interleavedOut) {
        _aligned_free(m_interleavedOut);
        m_interleavedOut = nullptr;
    }
    if (m_proc) {
        _aligned_free(m_proc);
        m_proc = nullptr;
    }
    if (m_foldL) {
        _aligned_free(m_foldL);
        m_foldL = nullptr;
    }
    if (m_foldR) {
        _aligned_free(m_foldR);
        m_foldR = nullptr;
    }
    if (m_multiOut) {
        _aligned_free(m_multiOut);
        m_multiOut = nullptr;
    }
    if (m_engIn) {
        _aligned_free(m_engIn);
        m_engIn = nullptr;
    }
    if (m_engOut) {
        _aligned_free(m_engOut);
        m_engOut = nullptr;
    }

    for (int c = 0; c < kMaxChannels; ++c) {
        if (m_inBuffers[c][0]) {
            _aligned_free(m_inBuffers[c][0]);
            m_inBuffers[c][0] = nullptr;
            m_inBuffers[c][1] = nullptr;
        }
        m_inputActive[c] = false;

        if (m_outBuffers[c][0]) {
            _aligned_free(m_outBuffers[c][0]);
            m_outBuffers[c][0] = nullptr;
            m_outBuffers[c][1] = nullptr;
        }
        m_outputActive[c] = false;
    }

    m_buffersAllocated = false;
    m_callbacks = nullptr;
    return ASE_OK;
}

ASIOError AuraAsioDriver::controlPanel() {
    // Phase 1：暂不弹窗，Phase 3 接入 AuraDSP 统一设置面板
    return ASE_OK;
}

ASIOError AuraAsioDriver::future(long selector, void* opt) {
    switch (selector) {
    case kAsioEnableTimeCodeRead:
    case kAsioDisableTimeCodeRead:
    case kAsioCanTimeInfo:
    case kAsioCanTimeCode:
        return ASE_SUCCESS;

    // 2026-11-22 审查 N5 裁定：私有 future() 选择子的控制面
    // （SetBypass/GetBypass/SetParam/GetParam/ApplyParamsString/
    // SetChannels/GetChannels）已删除——控制面由 S3/S4 参数块
    // 单独承担（ADR-014），原 ApplyParamsString 的 += 追加语义
    // 与块路径的替换语义冲突、SetChannels 旁路改宽与注册表档位
    // 真相冲突。下列六个只读诊断查询保留（实机冒烟
    // smoke_asio_driver 的驱动探针在用，无等价替代面）；其余
    // 未知选择子一律 ASE_NotPresent。
    case kAuraAsioFutureGetWasapiRenderedFrames:
        if (opt) {
            *reinterpret_cast<uint64_t*>(opt) = m_wasapiSink.GetTotalFramesRendered();
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;
    case kAuraAsioFutureGetWasapiTargetRate:
        if (opt) {
            *reinterpret_cast<double*>(opt) = m_wasapiSink.GetTargetSampleRate();
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;
    case kAuraAsioFutureIsWasapiOpen:
        if (opt) {
            *reinterpret_cast<long*>(opt) = m_wasapiSink.IsOpen() ? 1 : 0;
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;
    case kAuraAsioFutureIsDspLoaded:
        if (opt) {
            *reinterpret_cast<long*>(opt) = m_engineLoader.IsLoaded() ? 1 : 0;
            return ASE_SUCCESS;
        }
        return m_engineLoader.IsLoaded() ? ASE_SUCCESS : ASE_NotPresent;
    case kAuraAsioFutureGetDspProcessedFrames:
        if (opt) {
            *reinterpret_cast<uint64_t*>(opt) = m_dspProcessedFrames.load(std::memory_order_relaxed);
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;
    case kAuraAsioFutureCopyLastOutputBlock:
        if (opt) {
            auto* p = reinterpret_cast<AuraAsioBlockCopy*>(opt);
            if (p && p->outL && p->outR && p->maxSamples > 0 && m_proc) {
                const long ch = m_channels;
                long toCopy = (m_bufferSize < p->maxSamples) ? m_bufferSize : p->maxSamples;
                // 取处理后块的前两个通道（与历史立体声语义一致，多声道下为 ch0/ch1）
                for (long i = 0; i < toCopy; ++i) {
                    p->outL[i] = m_proc[i * ch + 0];
                    p->outR[i] = (ch > 1) ? m_proc[i * ch + 1] : m_proc[i * ch + 0];
                }
                p->copiedSamples = toCopy;
                return ASE_SUCCESS;
            }
        }
        return ASE_InvalidParameter;

    case kAsioCanInputMonitor:
    default:
        return ASE_NotPresent;
    }
}

ASIOError AuraAsioDriver::outputReady() {
    return ASE_OK;
}

// ---------------------------------------------------------------------------
// S3 最小遥测：Global\AuraDSP_AsioDriverTelemetry 发布（契约见
// AsioDriverShared.h）。SDDL 口径：交互用户全权（DAW 与 App 桥
// 均为同一交互用户进程，无 audiodg/LocalService 参与，不照搬
// APO 的 LS/LPAC 段）。
// ---------------------------------------------------------------------------
void AuraAsioDriver::OpenTelemetry() {
    CloseTelemetry();
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GA;;;IU)(A;;GA;;;OW)", SDDL_REVISION_1, &sd, nullptr)) {
        return;
    }
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = sd;
    sa.bInheritHandle = FALSE;
    HANDLE hMap = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE,
                                     0, ASIO_DRIVER_TELEMETRY_BYTES,
                                     ASIO_DRIVER_TELEMETRY_NAME);
    const bool preExisting = (GetLastError() == ERROR_ALREADY_EXISTS);
    LocalFree(sd);
    if (!hMap) return;
    void* view = MapViewOfFile(hMap, FILE_MAP_WRITE, 0, 0,
                               sizeof(AsioDriverTelemetryBlock));
    if (!view) {
        CloseHandle(hMap);
        return;
    }
    m_hTelemetryMap = hMap;
    m_telemetry = (AsioDriverTelemetryBlock*)view;
    // 仅新建（或内容无效）时初始化；存活块只接管写者身份，避免
    // 双实例互踩计数（APO-2 同口径）。
    if (!preExisting || m_telemetry->magic != ASIO_DRIVER_TELEMETRY_MAGIC) {
        memset(m_telemetry, 0, sizeof(AsioDriverTelemetryBlock));
        m_telemetry->magic = ASIO_DRIVER_TELEMETRY_MAGIC;
    }
    // version 无条件写（r65）：存活块可能由旧版驱动写成旧布局，
    // 若只在新建时写版本号，新驱动会带着旧版本号发布新尾部字段，
    // 读者按旧版回落、逐声道电平/请求代号永不生效。
    m_telemetry->version = ASIO_DRIVER_TELEMETRY_VERSION;
    m_telemetry->writerPid = GetCurrentProcessId();
    // token 是 init 生命周期快照；start 只回显。running 先归零，避免
    // 上一实例异常退出留下的 running=1 在新泵发布几何前误判为活跃。
    m_telemetry->requestSeq = m_channelRequestSeq;
    m_telemetry->running = 0;
}

void AuraAsioDriver::CloseTelemetry() {
    if (m_telemetry) {
        m_telemetry->running = 0;
        UnmapViewOfFile(m_telemetry);
        m_telemetry = nullptr;
    }
    if (m_hTelemetryMap) {
        CloseHandle(m_hTelemetryMap);
        m_hTelemetryMap = nullptr;
    }
}

// ---------------- S4 参数块（App 写、驱动读） ----------------

void AuraAsioDriver::OpenParams() {
    CloseParams();
    m_hParamsMap = OpenFileMappingW(FILE_MAP_READ, FALSE,
                                    ASIO_DRIVER_PARAMS_NAME);
    if (!m_hParamsMap) return;  // App 未运行：保持默认参数口径
    const void* view = MapViewOfFile(m_hParamsMap, FILE_MAP_READ, 0, 0,
                                     ASIO_DRIVER_PARAMS_BYTES);
    if (!view) {
        CloseHandle(m_hParamsMap);
        m_hParamsMap = nullptr;
        return;
    }
    const auto* block =
        static_cast<const AsioDriverParamsBlock*>(view);
    if (block->magic != ASIO_DRIVER_PARAMS_MAGIC ||
        block->version != ASIO_DRIVER_PARAMS_VERSION) {
        UnmapViewOfFile(view);
        CloseHandle(m_hParamsMap);
        m_hParamsMap = nullptr;
        return;
    }
    m_params = block;
    // 新映射：seq 哨兵归 0。App 已写过（偶数 >= 2）则首个 Pull 即应用；
    // 块仍全零（写者未启动）时 seq=0 与哨兵相等，不会应用空载荷。
    m_lastParamSeq = 0;
}

void AuraAsioDriver::CloseParams() {
    if (m_params) {
        UnmapViewOfFile(m_params);
        m_params = nullptr;
    }
    if (m_hParamsMap) {
        CloseHandle(m_hParamsMap);
        m_hParamsMap = nullptr;
    }
}

// v2 奇偶 seqlock（与 APO 参数块同协议）：读前 writeSeq 必须为偶数
// 且与上次应用值不同；拷完载荷/bypass/mute 后再读一次，两次相同才
// 采信——写者处于奇数写入窗口、或拷贝期间又写一轮，必被识破，本轮
// 放弃、下块重试。泵线程调用（非 RT 回调），引擎 set_param 的线程
// 安全口径与 APO worker 应用参数同级。
void AuraAsioDriver::PullParamsFromBlock() {
    if (!m_params) {
        // 块缺席（App 后启）：低频重试打开（约每 600 块一次），
        // 免得 DAW 先于 App 启动时参数线永不接通。
        if (++m_paramsRetry >= 600) {
            m_paramsRetry = 0;
            OpenParams();
        }
        return;
    }
    // 版本全等兜底（OpenParams 已查一次，但块可能被旧 App 重写）：
    // v1 的"写毕才递增"在奇偶协议下会让长期停在奇数的序号永远被
    // 跳过，必须整体拒绝，安全降级为默认参数。
    if (m_params->version != ASIO_DRIVER_PARAMS_VERSION) return;
    const long s1 = m_params->writeSeq;
    if ((s1 & 1) != 0) return;         // 写入中：本轮不碰
    if (s1 == m_lastParamSeq) return;  // 无新版本
    uint32_t bytes = m_params->payloadBytes;
    if (bytes > ASIO_DRIVER_PARAMS_PAYLOAD_CAP) {
        bytes = ASIO_DRIVER_PARAMS_PAYLOAD_CAP;
    }
    const char* payload = reinterpret_cast<const char*>(m_params) +
                          ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET;
    std::string snapshot(payload, payload + bytes);
    const long bypass = m_params->bypass;
    const long mute = m_params->mute;
    if (m_params->writeSeq != s1) return;  // 拷贝期间写者又写一轮，下块重试
    m_lastParamSeq = s1;
    m_pendingParamString = snapshot;
    // W6：参数串是引擎宽度的权威（App 的 4.0/2.0 档位经此到达
    // DAW 进程内引擎）；串里没有时跟流宽，绝不让引擎沿用旧窄宽度
    // 去误读更宽的流。
    m_engineCh = ClampEngineChannels(
        ParseParamInt(snapshot, "channels.count", (int)m_channels));
    m_channelMode = ParseParamInt(snapshot, "channels.mode", 0);
    // W7：端点序号变化即请求重开汇（reserved1[0]，旧 App 恒 0 不触发）。
    // [审查 L4 2026-11-25] 首个稳定块直接采纳现值作基线：App 跨会话
    // 切换过端点时序号已非 0，旧初值 0 会让 DAW 启动首块多一次无谓
    // 的汇重开（数十 ms dropout 级）。
    const long epSeq = (long)m_params->reserved1[0];
    if (m_lastEndpointSeq < 0) {
        m_lastEndpointSeq = epSeq;
    } else if (epSeq != m_lastEndpointSeq) {
        m_lastEndpointSeq = epSeq;
        m_sinkReloadReq = true;
    }
    m_paramsMuted = (mute != 0);
    m_bypass.store(bypass != 0, std::memory_order_relaxed);
    if (m_engine && !snapshot.empty()) {
        m_engineLoader.ApplyParamsString(m_engine, snapshot.c_str());
    }
}

void AuraAsioDriver::PublishTelemetrySinkState() {
    if (!m_telemetry) return;
    m_telemetry->sampleRate = (uint32_t)(m_sampleRate + 0.5);
    m_telemetry->channels = (uint32_t)m_channels;
    m_telemetry->bufferSize = (uint32_t)m_bufferSize;
    m_telemetry->sinkOpen = m_wasapiSink.IsOpen() ? 1u : 0u;
    m_telemetry->sinkRate = (uint32_t)(m_wasapiSink.GetTargetSampleRate() + 0.5);
    m_telemetry->sinkChannels = (uint32_t)m_wasapiSink.GetTargetChannels();
    m_telemetry->sinkBits = (uint32_t)m_wasapiSink.GetValidBitsPerSample();
    m_telemetry->sinkUsedConfigured =
        m_wasapiSink.UsedConfiguredEndpoint() ? 1u : 0u;
    wcsncpy_s(m_telemetry->sinkEndpointId,
              m_wasapiSink.GetEndpointId(), _TRUNCATE);
    m_telemetry->running = 1;
}

ASIOError AuraAsioDriver::start() {
    if (!m_buffersAllocated) return ASE_InvalidMode;
    if (m_started) return ASE_OK;

    m_samplePosition = 0;
    m_toggle = 0;

    m_hStopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!m_hStopEvent) return ASE_HWMalfunction;

    OpenTelemetry();
    OpenParams();

    m_hThread = CreateThread(nullptr, 0, AudioPumpThreadProc, this, 0, nullptr);
    if (!m_hThread) {
        CloseHandle(m_hStopEvent);
        m_hStopEvent = nullptr;
        return ASE_HWMalfunction;
    }

    SetThreadPriority(m_hThread, THREAD_PRIORITY_TIME_CRITICAL);
    m_started = true;
    return ASE_OK;
}

ASIOError AuraAsioDriver::stop() {
    if (!m_started) return ASE_OK;
    m_started = false;

    if (m_hStopEvent) {
        SetEvent(m_hStopEvent);
    }
    if (m_hThread) {
        WaitForSingleObject(m_hThread, 2000);
        CloseHandle(m_hThread);
        m_hThread = nullptr;
    }
    if (m_hStopEvent) {
        CloseHandle(m_hStopEvent);
        m_hStopEvent = nullptr;
    }
    CloseTelemetry();
    CloseParams();
    return ASE_OK;
}

// ---------------- RT 时钟泵线程 ----------------

DWORD WINAPI AuraAsioDriver::AudioPumpThreadProc(LPVOID param) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    auto* self = static_cast<AuraAsioDriver*>(param);
    DWORD res = self->PumpLoop();
    if (SUCCEEDED(hr)) {
        CoUninitialize();
    }
    return res;
}

DWORD AuraAsioDriver::PumpLoop() {
    timeBeginPeriod(1);
    DWORD taskIndex = 0;
    HANDLE hMmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

    m_wasapiSink.Open();
    PublishTelemetrySinkState();

    LARGE_INTEGER qpcFreq;
    QueryPerformanceFrequency(&qpcFreq);
    const double qpcFreqD = (double)qpcFreq.QuadPart;
    const double frameDurationSec = (double)m_bufferSize / m_sampleRate;
    const int64_t ticksPerBlock = (int64_t)(frameDurationSec * qpcFreqD);

    LARGE_INTEGER qpcNow, qpcNext;
    QueryPerformanceCounter(&qpcNow);
    qpcNext.QuadPart = qpcNow.QuadPart;

    while (WaitForSingleObject(m_hStopEvent, 0) == WAIT_TIMEOUT) {
        qpcNext.QuadPart += ticksPerBlock;

        // S4：参数块拉取（seq 未变时仅一次原子读，开销可忽略）。
        PullParamsFromBlock();

        // W7：端点序号变化 → 块边界重开汇。重开会阻塞几十 ms
        // （COM + Initialize），换输出设备本来就要断音，DAW 侧只
        // 表现为一次 dropout；比"必须重开 DAW"好得多。
        if (m_sinkReloadReq) {
            m_sinkReloadReq = false;
            m_wasapiSink.Close();
            m_wasapiSink.Open();
            PublishTelemetrySinkState();
        }

        const long currentToggle = m_toggle;
        m_toggle = 1 - m_toggle;

        m_samplePosition += m_bufferSize;

        // Phase 2 / Phase 3：提取对立半区（DAW 在上一个时钟周期已填毕的数据）
        const long ch = m_channels;
        // W6：引擎宽度（channels.count 影子）。不等宽时走适配层，
        // 等宽时保持零拷贝旧路径。
        const int engCh = (m_engineCh >= 1 && m_engineCh <= (int)kMaxChannels)
                              ? m_engineCh
                              : (int)ch;
        const bool widthAdapt = (engCh != (int)ch);
        const long playIndex = 1 - currentToggle;

        float telePeakIn = 0.0f, telePeakOut = 0.0f;
        float telePeakInCh[8] = {};
        float telePeakOutCh[8] = {};
        if (m_proc && m_interleavedIn && m_interleavedOut && m_foldL && m_foldR) {
            // 按通道收集 DAW 输出块，交织进 m_interleavedIn（缺缓冲的通道补零）
            for (long c = 0; c < ch; ++c) {
                const float* play = (m_outputActive[c] && m_outBuffers[c][playIndex])
                                        ? m_outBuffers[c][playIndex] : nullptr;
                for (long i = 0; i < m_bufferSize; ++i) {
                    m_interleavedIn[i * ch + c] = play ? play[i] : 0.0f;
                }
            }

            if (m_paramsMuted) {
                // 链路总闸静音（参数块 mute）：汇与回环均零，
                // 遥测峰值随折叠归零、频谱走清零分支。
                memset(m_proc, 0, (size_t)m_bufferSize * (size_t)ch * sizeof(float));
            } else if (m_engine && !m_bypass.load(std::memory_order_relaxed)) {
                // W6：流宽 ↔ 引擎宽适配。
                //   离散（mode=1）：按 chmap_stream_pos 取声道，映射外
                //     丢弃——4ch 引擎的 BL/BR 取自 8 宽流的 6/7，不会
                //     把 C/LFE 误当 BL/BR（本轮 4.0 错位的根因）。
                //   矩阵（mode=0）收窄：chmap_fold 折叠保能量（8→6 时
                //     BL/BR 折进 SL/SR）。
                //   矩阵扩张：按布局放置，静音槽交给引擎上混/填充。
                const float* engIn = m_interleavedIn;
                float* engOut = m_interleavedOut;
                if (widthAdapt) {
                    if (m_channelMode != 0) {
                        chmap_gather_discrete(m_interleavedIn, (int)ch,
                                              m_engIn, engCh,
                                              (int)m_bufferSize);
                    } else if (engCh < (int)ch) {
                        chmap_fold(m_interleavedIn, (int)ch, m_engIn, engCh,
                                   (int)m_bufferSize);
                    } else {
                        chmap_scatter_discrete(m_interleavedIn, (int)ch,
                                               m_engIn, engCh,
                                               (int)m_bufferSize);
                    }
                    engIn = m_engIn;
                    engOut = m_engOut;
                }
                m_engineLoader.Process(m_engine, engIn, engOut,
                                       (int)m_bufferSize, engCh);
                if (!widthAdapt) {
                    memcpy(m_proc, engOut,
                           (size_t)m_bufferSize * (size_t)ch * sizeof(float));
                } else if (m_channelMode == 0 && engCh > (int)ch) {
                    // 上混后的宽引擎输出折回窄流
                    chmap_fold(engOut, engCh, m_proc, (int)ch,
                               (int)m_bufferSize);
                } else {
                    // 引擎窄：按布局放回流（离散与矩阵同口径；scatter
                    // 整帧先清零，未被引擎覆盖的流声道保持静音）。
                    chmap_scatter_discrete(engOut, engCh, m_proc, (int)ch,
                                           (int)m_bufferSize);
                }
                m_dspProcessedFrames.fetch_add((uint64_t)m_bufferSize, std::memory_order_relaxed);
            } else {
                // 旁路直通（或未加载引擎时安全透传）
                memcpy(m_proc, m_interleavedIn, (size_t)m_bufferSize * (size_t)ch * sizeof(float));
            }

            // N→立体声下混（始终计算）：peakOut 单值遥测、旧面板兼容
            // 与端点回落都依赖这对缓存的最终折叠结果。
            if (ch <= 2) {
                for (long i = 0; i < m_bufferSize; ++i) {
                    m_foldL[i] = m_proc[i * ch + 0];
                    m_foldR[i] = (ch > 1) ? m_proc[i * ch + 1] : m_proc[i * ch + 0];
                }
            } else {
                // 下混表已收编至 engine/chain/channel_map.h
                // （第五十五轮）。旧手写表按错序索引：f[3] 实为
                // LFE 却被折入、SL/SR 左右互换、BR 从未入折——
                // 统一表按标准声道序折入且 LFE 不入折。
                for (long i = 0; i < m_bufferSize; ++i) {
                    float lr[2];
                    chmap_fold_frame(m_proc + i * ch, (int)ch, lr, 2);
                    m_foldL[i] = lr[0];
                    m_foldR[i] = lr[1];
                }
            }

            // 1. WASAPI 物理渲染汇直通推流（W5 多声道）
            // 端点宽度决定路径：立体声端点维持原折叠推流（逐样本
            // 等价）；端点多声道且流不宽于端点时离散直通；流更宽时
            // 用同一张 chmap 表下混到端点宽度。下混目标缓冲按 8 声道
            // 上限在 createBuffers 分配，RT 路径零分配。
            const int sinkCh = m_wasapiSink.GetTargetChannels();
            if (sinkCh <= 2) {
                m_wasapiSink.PushSamples(m_foldL, m_foldR, m_bufferSize, m_sampleRate);
            } else if (ch <= sinkCh) {
                m_wasapiSink.PushSamplesInterleaved(m_proc, (int)ch,
                                                    m_bufferSize, m_sampleRate);
            } else {
                for (long i = 0; i < m_bufferSize; ++i) {
                    chmap_fold_frame(m_proc + i * ch, (int)ch,
                                     m_multiOut + (size_t)i * (size_t)sinkCh,
                                     sinkCh);
                }
                m_wasapiSink.PushSamplesInterleaved(m_multiOut, sinkCh,
                                                    m_bufferSize, m_sampleRate);
            }

            // 2. 将处理后各通道提供给输入通道（标准虚拟驱动 Loopback 回录）
            for (long c = 0; c < ch; ++c) {
                float* dst = (m_inputActive[c] && m_inBuffers[c][currentToggle])
                                 ? m_inBuffers[c][currentToggle] : nullptr;
                if (dst) {
                    for (long i = 0; i < m_bufferSize; ++i) {
                        dst[i] = m_proc[i * ch + c];
                    }
                }
            }

            // S3 遥测峰值：入 = DAW 原始块 ch0/1，出 = 处理后立体声折。
            // r65 v3：同一循环顺带逐声道峰值——入取交织原始块、出
            // 取折叠前的处理结果；旧单值口径原样保留（面板兼容）。
            // W6：逐声道峰值改按**引擎声道序**上报——UI 按 channels.count
            // 显示 N 槽、标签取引擎布局，数据必须同序。4ch 引擎的 BL/BR
            // 在 8 宽流里位于 6/7，直接取流前 4 位会把 C/LFE 显示成
            // BL/BR（本轮 4.0 实测错位的直接原因）。
            for (long i = 0; i < m_bufferSize; ++i) {
                const float a0 = std::abs(m_interleavedIn[i * ch + 0]);
                const float a1 =
                    (ch > 1) ? std::abs(m_interleavedIn[i * ch + 1]) : a0;
                if (a0 > telePeakIn) telePeakIn = a0;
                if (a1 > telePeakIn) telePeakIn = a1;
                const float o0 = std::abs(m_foldL[i]);
                const float o1 = std::abs(m_foldR[i]);
                if (o0 > telePeakOut) telePeakOut = o0;
                if (o1 > telePeakOut) telePeakOut = o1;
                for (int c = 0; c < engCh && c < 8; ++c) {
                    const int pos = chmap_stream_pos(engCh, (int)ch, c);
                    if (pos >= (int)ch) continue;
                    const float ai =
                        std::abs(m_interleavedIn[(size_t)i * (size_t)ch + pos]);
                    if (ai > telePeakInCh[c]) telePeakInCh[c] = ai;
                    const float ao =
                        std::abs(m_proc[(size_t)i * (size_t)ch + pos]);
                    if (ao > telePeakOutCh[c]) telePeakOutCh[c] = ao;
                }
            }
        }

        // S3 遥测逐块发布（共享内存普通写，泵线程零额外同步）。
        if (m_telemetry) {
            m_telemetry->heartbeat++;
            m_telemetry->processedFrames = (uint64_t)m_samplePosition;
            m_telemetry->peakIn = telePeakIn;
            m_telemetry->peakOut = telePeakOut;
            std::memcpy(m_telemetry->peakInCh, telePeakInCh,
                        sizeof(telePeakInCh));
            std::memcpy(m_telemetry->peakOutCh, telePeakOutCh,
                        sizeof(telePeakOutCh));
            // S4 频谱：取引擎 viz 环最新一帧。旁路（引擎不处理）
            // 或引擎缺席/viz 未绑定时写全零，不留陈旧频谱误导
            // UI；处理中但本块无新帧则保留上一帧（防闪烁）。
            if (!m_paramsMuted &&
                !m_bypass.load(std::memory_order_relaxed) && m_engine &&
                m_engineLoader.HasViz()) {
                auradsp_viz_frame frame;
                int guard = 0;
                while (m_engineLoader.VizRead(m_engine, &frame, 1) > 0 &&
                       ++guard <= 32) {
                    std::memcpy(m_telemetry->spectrum, frame.spectrum,
                                sizeof(m_telemetry->spectrum));
                    std::memcpy(m_telemetry->eqInSpectrum,
                                frame.eq_in_spectrum,
                                sizeof(m_telemetry->eqInSpectrum));
                }
            } else {
                std::memset(m_telemetry->spectrum, 0,
                            sizeof(m_telemetry->spectrum));
                std::memset(m_telemetry->eqInSpectrum, 0,
                            sizeof(m_telemetry->eqInSpectrum));
            }
            m_telemetry->updateSeq++;
        }

        // 通知 DAW：消费输入/填充输出半区
        if (m_callbacks) {
            if (m_timeInfoMode && m_callbacks->bufferSwitchTimeInfo) {
                ASIOTime asioTime;
                memset(&asioTime, 0, sizeof(asioTime));
                asioTime.timeInfo.speed = 1.0;

                uint64_t ns = 0;
                if (qpcFreq.QuadPart > 0) {
                    ns = (uint64_t)((qpcNow.QuadPart * 1000000000ULL) / qpcFreq.QuadPart);
                }
                asioTime.timeInfo.systemTime.lo = (unsigned long)(ns & 0xFFFFFFFF);
                asioTime.timeInfo.systemTime.hi = (unsigned long)((ns >> 32) & 0xFFFFFFFF);

                asioTime.timeInfo.samplePosition.lo = (unsigned long)(m_samplePosition & 0xFFFFFFFF);
                asioTime.timeInfo.samplePosition.hi = (unsigned long)((m_samplePosition >> 32) & 0xFFFFFFFF);

                asioTime.timeInfo.sampleRate = m_sampleRate;
                asioTime.timeInfo.flags = kSystemTimeValid | kSamplePositionValid | kSampleRateValid;

                m_callbacks->bufferSwitchTimeInfo(&asioTime, currentToggle, ASIOFalse);
            } else if (m_callbacks->bufferSwitch) {
                m_callbacks->bufferSwitch(currentToggle, ASIOFalse);
            }
        }

        // 精确等待直到 qpcNext
        QueryPerformanceCounter(&qpcNow);
        int64_t remainingTicks = qpcNext.QuadPart - qpcNow.QuadPart;
        if (remainingTicks > 0) {
            double remainingMs = ((double)remainingTicks / qpcFreqD) * 1000.0;
            if (remainingMs > 1.5) {
                DWORD sleepMs = (DWORD)(remainingMs - 1.0);
                DWORD waitRes = WaitForSingleObject(m_hStopEvent, sleepMs);
                if (waitRes != WAIT_TIMEOUT) break;
            }
            // 微秒级自旋收尾
            do {
                QueryPerformanceCounter(&qpcNow);
            } while (qpcNow.QuadPart < qpcNext.QuadPart &&
                     WaitForSingleObject(m_hStopEvent, 0) == WAIT_TIMEOUT);
        } else {
            // 超载时步进跟上，防止雪崩
            qpcNext.QuadPart = qpcNow.QuadPart;
        }
    }

    if (m_telemetry) m_telemetry->running = 0;
    m_wasapiSink.Close();

    if (hMmcss) AvRevertMmThreadCharacteristics(hMmcss);
    timeEndPeriod(1);
    return 0;
}
