// AuraApo.h — 自研 System APO v1（透传 + 心跳 + RT-safe）。
//
// 架构参考：virtual-surround-sound / EqualizerAPO / tympan-apo。
// 彻底解决 COM 聚合与 CFG (Control Flow Guard) 规范性：
//   - Inner 派生自真正 IUnknown（非 reinterpret_cast 强转）；
//   - 全接口覆盖：IAudioProcessingObject / RT / Configuration / SystemEffects；
//   - 格式协商支持 float32 全采样率与多通道透传；
//   - 心跳共享内存支持 LocalService + LPAC (S-1-15-2-1, S-1-15-2-2) 全权限沙箱穿透。
#pragma once

#include <windows.h>
#include <audioenginebaseapo.h>
#include <ks.h>
#include <ksmedia.h>

#include <atomic>
#include <cstdint>

class CAuraApo : public IAudioProcessingObject,
                 public IAudioProcessingObjectRT,
                 public IAudioProcessingObjectConfiguration,
                 public IAudioSystemEffects {
 public:
    // audiodg 聚合感知：Inner 非委托 IUnknown 拥有对象身份与真实生命周期
    class Inner : public IUnknown {
     public:
        CAuraApo* self = nullptr;
        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
        STDMETHODIMP_(ULONG) AddRef() override;
        STDMETHODIMP_(ULONG) Release() override;
    };

    explicit CAuraApo(IUnknown* outer);
    virtual ~CAuraApo();

    // IUnknown（委托给 outer）
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // IAudioProcessingObject
    STDMETHODIMP Reset() override;
    STDMETHODIMP GetLatency(HNSTIME* pTime) override;
    STDMETHODIMP GetRegistrationProperties(APO_REG_PROPERTIES** ppRegProps) override;
    STDMETHODIMP Initialize(UINT32 cbDataSize, BYTE* pbyData) override;
    STDMETHODIMP IsInputFormatSupported(IAudioMediaType* pOppositeFormat,
                                        IAudioMediaType* pRequestedInputFormat,
                                        IAudioMediaType** ppSupportedInputFormat) override;
    STDMETHODIMP IsOutputFormatSupported(IAudioMediaType* pOppositeFormat,
                                         IAudioMediaType* pRequestedOutputFormat,
                                         IAudioMediaType** ppSupportedOutputFormat) override;
    STDMETHODIMP GetInputChannelCount(UINT32* pu32ChannelCount) override;

    // IAudioProcessingObjectConfiguration
    STDMETHODIMP LockForProcess(UINT32 numIn, APO_CONNECTION_DESCRIPTOR** in,
                                UINT32 numOut, APO_CONNECTION_DESCRIPTOR** out) override;
    STDMETHODIMP UnlockForProcess() override;

    // IAudioProcessingObjectRT（RT 实时音频线程：无锁、无堆分配、纯透传）
    STDMETHODIMP_(void) APOProcess(UINT32 numIn, APO_CONNECTION_PROPERTY** in,
                                   UINT32 numOut, APO_CONNECTION_PROPERTY** out) override;
    STDMETHODIMP_(UINT32) CalcInputFrames(UINT32 outputFrames) override;
    STDMETHODIMP_(UINT32) CalcOutputFrames(UINT32 inputFrames) override;

    Inner inner_;
    std::atomic<LONG> refs_{1};
    static long instCount;

 private:
    IUnknown* outer_ = nullptr;
    bool locked_ = false;
    UINT32 channels_ = 2;
    UINT32 rate_ = 48000;
    UINT32 blockAlign_ = 8;
    HANDLE hMap_ = nullptr;
    void* hbView_ = nullptr;
    volatile LONG seq_ = 0;
    volatile LONGLONG frames_ = 0;

    void OpenHeartbeat();
    void CloseHeartbeat();
    static bool IsFloat32Type(IAudioMediaType* type);
    static HRESULT CheckFormat(IAudioMediaType* opposite, IAudioMediaType* requested,
                               IAudioMediaType** supported);
};
