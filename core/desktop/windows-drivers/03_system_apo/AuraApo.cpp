// AuraApo.cpp — clean-room 实现（骨架模式对标 EAPO，逐行自写）。
#include "AuraApo.h"

#include <sddl.h>

#include "AuraApoGuid.h"
#include "AuraHeartbeat.h"

long CAuraApo::instCount = 0;

const CRegAPOProperties<1> CAuraApo::regEfxProperties(
    CLSID_AuraApoEfx, L"AuraAPO EFX", L"AuraDSP", 1, 0, IID_IAudioSystemEffects);

CAuraApo::CAuraApo(IUnknown* pUnkOuter)
    : CBaseAudioProcessingObject(regEfxProperties), m_outer(pUnkOuter) {
    InterlockedIncrement(&instCount);
}

CAuraApo::~CAuraApo() {
    CloseHeartbeat();
    InterlockedDecrement(&instCount);
}

HRESULT __stdcall CAuraApo::QueryInterface(REFIID iid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (m_outer) return m_outer->QueryInterface(iid, ppv);
    return NonDelegatingQueryInterface(iid, ppv);
}

ULONG __stdcall CAuraApo::AddRef() {
    if (m_outer) return m_outer->AddRef();
    return NonDelegatingAddRef();
}

ULONG __stdcall CAuraApo::Release() {
    if (m_outer) return m_outer->Release();
    return NonDelegatingRelease();
}

HRESULT __stdcall CAuraApo::NonDelegatingQueryInterface(REFIID iid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (iid == IID_IUnknown)
        *ppv = static_cast<INonDelegatingUnknown*>(this);
    else if (iid == IID_IAudioSystemEffects)
        *ppv = static_cast<IAudioSystemEffects*>(this);
    else if (iid == IID_IAudioProcessingObject)
        *ppv = static_cast<IAudioProcessingObject*>(this);
    else if (iid == IID_IAudioProcessingObjectRT)
        *ppv = static_cast<IAudioProcessingObjectRT*>(this);
    else if (iid == IID_IAudioProcessingObjectConfiguration)
        *ppv = static_cast<IAudioProcessingObjectConfiguration*>(this);
    else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    NonDelegatingAddRef();
    return S_OK;
}

ULONG __stdcall CAuraApo::NonDelegatingAddRef() {
    return (ULONG)InterlockedIncrement(&m_ref);
}

ULONG __stdcall CAuraApo::NonDelegatingRelease() {
    const ULONG n = (ULONG)InterlockedDecrement(&m_ref);
    if (n == 0) delete this;
    return n;
}

HRESULT __stdcall CAuraApo::GetLatency(HNSTIME* pTime) {
    if (!pTime) return E_POINTER;
    *pTime = 0;  // v1 透传零附加延迟
    return S_OK;
}

HRESULT __stdcall CAuraApo::Initialize(UINT32 /*cbDataSize*/, BYTE* /*pbyData*/) {
    return S_OK;  // v1 无初始化参数，照单全收
}

HRESULT __stdcall CAuraApo::IsInputFormatSupported(
    IAudioMediaType* /*pOutputFormat*/, IAudioMediaType* /*pRequestedInputFormat*/,
    IAudioMediaType** ppSupportedInputFormat) {
    // SPEC 宽容协商：透传与格式无关，全接受（S_OK = 按请求格式即可）。
    if (ppSupportedInputFormat) *ppSupportedInputFormat = nullptr;
    return S_OK;
}

HRESULT __stdcall CAuraApo::IsOutputFormatSupported(
    IAudioMediaType* /*pInputFormat*/, IAudioMediaType* /*pRequestedOutputFormat*/,
    IAudioMediaType** ppSupportedOutputFormat) {
    if (ppSupportedOutputFormat) *ppSupportedOutputFormat = nullptr;
    return S_OK;
}

HRESULT __stdcall CAuraApo::LockForProcess(UINT32 nIn, APO_CONNECTION_DESCRIPTOR** ppIn,
                                           UINT32 nOut, APO_CONNECTION_DESCRIPTOR** ppOut) {
    if ((nIn == 0 || !ppIn) || (nOut == 0 || !ppOut)) return E_INVALIDARG;
    m_nConn = nIn < nOut ? nIn : nOut;
    if (m_nConn > 8) m_nConn = 8;
    m_sampleRate = 0;
    for (UINT32 i = 0; i < m_nConn; ++i) {
        // pFormat 是 IAudioMediaType*（不是 WAVEFORMATEX，强转是未定义行为）。
        UNCOMPRESSEDAUDIOFORMAT uf{};
        UINT32 align = 4;
        if (ppIn[i]->pFormat &&
            SUCCEEDED(ppIn[i]->pFormat->GetUncompressedAudioFormat(&uf)) &&
            uf.dwSamplesPerFrame > 0 && uf.dwSamplesPerFrame <= 32 &&
            uf.dwBytesPerSampleContainer > 0 && uf.dwBytesPerSampleContainer <= 8) {
            align = uf.dwSamplesPerFrame * uf.dwBytesPerSampleContainer;
            if (uf.fFramesPerSecond > (FLOAT32)m_sampleRate)
                m_sampleRate = (UINT32)uf.fFramesPerSecond;
        }
        m_blockAlign[i] = align ? align : 4;
    }
    if (!OpenHeartbeat()) {
        // 心跳建不起（audiodg 上下文权限/命名空间所限）也绝不断流：
        // 降级为纯透传（无心跳上报）。处理优先于观测。
    }
    return S_OK;
}

HRESULT __stdcall CAuraApo::UnlockForProcess() {
    CloseHeartbeat();
    m_nConn = 0;
    return S_OK;
}

void __stdcall CAuraApo::APOProcess(UINT32 nIn, APO_CONNECTION_PROPERTY** ppIn, UINT32 nOut,
                                    APO_CONNECTION_PROPERTY** ppOut) {
    UINT32 n = nIn < nOut ? nIn : nOut;
    if (n > m_nConn) n = m_nConn;
    if (n > 8) n = 8;
    for (UINT32 i = 0; i < n; ++i) {
        const APO_CONNECTION_PROPERTY* in = ppIn[i];
        APO_CONNECTION_PROPERTY* out = ppOut[i];
        // pBuffer 是 UINT_PTR 整型（AudioAPOTypes.h），必须显式转指针。
        const BYTE* inBuf = in ? (const BYTE*)in->pBuffer : nullptr;
        BYTE* outBuf = out ? (BYTE*)out->pBuffer : nullptr;
        if (!in || !out || !inBuf || !outBuf) continue;
        UINT32 frames = in->u32ValidFrameCount;
        const size_t bytes = (size_t)frames * (m_blockAlign[i] ? m_blockAlign[i] : 4);
        if (in->u32BufferFlags & BUFFER_SILENT) {
            // SILENT 输入：清零输出并透传标志（EAPO 同式；杜绝垃圾爆音）。
            memset(outBuf, 0, bytes);
            out->u32BufferFlags = BUFFER_SILENT;
        } else {
            memcpy(outBuf, inBuf, bytes);
            out->u32BufferFlags = BUFFER_VALID;
        }
        out->u32ValidFrameCount = frames;
        const LONG seq = InterlockedIncrement(&m_seq);
        // framesTotal 累加（LONGLONG 原子加）。
        const LONGLONG total =
            InterlockedExchangeAdd64((volatile LONGLONG*)&m_frames, (LONGLONG)frames) +
            (LONGLONG)frames;
        // 心跳映射：Lock 期建好即只写（无锁、无等待；失败路径压根没建，空指针跳过）。
        AuraHeartbeat* hb = (AuraHeartbeat*)m_hbView;
        if (hb) {
            hb->seq = (uint32_t)seq;
            hb->framesTotal = (uint64_t)total;
            hb->lastNbs = frames;
        }
    }
}

bool CAuraApo::OpenHeartbeat() {
    CloseHeartbeat();
    // LocalService（audiodg）+ 任何用户进程可读写（SPEC §3 DACL 模式）。
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GA;;;LS)(A;;GA;;;WD)", SDDL_REVISION_1, &sd, nullptr))
        return false;
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = sd;
    sa.bInheritHandle = FALSE;
    HANDLE hMap = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0,
                                     (DWORD)sizeof(AuraHeartbeat), AURA_HEARTBEAT_MAP_NAME);
    LocalFree(sd);
    if (!hMap) return false;
    void* view = MapViewOfFile(hMap, FILE_MAP_WRITE, 0, 0, sizeof(AuraHeartbeat));
    if (!view) {
        CloseHandle(hMap);
        return false;
    }
    auto* hb = (AuraHeartbeat*)view;
    hb->magic = AURA_HEARTBEAT_MAGIC;
    hb->version = AURA_HEARTBEAT_VERSION;
    hb->seq = 0;
    hb->sampleRate = m_sampleRate;
    hb->framesTotal = 0;
    hb->lastNbs = 0;
    hb->pid = GetCurrentProcessId();
    m_hMap = hMap;
    m_hbView = view;
    return true;
}

void CAuraApo::CloseHeartbeat() {
    if (m_hbView) {
        UnmapViewOfFile(m_hbView);
        m_hbView = nullptr;
    }
    if (m_hMap) {
        CloseHandle(m_hMap);
        m_hMap = nullptr;
    }
}
