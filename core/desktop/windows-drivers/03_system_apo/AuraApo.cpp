// AuraApo.cpp — 自研 System APO v1（透传 + 心跳 + RT-safe）。
#include "AuraApo.h"

#include <sddl.h>
#include <cstdio>
#include <cstring>

#include "AuraApoGuid.h"
#include "AuraHeartbeat.h"

long CAuraApo::instCount = 0;

// ---------------------------------------------------------------------------
// Inner IUnknown（非委托，控制实际对象生命周期）
// ---------------------------------------------------------------------------
STDMETHODIMP CAuraApo::Inner::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown) {
        *ppv = static_cast<IUnknown*>(this);
    } else if (riid == IID_IAudioProcessingObject) {
        *ppv = static_cast<IAudioProcessingObject*>(self);
    } else if (riid == IID_IAudioProcessingObjectRT) {
        *ppv = static_cast<IAudioProcessingObjectRT*>(self);
    } else if (riid == IID_IAudioProcessingObjectConfiguration) {
        *ppv = static_cast<IAudioProcessingObjectConfiguration*>(self);
    } else if (riid == IID_IAudioSystemEffects) {
        *ppv = static_cast<IAudioSystemEffects*>(self);
    } else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ((IUnknown*)*ppv)->AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CAuraApo::Inner::AddRef() {
    return (ULONG)self->refs_.fetch_add(1) + 1;
}

STDMETHODIMP_(ULONG) CAuraApo::Inner::Release() {
    ULONG n = (ULONG)self->refs_.fetch_sub(1) - 1;
    if (n == 0) delete self;
    return n;
}

// ---------------------------------------------------------------------------
// CAuraApo 构造与析构
// ---------------------------------------------------------------------------
CAuraApo::CAuraApo(IUnknown* outer) {
    inner_.self = this;
    outer_ = outer ? outer : static_cast<IUnknown*>(&inner_);
    InterlockedIncrement(&instCount);
}

CAuraApo::~CAuraApo() {
    CloseHeartbeat();
    InterlockedDecrement(&instCount);
}

// ---------------------------------------------------------------------------
// 委托态 IUnknown（委托给 outer）
// ---------------------------------------------------------------------------
STDMETHODIMP CAuraApo::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    return outer_->QueryInterface(riid, ppv);
}

STDMETHODIMP_(ULONG) CAuraApo::AddRef() {
    return outer_->AddRef();
}

STDMETHODIMP_(ULONG) CAuraApo::Release() {
    return outer_->Release();
}

// ---------------------------------------------------------------------------
// IAudioProcessingObject
// ---------------------------------------------------------------------------
STDMETHODIMP CAuraApo::Reset() {
    return S_OK;
}

STDMETHODIMP CAuraApo::GetLatency(HNSTIME* pTime) {
    if (!pTime) return E_POINTER;
    *pTime = 0;  // 透传零延迟
    return S_OK;
}

STDMETHODIMP CAuraApo::GetRegistrationProperties(APO_REG_PROPERTIES** ppRegProps) {
    if (!ppRegProps) return E_POINTER;
    auto* p = (APO_REG_PROPERTIES*)CoTaskMemAlloc(sizeof(APO_REG_PROPERTIES));
    if (!p) return E_OUTOFMEMORY;
    memset(p, 0, sizeof(*p));
    p->clsid = CLSID_AuraApoEfx;
    p->Flags = (APO_FLAG)(APO_FLAG_INPLACE | APO_FLAG_DEFAULT);
    wcscpy_s(p->szFriendlyName, L"AuraAPO EFX");
    wcscpy_s(p->szCopyrightInfo, L"AuraDSP");
    p->u32MajorVersion = 1;
    p->u32MinorVersion = 0;
    p->u32MinInputConnections = 1;
    p->u32MaxInputConnections = 1;
    p->u32MinOutputConnections = 1;
    p->u32MaxOutputConnections = 1;
    p->u32MaxInstances = 0xFFFFFFFF;
    p->u32NumAPOInterfaces = 1;
    p->iidAPOInterfaceList[0] = IID_IAudioProcessingObject;
    *ppRegProps = p;
    return S_OK;
}

STDMETHODIMP CAuraApo::Initialize(UINT32 /*cbDataSize*/, BYTE* /*pbyData*/) {
    return S_OK;
}

bool CAuraApo::IsFloat32Type(IAudioMediaType* type) {
    const WAVEFORMATEX* wf = type ? type->GetAudioFormat() : nullptr;
    if (!wf) return false;
    if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        const auto* wfe = (const WAVEFORMATEXTENSIBLE*)wf;
        return IsEqualGUID(wfe->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != FALSE;
    }
    return false;
}

HRESULT CAuraApo::CheckFormat(IAudioMediaType* opposite, IAudioMediaType* requested,
                              IAudioMediaType** supported) {
    if (!requested || !supported) return E_POINTER;
    *supported = nullptr;
    if (opposite) {
        const WAVEFORMATEX* a = opposite->GetAudioFormat();
        const WAVEFORMATEX* b = requested->GetAudioFormat();
        if (a && b && (a->nChannels != b->nChannels || a->nSamplesPerSec != b->nSamplesPerSec ||
                       a->wBitsPerSample != b->wBitsPerSample)) {
            *supported = opposite;
            opposite->AddRef();
            return S_FALSE;
        }
    }
    if (!IsFloat32Type(requested)) return APOERR_FORMAT_NOT_SUPPORTED;
    *supported = requested;
    requested->AddRef();
    return S_OK;
}

STDMETHODIMP CAuraApo::IsInputFormatSupported(IAudioMediaType* pOppositeFormat,
                                              IAudioMediaType* pRequestedInputFormat,
                                              IAudioMediaType** ppSupportedInputFormat) {
    return CheckFormat(pOppositeFormat, pRequestedInputFormat, ppSupportedInputFormat);
}

STDMETHODIMP CAuraApo::IsOutputFormatSupported(IAudioMediaType* pOppositeFormat,
                                               IAudioMediaType* pRequestedOutputFormat,
                                               IAudioMediaType** ppSupportedOutputFormat) {
    return CheckFormat(pOppositeFormat, pRequestedOutputFormat, ppSupportedOutputFormat);
}

STDMETHODIMP CAuraApo::GetInputChannelCount(UINT32* pu32ChannelCount) {
    if (!pu32ChannelCount) return E_POINTER;
    *pu32ChannelCount = channels_ ? channels_ : 2;
    return S_OK;
}

// ---------------------------------------------------------------------------
// IAudioProcessingObjectConfiguration
// ---------------------------------------------------------------------------
STDMETHODIMP CAuraApo::LockForProcess(UINT32 numIn, APO_CONNECTION_DESCRIPTOR** in,
                                      UINT32 numOut, APO_CONNECTION_DESCRIPTOR** out) {
    if (numIn != 1 || numOut != 1 || !in || !out || !in[0] || !out[0])
        return APOERR_NUM_CONNECTIONS_INVALID;
    const WAVEFORMATEX* wf = in[0]->pFormat ? in[0]->pFormat->GetAudioFormat() : nullptr;
    if (!wf) return APOERR_INVALID_CONNECTION_FORMAT;
    channels_ = wf->nChannels ? wf->nChannels : 2;
    rate_ = wf->nSamplesPerSec ? wf->nSamplesPerSec : 48000;
    blockAlign_ = wf->nBlockAlign ? wf->nBlockAlign : (channels_ * sizeof(float));
    locked_ = true;
    OpenHeartbeat();
    return S_OK;
}

STDMETHODIMP CAuraApo::UnlockForProcess() {
    CloseHeartbeat();
    locked_ = false;
    return S_OK;
}

// ---------------------------------------------------------------------------
// IAudioProcessingObjectRT
// ---------------------------------------------------------------------------
STDMETHODIMP_(void) CAuraApo::APOProcess(UINT32 numIn, APO_CONNECTION_PROPERTY** in,
                                         UINT32 numOut, APO_CONNECTION_PROPERTY** out) {
    if (numIn != 1 || numOut != 1 || !in || !out || !in[0] || !out[0]) return;
    const APO_CONNECTION_PROPERTY* cin = in[0];
    APO_CONNECTION_PROPERTY* cout = out[0];
    const UINT32 frames = cin->u32ValidFrameCount;
    const BYTE* src = (const BYTE*)cin->pBuffer;
    BYTE* dst = (BYTE*)cout->pBuffer;
    const size_t bytes = (size_t)frames * (blockAlign_ ? blockAlign_ : (channels_ * sizeof(float)));

    if (cin->u32BufferFlags & BUFFER_SILENT) {
        if (dst) memset(dst, 0, bytes);
        cout->u32BufferFlags = BUFFER_SILENT;
    } else {
        if (dst && src && dst != src) memcpy(dst, src, bytes);
        cout->u32BufferFlags = cin->u32BufferFlags;
    }
    cout->u32ValidFrameCount = frames;

    // 心跳上报：无锁、无分配
    const LONG seq = InterlockedIncrement(&seq_);
    const LONGLONG total =
        InterlockedExchangeAdd64((volatile LONGLONG*)&frames_, (LONGLONG)frames) + (LONGLONG)frames;
    auto* hb = (AuraHeartbeat*)hbView_;
    if (hb) {
        hb->seq = (uint32_t)seq;
        hb->framesTotal = (uint64_t)total;
        hb->lastNbs = frames;
    }
}

STDMETHODIMP_(UINT32) CAuraApo::CalcInputFrames(UINT32 outputFrames) {
    return outputFrames;
}

STDMETHODIMP_(UINT32) CAuraApo::CalcOutputFrames(UINT32 inputFrames) {
    return inputFrames;
}

// ---------------------------------------------------------------------------
// 心跳共享映射（LocalService + LPAC 穿透）
// ---------------------------------------------------------------------------
void CAuraApo::OpenHeartbeat() {
    CloseHeartbeat();
    // LocalService（audiodg）+ 任何用户进程可读写 + LPAC (S-1-15-2-1, S-1-15-2-2)
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GA;;;LS)(A;;GA;;;WD)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)", SDDL_REVISION_1,
            &sd, nullptr))
        return;
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = sd;
    sa.bInheritHandle = FALSE;

    const bool localHb = [] {
        char v[2] = {0};
        DWORD n = GetEnvironmentVariableA("AURAAPO_HEARTBEAT_LOCAL", v, 2);
        return n == 1 && v[0] == '1';
    }();
    const wchar_t* hbName = localHb ? L"Local\\AuraAPO_Heartbeat" : AURA_HEARTBEAT_MAP_NAME;
    HANDLE hMap = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0,
                                     (DWORD)sizeof(AuraHeartbeat), hbName);
    LocalFree(sd);
    if (!hMap) return;

    void* view = MapViewOfFile(hMap, FILE_MAP_WRITE, 0, 0, sizeof(AuraHeartbeat));
    if (!view) {
        CloseHandle(hMap);
        return;
    }
    auto* hb = (AuraHeartbeat*)view;
    hb->magic = AURA_HEARTBEAT_MAGIC;
    hb->version = AURA_HEARTBEAT_VERSION;
    hb->seq = 0;
    hb->sampleRate = rate_;
    hb->framesTotal = 0;
    hb->lastNbs = 0;
    hb->pid = GetCurrentProcessId();
    hMap_ = hMap;
    hbView_ = view;
}

void CAuraApo::CloseHeartbeat() {
    if (hbView_) {
        UnmapViewOfFile(hbView_);
        hbView_ = nullptr;
    }
    if (hMap_) {
        CloseHandle(hMap_);
        hMap_ = nullptr;
    }
}
