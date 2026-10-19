// AuraAsioDriver.cpp — AuraDSP 虚拟 ASIO 驱动实现
#include "AuraAsioDriver.h"
#include "AuraAsioDriverGuid.h"

#include <cmath>
#include <cstring>
#include <new>

std::atomic<long> AuraAsioDriver::s_instanceCount{0};

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
    if (RegGetValueW(HKEY_CURRENT_USER, L"SOFTWARE\\AuraDSP\\AsioDriver",
                     L"Channels", RRF_RT_REG_DWORD, nullptr, &val, &sz) == ERROR_SUCCESS ||
        RegGetValueW(HKEY_CLASSES_ROOT, clsidKey.c_str(),
                     L"Channels", RRF_RT_REG_DWORD, nullptr, &val, &sz) == ERROR_SUCCESS) {
        if (IsValidChannelCount((long)val)) {
            m_channels = (long)val;
            return;
        }
    }
    m_channels = 2;
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

ASIOError AuraAsioDriver::setSampleRate(ASIOSampleRate sampleRate) {
    if (canSampleRate(sampleRate) != ASE_OK) return ASE_NoClock;
    if (m_started) return ASE_InvalidMode;
    m_sampleRate = sampleRate;
    if (m_engine) {
        m_engineLoader.DestroyEngine(m_engine);
        m_engine = m_engineLoader.CreateEngine((float)m_sampleRate, (int)m_bufferSize);
        if (m_engine && !m_pendingParamString.empty()) {
            m_engineLoader.ApplyParamsString(m_engine, m_pendingParamString.c_str());
        }
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
    if (!m_interleavedIn || !m_interleavedOut || !m_proc || !m_foldL || !m_foldR) {
        disposeBuffers();
        return ASE_NoMemory;
    }
    memset(m_interleavedIn, 0, interBytes);
    memset(m_interleavedOut, 0, interBytes);
    memset(m_proc, 0, interBytes);
    memset(m_foldL, 0, pairBytes);
    memset(m_foldR, 0, pairBytes);

    // 引擎句柄实例化（按协商后的采样率与缓冲大小创建）
    if (!m_engineLoader.IsLoaded()) {
        m_engineLoader.Load();
    }
    if (m_engineLoader.IsLoaded()) {
        m_engine = m_engineLoader.CreateEngine((float)m_sampleRate, (int)m_bufferSize);
        if (m_engine && !m_pendingParamString.empty()) {
            m_engineLoader.ApplyParamsString(m_engine, m_pendingParamString.c_str());
        }
        // B2c：驱动为权威，钉死引擎通道档位（避免传输/处理步长不一致）
        if (m_engine) {
            int nCh = (int)m_channels;
            m_engineLoader.SetParam(m_engine, "channels.count", &nCh, (uint32_t)sizeof(nCh));
        }
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

    // Phase 2 诊断选择子
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

    // Phase 3 DSP 扩展与诊断选择子
    case kAuraAsioFutureIsDspLoaded:
        if (opt) {
            *reinterpret_cast<long*>(opt) = m_engineLoader.IsLoaded() ? 1 : 0;
            return ASE_SUCCESS;
        }
        return m_engineLoader.IsLoaded() ? ASE_SUCCESS : ASE_NotPresent;

    case kAuraAsioFutureSetBypass:
        if (opt) {
            const long val = *reinterpret_cast<const long*>(opt);
            m_bypass.store(val != 0, std::memory_order_relaxed);
            return ASE_SUCCESS;
        }
        m_bypass.store(true, std::memory_order_relaxed);
        return ASE_SUCCESS;

    case kAuraAsioFutureGetBypass:
        if (opt) {
            *reinterpret_cast<long*>(opt) = m_bypass.load(std::memory_order_relaxed) ? 1 : 0;
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;

    case kAuraAsioFutureSetParam:
        if (opt) {
            auto* p = reinterpret_cast<const AuraAsioParamIo*>(opt);
            if (!p || !p->id) return ASE_InvalidParameter;
            if (m_engine) {
                int rc = m_engineLoader.SetParam(m_engine, p->id, p->value, p->bytes);
                return (rc == 0) ? ASE_SUCCESS : ASE_InvalidParameter;
            }
            return ASE_NotPresent;
        }
        return ASE_InvalidParameter;

    case kAuraAsioFutureGetParam:
        if (opt) {
            auto* p = reinterpret_cast<AuraAsioParamIo*>(opt);
            if (!p || !p->id || !p->value) return ASE_InvalidParameter;
            if (m_engine) {
                int rc = m_engineLoader.GetParam(m_engine, p->id, p->value, p->bytes);
                return (rc == 0) ? ASE_SUCCESS : ASE_InvalidParameter;
            }
            return ASE_NotPresent;
        }
        return ASE_InvalidParameter;

    case kAuraAsioFutureApplyParamsString:
        if (opt) {
            const char* s = reinterpret_cast<const char*>(opt);
            if (!s) return ASE_InvalidParameter;
            m_pendingParamString += std::string(";") + s;
            if (m_engine) {
                int applied = m_engineLoader.ApplyParamsString(m_engine, s);
                return (applied >= 0) ? ASE_SUCCESS : ASE_InvalidParameter;
            }
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;

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

    case kAuraAsioFutureSetChannels:
        // B2c：仅允许在 createBuffers 之前设置；驱动为权威并同步引擎 channels.count
        if (opt) {
            if (m_buffersAllocated) return ASE_InvalidMode;
            const long n = *reinterpret_cast<const long*>(opt);
            if (!IsValidChannelCount(n)) return ASE_InvalidParameter;
            m_channels = n;
            if (m_engine) {
                int nCh = (int)m_channels;
                m_engineLoader.SetParam(m_engine, "channels.count", &nCh, (uint32_t)sizeof(nCh));
            }
            return ASE_SUCCESS;
        }
        return ASE_InvalidParameter;

    case kAuraAsioFutureGetChannels:
        if (opt) {
            *reinterpret_cast<long*>(opt) = m_channels;
            return ASE_SUCCESS;
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

ASIOError AuraAsioDriver::start() {
    if (!m_buffersAllocated) return ASE_InvalidMode;
    if (m_started) return ASE_OK;

    m_samplePosition = 0;
    m_toggle = 0;

    m_hStopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!m_hStopEvent) return ASE_HWMalfunction;

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

        const long currentToggle = m_toggle;
        m_toggle = 1 - m_toggle;

        m_samplePosition += m_bufferSize;

        // Phase 2 / Phase 3：提取对立半区（DAW 在上一个时钟周期已填毕的数据）
        const long ch = m_channels;
        const long playIndex = 1 - currentToggle;

        if (m_proc && m_interleavedIn && m_interleavedOut && m_foldL && m_foldR) {
            // 按通道收集 DAW 输出块，交织进 m_interleavedIn（缺缓冲的通道补零）
            for (long c = 0; c < ch; ++c) {
                const float* play = (m_outputActive[c] && m_outBuffers[c][playIndex])
                                        ? m_outBuffers[c][playIndex] : nullptr;
                for (long i = 0; i < m_bufferSize; ++i) {
                    m_interleavedIn[i * ch + c] = play ? play[i] : 0.0f;
                }
            }

            if (m_engine && !m_bypass.load(std::memory_order_relaxed)) {
                // 交织 DAW 输出送入 DSP 处理
                m_engineLoader.Process(m_engine, m_interleavedIn, m_interleavedOut, (int)m_bufferSize);
                memcpy(m_proc, m_interleavedOut, (size_t)m_bufferSize * (size_t)ch * sizeof(float));
                m_dspProcessedFrames.fetch_add((uint64_t)m_bufferSize, std::memory_order_relaxed);
            } else {
                // 旁路直通（或未加载引擎时安全透传）
                memcpy(m_proc, m_interleavedIn, (size_t)m_bufferSize * (size_t)ch * sizeof(float));
            }

            // N→立体声下混，供 WasapiSink 物理端点（2 声道为逐样本等价拷贝）
            if (ch <= 2) {
                for (long i = 0; i < m_bufferSize; ++i) {
                    m_foldL[i] = m_proc[i * ch + 0];
                    m_foldR[i] = (ch > 1) ? m_proc[i * ch + 1] : m_proc[i * ch + 0];
                }
            } else {
                const float k = 0.70710678f;  // 标准 -3dB 下混系数
                for (long i = 0; i < m_bufferSize; ++i) {
                    const float* f = m_proc + i * ch;
                    float l = f[0], r = f[1];
                    if (ch > 2) { const float ctr = f[2] * k; l += ctr; r += ctr; }
                    if (ch > 3) { l += f[3] * k; }
                    if (ch > 4) { r += f[4] * k; }
                    if (ch > 5) { l += f[5] * k; }
                    if (ch > 6) { r += f[6] * k; }
                    m_foldL[i] = l;
                    m_foldR[i] = r;
                }
            }

            // 1. WASAPI 物理渲染汇直通推流
            m_wasapiSink.PushSamples(m_foldL, m_foldR, m_bufferSize, m_sampleRate);

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

    m_wasapiSink.Close();

    if (hMmcss) AvRevertMmThreadCharacteristics(hMmcss);
    timeEndPeriod(1);
    return 0;
}
