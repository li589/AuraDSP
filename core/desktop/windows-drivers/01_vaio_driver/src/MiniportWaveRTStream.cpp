/*++

Module Name:

    MiniportWaveRTStream.cpp

Abstract:

    See MiniportWaveRTStream.h.

--*/

#include "MiniportWaveRTStream.h"
#include "MiniportWaveRT.h"
#include "ControlDevice.h"

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
    if (m_KsState == KSSTATE_RUN)
    {
        AuraControlDevice_OnStreamStateChange(m_bCapture, KSSTATE_STOP);
        // VAIO-3：运行中析构同为 RUN 离开边沿，计数须同步回落。
        AuraControlDevice_OnStreamRunEdge(m_bCapture, FALSE);
    }

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

        AuraControlDevice_OnFormatChange(Capture, wfx->nSamplesPerSec, wfx->nChannels, wfx->wBitsPerSample);
    }

    m_pMiniport   = Miniport;
    m_pPortStream = PortStream;
    m_ulPin       = Pin;
    m_bCapture    = Capture;
    m_KsState     = KSSTATE_STOP;

    m_Clock.SetQpcFrequency(Miniport->GetQpcFrequency());
    m_Clock.Reset();

    AURA_TRACE("stream created: pin=%u (capture=%u), %u B/s, blockAlign=%u",
               Pin, Capture, m_ulBytesPerSecond, m_ulBlockAlign);

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

    if (DataFormat->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX))
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // A WaveRT stream's format is normally fixed when NewStream() creates
    // it, but the audio engine can also renegotiate in place on a running
    // stream.  Mirror Init(): record the new geometry and publish it to
    // the shared ring header.  Without this, an in-place change leaves
    // the header (and therefore the bridge pump) describing the old
    // format while the stream already writes the new one — the pump
    // then misreads the ring indefinitely (round-7 item 6).  Still
    // accept every well-formed request (the class driver treats a
    // failure here as fatal to the pin).
    //
    {
        PWAVEFORMATEX wfx = reinterpret_cast<PWAVEFORMATEX>(
                                reinterpret_cast<PBYTE>(DataFormat) + sizeof(KSDATAFORMAT));

        if (wfx->nBlockAlign == 0 || wfx->nAvgBytesPerSec == 0)
        {
            return STATUS_INVALID_PARAMETER;
        }

        m_ulBlockAlign      = wfx->nBlockAlign;
        m_ulBytesPerSecond  = wfx->nAvgBytesPerSec;

        // 白噪声专项 S3（2026-11-12）：换格式不重置时钟偏移——
        // 偏移的绝对相位无意义（桥按 WO/TW 锚相对读取、引擎按
        // 上报位置重同步），毒性只来自非帧倍数的丢弃/重复；此后
        // Advance 按新帧格量化推进、拷贝窗口保持连续，钳制丢弃
        // 量由 AdvanceAndCopyLocked 贴帧保证。旧格式尾部数据由
        // 桥的几何重同步丢弃，不在此处理。

        AuraControlDevice_OnFormatChange(m_bCapture, wfx->nSamplesPerSec, wfx->nChannels, wfx->wBitsPerSample);
    }

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
        // 全面复审 S5（VAIO-2）：停钟前先把自上次 GetPosition 以来
        // 已播放但未搬运的尾段刷进/出共享环——此前直接 Stop+Reset
        // 令这段音频静默丢失（停播尾截断）。
        if (m_KsState == KSSTATE_RUN)
        {
            KIRQL oldIrql;
            KeAcquireSpinLock(&m_PositionLock, &oldIrql);
            qpc = KeQueryPerformanceCounter(NULL);
            AdvanceAndCopyLocked((ULONGLONG)qpc.QuadPart);
            KeReleaseSpinLock(&m_PositionLock, oldIrql);
        }
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Stop(qpc.QuadPart);
        m_Clock.Reset();
        AuraControlDevice_OnStreamStateChange(m_bCapture, State);
        break;

    case KSSTATE_ACQUIRE:
        //
        // Buffers are allocated by AllocateAudioBuffer(); nothing to do.
        //
        AuraControlDevice_OnStreamStateChange(m_bCapture, State);
        break;

    case KSSTATE_PAUSE:
        // 同 STOP：暂停前刷尾段（时钟同样停走）。
        if (m_KsState == KSSTATE_RUN)
        {
            KIRQL oldIrql;
            KeAcquireSpinLock(&m_PositionLock, &oldIrql);
            qpc = KeQueryPerformanceCounter(NULL);
            AdvanceAndCopyLocked((ULONGLONG)qpc.QuadPart);
            KeReleaseSpinLock(&m_PositionLock, oldIrql);
        }
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Stop(qpc.QuadPart);
        AuraControlDevice_OnStreamStateChange(m_bCapture, State);
        break;

    case KSSTATE_RUN:
        qpc = KeQueryPerformanceCounter(NULL);
        m_Clock.Start(qpc.QuadPart);
        AuraControlDevice_OnStreamStateChange(m_bCapture, State);
        break;

    default:
        ntStatus = STATUS_INVALID_PARAMETER;
        break;
    }

    if (NT_SUCCESS(ntStatus))
    {
        // 全面复审 S5（VAIO-3）：活跃流计数只在 RUN 边沿增减——
        // 此前 OnStreamStateChange 按调用计数，RUN→PAUSE→RUN
        // 重复加、PAUSE→STOP 凭空减，计数与真实在跑流数漂移。
        const BOOLEAN wasRunning = (m_KsState == KSSTATE_RUN);
        const BOOLEAN nowRunning = (State == KSSTATE_RUN);
        if (wasRunning != nowRunning)
        {
            AuraControlDevice_OnStreamRunEdge(m_bCapture, nowRunning);
        }
        m_KsState = State;
    }

    return ntStatus;
}

void
CMiniportWaveRTStream::AdvanceAndCopyLocked(
    _In_ ULONGLONG QpcNow
    )
{
    ULONGLONG oldPlay = m_Clock.PlayOffset();
    ULONG bytesAdvanced = m_Clock.Advance(QpcNow, m_ulBytesPerSecond, m_ulBlockAlign);

    if (bytesAdvanced == 0 || m_pDmaBuffer == NULL || m_ulBufferSize == 0)
    {
        return;
    }

    ULONG bytesToProcess = bytesAdvanced;
    ULONGLONG startPlay = oldPlay;
    if (bytesAdvanced > m_ulBufferSize)
    {
        // 全面复审 S5（VAIO-2）：停滞超过一整缓冲时只搬最近一缓冲
        // 的内容，起点须随之前移 (oldPlay + advanced - size)——
        // 此前仍从 oldPlay 起搬，窗口与播放位置错位 (advanced -
        // size) 字节且永不自愈（与第七轮桥侧模偏移同类病）。
        // 白噪声专项 S3（2026-11-12）：丢弃量 = advanced - toProcess
        // 必须为帧倍数，否则环字节流被旋转出帧格（见 VirtualClock
        // 帧量化注释）。时钟量化后 advanced 已是帧倍数；此处再把
        // toProcess 向下贴到帧倍数，使钳制不依赖缓冲大小的来源
        // （缓冲按分配时点的 BlockAlign 取整，运行中换格式后
        // 未必仍是现行帧格的倍数）。
        bytesToProcess = m_ulBufferSize;
        if (m_ulBlockAlign > 1)
        {
            bytesToProcess -= bytesToProcess % m_ulBlockAlign;
            if (bytesToProcess == 0)
            {
                return;
            }
        }
        startPlay = oldPlay + (bytesAdvanced - bytesToProcess);
    }
    ULONG startOffset = (ULONG)(startPlay % m_ulBufferSize);
    ULONG chunk1 = m_ulBufferSize - startOffset;

    if (!m_bCapture)
    {
        // Render: copy played audio from DMA buffer into shared ring buffer
        if (chunk1 >= bytesToProcess)
        {
            AuraControlDevice_WriteRenderSamples(m_pDmaBuffer + startOffset, bytesToProcess);
        }
        else
        {
            AuraControlDevice_WriteRenderSamples(m_pDmaBuffer + startOffset, chunk1);
            AuraControlDevice_WriteRenderSamples(m_pDmaBuffer, bytesToProcess - chunk1);
        }
    }
    else
    {
        // Capture: read captured audio from shared ring buffer into DMA buffer
        if (chunk1 >= bytesToProcess)
        {
            AuraControlDevice_ReadCaptureSamples(m_pDmaBuffer + startOffset, bytesToProcess);
        }
        else
        {
            AuraControlDevice_ReadCaptureSamples(m_pDmaBuffer + startOffset, chunk1);
            AuraControlDevice_ReadCaptureSamples(m_pDmaBuffer, bytesToProcess - chunk1);
        }
    }
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
        AdvanceAndCopyLocked((ULONGLONG)qpc.QuadPart);
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
