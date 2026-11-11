// AuraApo.h — 自研 System APO（v1 透传 + 心跳；2026-11-10 立项 P2 起座位实例经 ApoEngineHost 真处理，其余实例与全部失败路径保持 v1 透传语义）。
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

#include "ApoEngineHost.h"

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
    // 真处理宿主（设计 P2）：抢不到座位/引擎不可用时恒惰性，
    // APOProcess 自动回落 v1 透传，行为不劣于现状。
    ApoEngineHost engine_;
    // 心跳计数直接原子累加进共享块（全面复审 S4 / APO-2），本实例
    // 不再持本地镜像（旧 seq_/frames_ 已删）。

    void OpenHeartbeat();
    void CloseHeartbeat();
    static bool IsFloat32Type(IAudioMediaType* type);
    static HRESULT CheckFormat(IAudioMediaType* opposite, IAudioMediaType* requested,
                               IAudioMediaType** supported);
};
