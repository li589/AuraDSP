// AuraApo.h — 自研 APO v1（透传 + 心跳；无 DSP）。
//
// COM 骨架模式对标 EAPO（CBaseAudioProcessingObject + 裸 COM 聚合 + 自注册），
// 实现全部 clean-room 重写。v1 语义：
//  - 格式全接受（SPEC 宽容协商；透传与格式无关，按字节搬运）；
//  - APOProcess 按连接对 memcpy，SILENT 输入则零输出+SILENT 标志（防垃圾爆音）；
//  - 心跳映射每块 seq++/framesTotal+=n（LocalService 可写的开放 DACL）。
// 聚合（pUnkOuter + NonDelegating）是 EAPO 同式：audiodg 可能聚合创建，缺了静默拒载。
#pragma once

#include <audioenginebaseapo.h>
#include <baseaudioprocessingobject.h>

#include <atomic>
#include <cstdint>
#include <windows.h>

class INonDelegatingUnknown {
    virtual HRESULT __stdcall NonDelegatingQueryInterface(REFIID iid, void** ppv) = 0;
    virtual ULONG __stdcall NonDelegatingAddRef() = 0;
    virtual ULONG __stdcall NonDelegatingRelease() = 0;
};

class CAuraApo : public CBaseAudioProcessingObject,
                 public IAudioSystemEffects,
                 public INonDelegatingUnknown {
 public:
    CAuraApo(IUnknown* pUnkOuter);
    virtual ~CAuraApo();

    // IUnknown（聚合感知）
    virtual HRESULT __stdcall QueryInterface(REFIID iid, void** ppv) override;
    virtual ULONG __stdcall AddRef() override;
    virtual ULONG __stdcall Release() override;

    // IAudioProcessingObject（宽容版，其余走基类默认）
    virtual HRESULT __stdcall GetLatency(HNSTIME* pTime) override;
    virtual HRESULT __stdcall Initialize(UINT32 cbDataSize, BYTE* pbyData) override;
    virtual HRESULT __stdcall IsInputFormatSupported(
        IAudioMediaType* pOutputFormat, IAudioMediaType* pRequestedInputFormat,
        IAudioMediaType** ppSupportedInputFormat) override;
    virtual HRESULT __stdcall IsOutputFormatSupported(
        IAudioMediaType* pInputFormat, IAudioMediaType* pRequestedOutputFormat,
        IAudioMediaType** ppSupportedOutputFormat) override;

    // IAudioProcessingObjectConfiguration
    virtual HRESULT __stdcall LockForProcess(
        UINT32 nIn, APO_CONNECTION_DESCRIPTOR** ppIn, UINT32 nOut,
        APO_CONNECTION_DESCRIPTOR** ppOut) override;
    virtual HRESULT __stdcall UnlockForProcess() override;

    // IAudioProcessingObjectRT（纯虚，v1=透传+心跳）
    virtual void __stdcall APOProcess(
        UINT32 nIn, APO_CONNECTION_PROPERTY** ppIn, UINT32 nOut,
        APO_CONNECTION_PROPERTY** ppOut) override;

    // INonDelegatingUnknown
    virtual HRESULT __stdcall NonDelegatingQueryInterface(REFIID iid, void** ppv) override;
    virtual ULONG __stdcall NonDelegatingAddRef() override;
    virtual ULONG __stdcall NonDelegatingRelease() override;

    static long instCount;
    static const CRegAPOProperties<1> regEfxProperties;

 private:
    long m_ref = 1;
    IUnknown* m_outer = nullptr;  // 非拥有（聚合外层）
    UINT32 m_blockAlign[8] = {};  // 每连接字节/帧（Lock 时快照，最多 8 连接）
    UINT32 m_nConn = 0;
    HANDLE m_hMap = nullptr;       // 心跳映射（Lock 建，Unlock 关）
    void* m_hbView = nullptr;      // 映射视图（RT 只写 seq/frames/lastNbs）
    volatile LONG m_seq = 0;
    volatile LONGLONG m_frames = 0;
    UINT32 m_sampleRate = 0;

    void CloseHeartbeat();
    bool OpenHeartbeat();
};
