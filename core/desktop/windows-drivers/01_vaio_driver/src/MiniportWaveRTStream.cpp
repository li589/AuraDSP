/*++

Module Name:

    MiniportWaveRTStream.cpp

Abstract:

    See MiniportWaveRTStream.h.

--*/

#include "MiniportWaveRTStream.h"
#include "MiniportWaveRT.h"

CMiniportWaveRTStream::CMiniportWaveRTStream()
    : m_lRefCount(1)
    , m_pMiniport(NULL)
    , m_pPortStream(NULL)
    , m_ulPin(0)
    , m_bCapture(FALSE)
    , m_ulBytesPerSecond(0)
    , m_ulBlockAlign(0)
    , m_ulBufferSize(0)
    , m_pDmaBuffer(NULL)
    , m_KsState(KSSTATE_STOP)
{
    KeInitializeSpinLock(&m_PositionLock);
}

CMiniportWaveRTStream::~CMiniportWaveRTStream()
{
    //
    // The class driver is responsible for calling FreeAudioBuffer() before
    // dropping the stream, but be defensive: a buffer still mapped here would
    // otherwise leak its pages.
    //
    ASSERT(m_pDmaBuffer == NULL);
}

//=============================================================================
// IUnknown
//=============================================================================

STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::QueryInterface(
    _In_ REFIID InterfaceId,
    _COM_Outptr_ PVOID * Interface
    )
{
    if (Interface == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Interface = NULL;

    if (IsEqualGUIDAligned(InterfaceId, IID_IUnknown) ||
        IsEqualGUIDAligned(InterfaceId, IID_IMiniportWaveRTStream))
    {
        *Interface = PVOID(static_cast<IMiniportWaveRTStream *>(this));
        AddRef();
        return STATUS_SUCCESS;
    }

    return STATUS_NOT_SUPPORTED;
}

//=============================================================================
// Init
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
CMiniportWaveRTStream::Init(
    _In_ CMiniportWaveRT *   Miniport,
    _In_ PPORTWAVERTSTREAM   PortStream,
    _In_ ULONG               Pin,
    _In_ BOOLEAN             Capture,
    _In_ PKSDATAFORMAT       DataFormat
    )
{
    PAGED_CODE();

    if (Miniport == NULL || PortStream == NULL || DataFormat == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // This increment only implements the render (playback) direction.
    //
    if (Capture)
    {
        return STATUS_NOT_SUPPORTED;
    }

    if (DataFormat->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX))
    {
        return STATUS_INVALID_PARAMETER;
    }

    {
        PWAVEFORMATEX wfx = reinterpret_cast<PWAVEFORMATEX>(
                                reinterpret_cast<PBYTE>(DataFormat) + sizeof(KSDATAFORMAT));

        if (wfx->nBlockAlign == 0 || wfx->nAvgBytesPerSec == 0)
        {
            return STATUS_INVALID_PARAMETER;
        }

        m_ulBlockAlign      = wfx->nBlockAlign;
        m_ulBytesPerSecond  = wfx->nAvgBytesPerSec;
    }

    m_pMiniport   = Miniport;
    m_pPortStream = PortStream;
    m_ulPin       = Pin;
    m_bCapture    = Capture;
    m_KsState     = KSSTATE_STOP;

    m_Clock.SetQpcFrequency(Miniport->GetQpcFrequency());
    m_Clock.Reset();

    AURA_TRACE("stream created: pin=%u, %u B/s, blockAlign=%u",
               Pin, m_ulBytesPerSecond, m_ulBlockAlign);

    return STATUS_SUCCESS;
}

//=============================================================================
// IMiniportWaveRTStream
//=============================================================================

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::SetFormat(
    _In_ PKSDATAFORMAT DataFormat
    )
{
    PAGED_CODE();

    if (DataFormat == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // A WaveRT stream's format is fixed when NewStream() creates it; the data
    // range negotiation already happened at the pin level.  Accept the request
    // (the class driver treats a failure here as fatal to the pin).
    //
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::SetState(
    _In_ KSSTATE State
    )
{
    NTSTATUS    ntStatus = STATUS_SUCCESS;
    LARGE_INTEGER qpc;

    switch (State)
    {
    case KSSTATE_STOP:
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Stop(qpc.QuadPart);
        m_Clock.Reset();
        break;

    case KSSTATE_ACQUIRE:
        //
        // Buffers are allocated by AllocateAudioBuffer(); nothing to do.
        //
        break;

    case KSSTATE_PAUSE:
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Stop(qpc.QuadPart);
        break;

    case KSSTATE_RUN:
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Start(qpc.QuadPart);
        break;

    default:
        ntStatus = STATUS_INVALID_PARAMETER;
        break;
    }

    if (NT_SUCCESS(ntStatus))
    {
        m_KsState = State;
    }

    return ntStatus;
}

STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::GetPosition(
    _Out_ PKSAUDIO_POSITION Position
    )
{
    KIRQL   oldIrql;
    LARGE_INTEGER qpc;

    if (Position == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    KeAcquireSpinLock(&m_PositionLock, &oldIrql);

    if (m_KsState == KSSTATE_RUN)
    {
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Advance((ULONGLONG)qpc.QuadPart, m_ulBytesPerSecond);
    }

    Position->PlayOffset  = m_Clock.PlayOffset();
    Position->WriteOffset = m_Clock.WriteOffset();

    KeReleaseSpinLock(&m_PositionLock, oldIrql);

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::AllocateAudioBuffer(
    _In_  ULONG                 RequestedSize,
    _Out_ PMDL *                AudioBufferMdl,
    _Out_ ULONG *               ActualSize,
    _Out_ ULONG *               OffsetFromFirstPage,
    _Out_ MEMORY_CACHING_TYPE * CacheType
    )
{
    PHYSICAL_ADDRESS    highAddress;
    PMDL                pBufferMdl;

    PAGED_CODE();

    if (AudioBufferMdl == NULL || ActualSize == NULL ||
        OffsetFromFirstPage == NULL || CacheType == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *AudioBufferMdl       = NULL;
    *ActualSize           = 0;
    *OffsetFromFirstPage  = 0;
    *CacheType            = MmCached;

    if (m_pPortStream == NULL || m_ulBlockAlign == 0)
    {
        return STATUS_INVALID_DEVICE_STATE;
    }

    if (RequestedSize < m_ulBlockAlign)
    {
        return STATUS_UNSUCCESSFUL;
    }

    //
    // WaveRT buffers must be an integral number of sample frames.
    //
    RequestedSize -= RequestedSize % m_ulBlockAlign;

    highAddress.HighPart = 0;
    highAddress.LowPart  = MAXULONG32;

    pBufferMdl = m_pPortStream->AllocatePagesForMdl(highAddress, RequestedSize);
    if (pBufferMdl == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    //
    // Map the pages so the miniport can touch the buffer.  Per the WaveRT
    // guidance, audio buffers must use a caching type that imposes no
    // platform-specific alignment requirements -- MmCached qualifies and is
    // what the WDK virtual-audio samples use.
    //
    m_pDmaBuffer = (BYTE *)m_pPortStream->MapAllocatedPages(pBufferMdl, MmCached);
    if (m_pDmaBuffer == NULL)
    {
        m_pPortStream->FreePagesFromMdl(pBufferMdl);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    m_ulBufferSize = RequestedSize;

    *AudioBufferMdl      = pBufferMdl;
    *ActualSize          = RequestedSize;
    *OffsetFromFirstPage = 0;
    *CacheType           = MmCached;

    AURA_TRACE("audio buffer allocated: %u bytes", RequestedSize);

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(VOID)
CMiniportWaveRTStream::FreeAudioBuffer(
    _In_opt_ PMDL   AudioBufferMdl,
    _In_     ULONG  BufferSize
    )
{
    PAGED_CODE();

    UNREFERENCED_PARAMETER(BufferSize);

    if (AudioBufferMdl != NULL && m_pPortStream != NULL)
    {
        if (m_pDmaBuffer != NULL)
        {
            m_pPortStream->UnmapAllocatedPages(m_pDmaBuffer, AudioBufferMdl);
            m_pDmaBuffer = NULL;
        }

        m_pPortStream->FreePagesFromMdl(AudioBufferMdl);
    }

    m_ulBufferSize = 0;
    m_Clock.Reset();
}

#pragma code_seg("PAGE")
STDMETHODIMP_(VOID)
CMiniportWaveRTStream::GetHWLatency(
    _Out_ PKSRTAUDIO_HWLATENCY HwLatency
    )
{
    PAGED_CODE();

    if (HwLatency != NULL)
    {
        //
        // Purely virtual device: no codec, no FIFO, no chipset hop.
        //
        HwLatency->ChipsetDelay = 0;
        HwLatency->CodecDelay   = 0;
        HwLatency->FifoSize     = 0;
    }
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::GetPositionRegister(
    _Out_ PKSRTAUDIO_HWREGISTER Register
    )
{
    PAGED_CODE();

    UNREFERENCED_PARAMETER(Register);

    //
    // No memory-mapped position counter exists.  Not implemented => the port
    // driver falls back to IMiniportWaveRTStream::GetPosition().
    //
    return STATUS_NOT_IMPLEMENTED;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::GetClockRegister(
    _Out_ PKSRTAUDIO_HWREGISTER Register
    )
{
    PAGED_CODE();

    UNREFERENCED_PARAMETER(Register);

    return STATUS_NOT_IMPLEMENTED;
}
