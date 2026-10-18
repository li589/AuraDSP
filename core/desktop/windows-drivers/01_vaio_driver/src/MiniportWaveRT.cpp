/*++

Module Name:

    MiniportWaveRT.cpp

Abstract:

    See MiniportWaveRT.h.

--*/

#include "MiniportWaveRT.h"
#include "MiniportWaveRTStream.h"
#include "AuraVaoTables.h"
#include "ControlDevice.h"

CMiniportWaveRT::CMiniportWaveRT(
    _In_opt_ CAdapterCommon * AdapterCommon
    )
    : m_lRefCount(1)
    , m_pPort(NULL)
    , m_pAdapterCommon(AdapterCommon)
    , m_ullQpcFrequency(0)
{
    //
    // Cache the performance counter frequency once; CAuraVirtualClock needs it
    // to convert ticks into elapsed bytes.
    //
    {
        LARGE_INTEGER freq = { 0 };
        KeQueryPerformanceCounter(&freq);
        m_ullQpcFrequency = (ULONGLONG)freq.QuadPart;
    }
}

CMiniportWaveRT::~CMiniportWaveRT()
{
}

//=============================================================================
// IUnknown
//=============================================================================

STDMETHODIMP_(NTSTATUS)
CMiniportWaveRT::QueryInterface(
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
        IsEqualGUIDAligned(InterfaceId, IID_IMiniportWaveRT))
    {
        *Interface = PVOID(static_cast<IMiniportWaveRT *>(this));
        AddRef();
        return STATUS_SUCCESS;
    }

    return STATUS_NOT_SUPPORTED;
}

//=============================================================================
// IMiniport / IMiniportWaveRT
//=============================================================================

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRT::Init(
    _In_ PUNKNOWN      UnknownAdapter,
    _In_ PRESOURCELIST ResourceList,
    _In_ PPORTWAVERT   Port
    )
{
    PAGED_CODE();

    if (Port == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // The adapter common object is what PortCls passes for a subdevice's
    // adapter unknown; it is also the object our factory already received, so
    // prefer whichever is available.
    //
    UNREFERENCED_PARAMETER(UnknownAdapter);
    UNREFERENCED_PARAMETER(ResourceList);

    m_pPort = Port;

    AURA_TRACE("CMiniportWaveRT::Init (qpcFreq=%I64u)", m_ullQpcFrequency);

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRT::GetDescription(
    _Out_ PPCFILTER_DESCRIPTOR * Description
    )
{
    PAGED_CODE();

    if (Description == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Description = &AuraWaveMiniportFilterDescriptor;

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRT::DataRangeIntersection(
    _In_  ULONG        PinId,
    _In_  PKSDATARANGE ClientDataRange,
    _In_  PKSDATARANGE MyDataRange,
    _In_  ULONG        OutputBufferLength,
    _Out_writes_bytes_to_opt_(OutputBufferLength, *ResultantFormatLength)
          PVOID        ResultantFormat,
    _Out_ PULONG       ResultantFormatLength
    )
{
    PAGED_CODE();

    NTSTATUS ntStatus = STATUS_SUCCESS;
    AURA_INTERSECTION_LOG_ENTRY logEntry;
    RtlZeroMemory(&logEntry, sizeof(logEntry));
    logEntry.PinId = PinId;
    logEntry.OutputBufferLength = OutputBufferLength;
    if (ClientDataRange != NULL)
    {
        logEntry.FormatSize = ClientDataRange->FormatSize;
        logEntry.MajorFormat = ClientDataRange->MajorFormat;
        logEntry.SubFormat = ClientDataRange->SubFormat;
        logEntry.Specifier = ClientDataRange->Specifier;
        if (ClientDataRange->FormatSize >= sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE))
        {
            PKSDATAFORMAT_WAVEFORMATEXTENSIBLE c = (PKSDATAFORMAT_WAVEFORMATEXTENSIBLE)ClientDataRange;
            logEntry.ExtraChannels = c->WaveFormatExt.Format.nChannels;
            logEntry.ExtraBits = c->WaveFormatExt.Format.wBitsPerSample;
            logEntry.ExtraSampleRate = c->WaveFormatExt.Format.nSamplesPerSec;
            logEntry.ExtraChannelMask = c->WaveFormatExt.dwChannelMask;
            logEntry.ExtraSubFormat = c->WaveFormatExt.SubFormat;
        }
        else if (ClientDataRange->FormatSize >= sizeof(KSDATARANGE_AUDIO))
        {
            PKSDATARANGE_AUDIO c = (PKSDATARANGE_AUDIO)ClientDataRange;
            logEntry.ExtraChannels = c->MaximumChannels;
            logEntry.ExtraBits = c->MaximumBitsPerSample;
            logEntry.ExtraSampleRate = c->MaximumSampleFrequency;
        }
    }
    if (MyDataRange != NULL && MyDataRange->FormatSize >= sizeof(KSDATARANGE_AUDIO))
    {
        PKSDATARANGE_AUDIO m = (PKSDATARANGE_AUDIO)MyDataRange;
        logEntry.MyMaxChannels = m->MaximumChannels;
        logEntry.MyMaxBits = m->MaximumBitsPerSample;
        logEntry.MyMaxSampleRate = m->MaximumSampleFrequency;
        logEntry.MySubFormat = m->DataRange.SubFormat;
    }

#define RETURN_STATUS(s) do { ntStatus = (s); logEntry.Status = ntStatus; AuraControlDevice_LogIntersection(&logEntry); return ntStatus; } while (0)

    if (ClientDataRange == NULL || MyDataRange == NULL || ResultantFormatLength == NULL)
    {
        RETURN_STATUS(STATUS_INVALID_PARAMETER);
    }

    // Only host pins negotiate streaming formats
    if (PinId != KSPIN_WAVE_RENDER_SINK && PinId != KSPIN_WAVE_CAPTURE_SINK)
    {
        RETURN_STATUS(STATUS_NOT_IMPLEMENTED);
    }

    // Validate major format: AUDIO or WILDCARD
    if (!IsEqualGUIDAligned(ClientDataRange->MajorFormat, KSDATAFORMAT_TYPE_AUDIO) &&
        !IsEqualGUIDAligned(ClientDataRange->MajorFormat, KSDATAFORMAT_TYPE_WILDCARD))
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    // Validate specifier: WAVEFORMATEX or WILDCARD
    if (!IsEqualGUIDAligned(ClientDataRange->Specifier, KSDATAFORMAT_SPECIFIER_WAVEFORMATEX) &&
        !IsEqualGUIDAligned(ClientDataRange->Specifier, KSDATAFORMAT_SPECIFIER_WILDCARD))
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    PKSDATARANGE_AUDIO myAudioRange = (PKSDATARANGE_AUDIO)MyDataRange;

    GUID clientSubFormat = ClientDataRange->SubFormat;
    ULONG reqChannels = 0;
    ULONG reqBits = 0;
    ULONG reqSampleRate = 0;
    DWORD reqChannelMask = 0;
    BOOLEAN isExtensible = FALSE;

    if (ClientDataRange->FormatSize >= sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE))
    {
        PKSDATAFORMAT_WAVEFORMATEXTENSIBLE clientWfe = (PKSDATAFORMAT_WAVEFORMATEXTENSIBLE)ClientDataRange;
        reqChannels = clientWfe->WaveFormatExt.Format.nChannels;
        reqBits = clientWfe->WaveFormatExt.Format.wBitsPerSample;
        reqSampleRate = clientWfe->WaveFormatExt.Format.nSamplesPerSec;
        reqChannelMask = clientWfe->WaveFormatExt.dwChannelMask;

        if (clientWfe->WaveFormatExt.Format.wFormatTag == WAVE_FORMAT_EXTENSIBLE)
        {
            clientSubFormat = clientWfe->WaveFormatExt.SubFormat;
            isExtensible = TRUE;
        }
        else if (clientWfe->WaveFormatExt.Format.wFormatTag == WAVE_FORMAT_PCM)
        {
            clientSubFormat = KSDATAFORMAT_SUBTYPE_PCM;
            isExtensible = (reqChannels > 2);
        }
        else if (clientWfe->WaveFormatExt.Format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
        {
            clientSubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
            isExtensible = (reqChannels > 2);
        }
        else
        {
            isExtensible = (reqChannels > 2);
        }
    }
    else if (ClientDataRange->FormatSize == sizeof(KSDATAFORMAT_WAVEFORMATEX))
    {
        PKSDATAFORMAT_WAVEFORMATEX clientWfx = (PKSDATAFORMAT_WAVEFORMATEX)ClientDataRange;
        reqChannels = clientWfx->WaveFormatEx.nChannels;
        reqBits = clientWfx->WaveFormatEx.wBitsPerSample;
        reqSampleRate = clientWfx->WaveFormatEx.nSamplesPerSec;
        if (clientWfx->WaveFormatEx.wFormatTag == WAVE_FORMAT_PCM)
        {
            clientSubFormat = KSDATAFORMAT_SUBTYPE_PCM;
        }
        else if (clientWfx->WaveFormatEx.wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
        {
            clientSubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
        }
        isExtensible = (reqChannels > 2);
    }
    else if (ClientDataRange->FormatSize >= sizeof(KSDATARANGE_AUDIO))
    {
        PKSDATARANGE_AUDIO clientRange = (PKSDATARANGE_AUDIO)ClientDataRange;
        if (clientRange->MaximumChannels != myAudioRange->MaximumChannels)
        {
            RETURN_STATUS(STATUS_NO_MATCH);
        }
        reqChannels = myAudioRange->MaximumChannels;

        if (clientRange->MinimumSampleFrequency > myAudioRange->MaximumSampleFrequency ||
            clientRange->MaximumSampleFrequency < myAudioRange->MinimumSampleFrequency)
        {
            RETURN_STATUS(STATUS_NO_MATCH);
        }

        if (48000 >= clientRange->MinimumSampleFrequency && 48000 <= clientRange->MaximumSampleFrequency)
        {
            reqSampleRate = 48000;
        }
        else
        {
            reqSampleRate = (myAudioRange->MinimumSampleFrequency > clientRange->MinimumSampleFrequency) ?
                            myAudioRange->MinimumSampleFrequency : clientRange->MinimumSampleFrequency;
        }

        if (clientRange->MinimumBitsPerSample > myAudioRange->MaximumBitsPerSample ||
            clientRange->MaximumBitsPerSample < myAudioRange->MinimumBitsPerSample)
        {
            RETURN_STATUS(STATUS_NO_MATCH);
        }
        reqBits = myAudioRange->MaximumBitsPerSample;
        isExtensible = (reqChannels > 2);
    }
    else
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    if (IS_VALID_WAVEFORMATEX_GUID(&clientSubFormat))
    {
        USHORT tag = EXTRACT_WAVEFORMATEX_ID(&clientSubFormat);
        if (tag == WAVE_FORMAT_PCM) clientSubFormat = KSDATAFORMAT_SUBTYPE_PCM;
        else if (tag == WAVE_FORMAT_IEEE_FLOAT) clientSubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    }

    // Validate resolved subformat match against MyDataRange
    if (!IsEqualGUIDAligned(clientSubFormat, myAudioRange->DataRange.SubFormat) &&
        !IsEqualGUIDAligned(clientSubFormat, KSDATAFORMAT_SUBTYPE_WILDCARD))
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    if (reqChannels != myAudioRange->MaximumChannels)
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    if (reqBits < myAudioRange->MinimumBitsPerSample || reqBits > myAudioRange->MaximumBitsPerSample)
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    if (reqSampleRate < myAudioRange->MinimumSampleFrequency || reqSampleRate > myAudioRange->MaximumSampleFrequency)
    {
        RETURN_STATUS(STATUS_NO_MATCH);
    }

    if (reqChannelMask == 0)
    {
        switch (reqChannels)
        {
        case 1: reqChannelMask = KSAUDIO_SPEAKER_MONO; break;
        case 2: reqChannelMask = KSAUDIO_SPEAKER_STEREO; break;
        case 4: reqChannelMask = KSAUDIO_SPEAKER_QUAD; break;
        case 6: reqChannelMask = KSAUDIO_SPEAKER_5POINT1_SURROUND; break;
        case 8: reqChannelMask = KSAUDIO_SPEAKER_7POINT1_SURROUND; break;
        default: reqChannelMask = 0; break;
        }
    }

    ULONG requiredSize = isExtensible ? sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE) : sizeof(KSDATAFORMAT_WAVEFORMATEX);
    *ResultantFormatLength = requiredSize;

    if (OutputBufferLength == 0)
    {
        RETURN_STATUS(STATUS_BUFFER_OVERFLOW);
    }

    if (OutputBufferLength < requiredSize)
    {
        RETURN_STATUS(STATUS_BUFFER_TOO_SMALL);
    }

    if (ResultantFormat == NULL)
    {
        RETURN_STATUS(STATUS_INVALID_PARAMETER);
    }

    RtlZeroMemory(ResultantFormat, requiredSize);

    if (isExtensible)
    {
        PKSDATAFORMAT_WAVEFORMATEXTENSIBLE pWfe = (PKSDATAFORMAT_WAVEFORMATEXTENSIBLE)ResultantFormat;
        pWfe->DataFormat.FormatSize = sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE);
        pWfe->DataFormat.Flags = 0;
        pWfe->DataFormat.SampleSize = (ULONG)((reqChannels * reqBits) / 8);
        pWfe->DataFormat.Reserved = 0;
        pWfe->DataFormat.MajorFormat = KSDATAFORMAT_TYPE_AUDIO;
        pWfe->DataFormat.SubFormat = myAudioRange->DataRange.SubFormat;
        pWfe->DataFormat.Specifier = KSDATAFORMAT_SPECIFIER_WAVEFORMATEX;

        pWfe->WaveFormatExt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        pWfe->WaveFormatExt.Format.nChannels = (WORD)reqChannels;
        pWfe->WaveFormatExt.Format.nSamplesPerSec = reqSampleRate;
        pWfe->WaveFormatExt.Format.wBitsPerSample = (WORD)reqBits;
        pWfe->WaveFormatExt.Format.nBlockAlign = (WORD)((reqChannels * reqBits) / 8);
        pWfe->WaveFormatExt.Format.nAvgBytesPerSec = reqSampleRate * pWfe->WaveFormatExt.Format.nBlockAlign;
        pWfe->WaveFormatExt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
        pWfe->WaveFormatExt.Samples.wValidBitsPerSample = (WORD)reqBits;
        pWfe->WaveFormatExt.dwChannelMask = reqChannelMask;
        pWfe->WaveFormatExt.SubFormat = myAudioRange->DataRange.SubFormat;
    }
    else
    {
        PKSDATAFORMAT_WAVEFORMATEX pWfx = (PKSDATAFORMAT_WAVEFORMATEX)ResultantFormat;
        pWfx->DataFormat.FormatSize = sizeof(KSDATAFORMAT_WAVEFORMATEX);
        pWfx->DataFormat.Flags = 0;
        pWfx->DataFormat.SampleSize = (ULONG)((reqChannels * reqBits) / 8);
        pWfx->DataFormat.Reserved = 0;
        pWfx->DataFormat.MajorFormat = KSDATAFORMAT_TYPE_AUDIO;
        pWfx->DataFormat.SubFormat = myAudioRange->DataRange.SubFormat;
        pWfx->DataFormat.Specifier = KSDATAFORMAT_SPECIFIER_WAVEFORMATEX;

        pWfx->WaveFormatEx.wFormatTag = (WORD)(IsEqualGUIDAligned(myAudioRange->DataRange.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) ?
                                               WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM);
        pWfx->WaveFormatEx.nChannels = (WORD)reqChannels;
        pWfx->WaveFormatEx.nSamplesPerSec = reqSampleRate;
        pWfx->WaveFormatEx.wBitsPerSample = (WORD)reqBits;
        pWfx->WaveFormatEx.nBlockAlign = (WORD)((reqChannels * reqBits) / 8);
        pWfx->WaveFormatEx.nAvgBytesPerSec = reqSampleRate * pWfx->WaveFormatEx.nBlockAlign;
        pWfx->WaveFormatEx.cbSize = 0;
    }

#undef RETURN_STATUS
    logEntry.Status = STATUS_SUCCESS;
    AuraControlDevice_LogIntersection(&logEntry);
    return STATUS_SUCCESS;
}

#pragma code_seg()
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRT::GetDeviceDescription(
    _Out_ PDEVICE_DESCRIPTION DeviceDescription
    )
{
    if (DeviceDescription == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    RtlZeroMemory(DeviceDescription, sizeof(*DeviceDescription));

    //
    // AuraVAIO has no DMA engine; these values keep the class driver happy
    // without implying any real bus mastering.
    //
    DeviceDescription->Master              = TRUE;
    DeviceDescription->ScatterGather       = TRUE;
    DeviceDescription->Dma32BitAddresses   = TRUE;
    DeviceDescription->InterfaceType       = PCIBus;
    DeviceDescription->MaximumLength       = 0xFFFFFFFF;

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRT::NewStream(
    _Out_ PMINIPORTWAVERTSTREAM * Stream,
    _In_  PPORTWAVERTSTREAM       PortStream,
    _In_  ULONG                   Pin,
    _In_  BOOLEAN                 Capture,
    _In_  PKSDATAFORMAT           DataFormat
    )
{
    NTSTATUS                ntStatus = STATUS_SUCCESS;
    CMiniportWaveRTStream * pStream  = NULL;

    PAGED_CODE();

    if (Stream == NULL || PortStream == NULL || DataFormat == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Stream = NULL;

    if (Pin != KSPIN_WAVE_RENDER_SINK && Pin != KSPIN_WAVE_CAPTURE_SINK)
    {
        AURA_TRACE("NewStream on unsupported pin %u", Pin);
        return STATUS_NOT_SUPPORTED;
    }

    //
    // Note: we intentionally keep no stream count here.  The pin descriptor
    // advertises MaxGlobalInstanceCount = 1, so PortCls already guarantees a
    // single live stream -- and a count we never decremented would wedge the
    // endpoint after the first open/close cycle.
    //
    pStream = new (POOL_FLAG_NON_PAGED, AURA_POOLTAG) CMiniportWaveRTStream();
    if (pStream == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    ntStatus = pStream->Init(this, PortStream, Pin, Capture, DataFormat);
    if (!NT_SUCCESS(ntStatus))
    {
        //
        // Release() drops the construction reference, destroying the object.
        //
        pStream->Release();
        return ntStatus;
    }

    //
    // The caller takes ownership of the single construction reference.
    //
    *Stream = static_cast<IMiniportWaveRTStream *>(pStream);

    return STATUS_SUCCESS;
}

//=============================================================================
// Factory
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
CreateMiniportWaveRT(
    _Outptr_ PUNKNOWN *         OutMiniport,
    _In_     REFCLSID           MiniportClassId,
    _In_opt_ PUNKNOWN           OuterUnknown,
    _In_     POOL_FLAGS         PoolFlags,
    _In_opt_ CAdapterCommon *   AdapterCommon,
    _In_opt_ PVOID              MiniportContext
    )
{
    CMiniportWaveRT * pMiniport;

    PAGED_CODE();

    UNREFERENCED_PARAMETER(MiniportClassId);
    UNREFERENCED_PARAMETER(OuterUnknown);
    UNREFERENCED_PARAMETER(MiniportContext);

    if (OutMiniport == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *OutMiniport = NULL;

    pMiniport = new (PoolFlags, AURA_POOLTAG) CMiniportWaveRT(AdapterCommon);
    if (pMiniport == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    *OutMiniport = PUNKNOWN(static_cast<IMiniportWaveRT *>(pMiniport));

    return STATUS_SUCCESS;
}
