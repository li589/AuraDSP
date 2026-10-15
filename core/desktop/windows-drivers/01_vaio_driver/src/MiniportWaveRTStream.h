/*++

Module Name:

    MiniportWaveRTStream.h

Abstract:

    The AuraVAIO WaveRT stream object.

    WaveRT (Wave Real-Time) lets the audio engine share a ring buffer directly
    with the device: the driver allocates the buffer, maps it, and reports a
    byte position.  A virtual device has no DMA engine, so the position comes
    from CAuraVirtualClock, which derives it from the performance counter.

--*/

#ifndef _AURA_MINIPORT_WAVERT_STREAM_H_
#define _AURA_MINIPORT_WAVERT_STREAM_H_

#include "AuraVaio.h"
#include "VirtualClock.h"

class CMiniportWaveRT;

class CMiniportWaveRTStream : public IMiniportWaveRTStream
{
public:
    CMiniportWaveRTStream();
    virtual ~CMiniportWaveRTStream();

    // ---- IUnknown ----
    STDMETHODIMP_(NTSTATUS) QueryInterface(
        _In_  REFIID InterfaceId,
        _COM_Outptr_ PVOID * Interface
        );
    AURA_REFCOUNT_BOILERPLATE

    // ---- IMiniportWaveRTStream ----
    STDMETHODIMP_(NTSTATUS) SetFormat(
        _In_ PKSDATAFORMAT DataFormat
        );
    STDMETHODIMP_(NTSTATUS) SetState(
        _In_ KSSTATE State
        );
    STDMETHODIMP_(NTSTATUS) GetPosition(
        _Out_ PKSAUDIO_POSITION Position
        );
    STDMETHODIMP_(NTSTATUS) AllocateAudioBuffer(
        _In_  ULONG                 RequestedSize,
        _Out_ PMDL *                AudioBufferMdl,
        _Out_ ULONG *               ActualSize,
        _Out_ ULONG *               OffsetFromFirstPage,
        _Out_ MEMORY_CACHING_TYPE * CacheType
        );
    STDMETHODIMP_(VOID) FreeAudioBuffer(
        _In_opt_ PMDL   AudioBufferMdl,
        _In_     ULONG  BufferSize
        );
    STDMETHODIMP_(VOID) GetHWLatency(
        _Out_ PKSRTAUDIO_HWLATENCY HwLatency
        );
    STDMETHODIMP_(NTSTATUS) GetPositionRegister(
        _Out_ PKSRTAUDIO_HWREGISTER Register
        );
    STDMETHODIMP_(NTSTATUS) GetClockRegister(
        _Out_ PKSRTAUDIO_HWREGISTER Register
        );

    // ---- AuraVAIO ----
    NTSTATUS Init(
        _In_ CMiniportWaveRT *   Miniport,
        _In_ PPORTWAVERTSTREAM   PortStream,
        _In_ ULONG               Pin,
        _In_ BOOLEAN             Capture,
        _In_ PKSDATAFORMAT       DataFormat
        );

    BOOLEAN IsCapture() const { return m_bCapture; }
    ULONG   GetPin() const    { return m_ulPin; }

private:
    LONG                m_lRefCount;
    CMiniportWaveRT *   m_pMiniport;
    PPORTWAVERTSTREAM   m_pPortStream;

    ULONG               m_ulPin;
    BOOLEAN             m_bCapture;

    //
    // Format derived values (nAvgBytesPerSec / nBlockAlign of the negotiated
    // WAVEFORMATEX), plus the ring buffer we handed to the audio engine.
    //
    ULONG               m_ulBytesPerSecond;
    ULONG               m_ulBlockAlign;
    ULONG               m_ulBufferSize;
    BYTE *              m_pDmaBuffer;

    KSSTATE             m_KsState;
    KSPIN_LOCK          m_PositionLock;
    CAuraVirtualClock   m_Clock;
};

#endif // _AURA_MINIPORT_WAVERT_STREAM_H_
