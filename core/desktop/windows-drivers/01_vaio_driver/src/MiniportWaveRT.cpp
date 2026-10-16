/*++

Module Name:

    MiniportWaveRT.cpp

Abstract:

    See MiniportWaveRT.h.

--*/

#include "MiniportWaveRT.h"
#include "MiniportWaveRTStream.h"
#include "AuraVaoTables.h"

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
    ULONG   requiredSize;

    PAGED_CODE();

    UNREFERENCED_PARAMETER(PinId);
    UNREFERENCED_PARAMETER(ResultantFormat);

    if (ClientDataRange == NULL || MyDataRange == NULL ||
        ResultantFormatLength == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (!IsEqualGUIDAligned(ClientDataRange->Specifier,
                            KSDATAFORMAT_SPECIFIER_WAVEFORMATEX))
    {
        return STATUS_NOT_IMPLEMENTED;
    }

    requiredSize = sizeof(KSDATAFORMAT_WAVEFORMATEX);

    if (OutputBufferLength == 0)
    {
        *ResultantFormatLength = requiredSize;
        return STATUS_BUFFER_OVERFLOW;
    }

    if (OutputBufferLength < requiredSize)
    {
        return STATUS_BUFFER_TOO_SMALL;
    }

    //
    // Each of our data ranges is per-channel-count, so require an exact match
    // on the channel count and let the class handler compute the rest.
    //
    if (((PKSDATARANGE_AUDIO)MyDataRange)->MaximumChannels !=
        ((PKSDATARANGE_AUDIO)ClientDataRange)->MaximumChannels)
    {
        return STATUS_NO_MATCH;
    }

    return STATUS_NOT_IMPLEMENTED;
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
