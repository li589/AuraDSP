/*++

Module Name:

    Topology.cpp

Abstract:

    See Topology.h.

--*/

#include "Topology.h"
#include "AuraVaoTables.h"

CMiniportTopology::CMiniportTopology(
    _In_opt_ CAdapterCommon * AdapterCommon
    )
    : m_lRefCount(1)
    , m_pPort(NULL)
    , m_pAdapterCommon(AdapterCommon)
    , m_ulChannelConfig(KSAUDIO_SPEAKER_7POINT1_SURROUND)
{
}

CMiniportTopology::~CMiniportTopology()
{
}

//=============================================================================
// IUnknown
//=============================================================================

STDMETHODIMP_(NTSTATUS)
CMiniportTopology::QueryInterface(
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
        IsEqualGUIDAligned(InterfaceId, IID_IMiniportTopology))
    {
        *Interface = PVOID(static_cast<IMiniportTopology *>(this));
        AddRef();
        return STATUS_SUCCESS;
    }

    return STATUS_NOT_SUPPORTED;
}

//=============================================================================
// IMiniportTopology / IMiniport
//=============================================================================

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportTopology::Init(
    _In_ PUNKNOWN        UnknownAdapter,
    _In_ PRESOURCELIST   ResourceList,
    _In_ PPORTTOPOLOGY   Port
    )
{
    PAGED_CODE();

    UNREFERENCED_PARAMETER(UnknownAdapter);
    UNREFERENCED_PARAMETER(ResourceList);

    if (Port == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    m_pPort = Port;

    AURA_TRACE("CMiniportTopology::Init");

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportTopology::GetDescription(
    _Out_ PPCFILTER_DESCRIPTOR * Description
    )
{
    PAGED_CODE();

    if (Description == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Description = &AuraTopoMiniportFilterDescriptor;

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportTopology::DataRangeIntersection(
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

    UNREFERENCED_PARAMETER(PinId);
    UNREFERENCED_PARAMETER(MyDataRange);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ResultantFormat);

    if (ClientDataRange == NULL || ResultantFormatLength == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *ResultantFormatLength = 0;

    //
    // Topology pins carry an analogue (specifier NONE) range; hand the
    // intersection back to the class handler.
    //
    return STATUS_NOT_IMPLEMENTED;
}

//=============================================================================
// Factory
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
CreateMiniportTopology(
    _Outptr_ PUNKNOWN *         OutMiniport,
    _In_     REFCLSID           MiniportClassId,
    _In_opt_ PUNKNOWN           OuterUnknown,
    _In_     POOL_FLAGS         PoolFlags,
    _In_opt_ CAdapterCommon *   AdapterCommon,
    _In_opt_ PVOID              MiniportContext
    )
{
    CMiniportTopology * pMiniport;

    PAGED_CODE();

    UNREFERENCED_PARAMETER(MiniportClassId);
    UNREFERENCED_PARAMETER(OuterUnknown);
    UNREFERENCED_PARAMETER(MiniportContext);

    if (OutMiniport == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *OutMiniport = NULL;

    pMiniport = new (PoolFlags, AURA_POOLTAG) CMiniportTopology(AdapterCommon);
    if (pMiniport == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    *OutMiniport = PUNKNOWN(static_cast<IMiniportTopology *>(pMiniport));

    return STATUS_SUCCESS;
}

//=============================================================================
// Property Handlers
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
PropertyHandler_ChannelConfig(
    _In_ PPCPROPERTY_REQUEST PropertyRequest
    )
{
    PAGED_CODE();

    if (PropertyRequest == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    CMiniportTopology * pTopology = NULL;
    if (PropertyRequest->MajorTarget != NULL)
    {
        pTopology = static_cast<CMiniportTopology *>(
            static_cast<IMiniportTopology *>(PropertyRequest->MajorTarget));
    }

    if (pTopology == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (PropertyRequest->Verb & KSPROPERTY_TYPE_BASICSUPPORT)
    {
        if (PropertyRequest->ValueSize >= sizeof(KSPROPERTY_DESCRIPTION))
        {
            PKSPROPERTY_DESCRIPTION desc = (PKSPROPERTY_DESCRIPTION)PropertyRequest->Value;
            RtlZeroMemory(desc, sizeof(KSPROPERTY_DESCRIPTION));
            desc->AccessFlags = KSPROPERTY_TYPE_GET | KSPROPERTY_TYPE_SET | KSPROPERTY_TYPE_BASICSUPPORT;
            desc->DescriptionSize = sizeof(KSPROPERTY_DESCRIPTION);
            desc->PropTypeSet.Set = KSPROPTYPESETID_General;
            desc->PropTypeSet.Id = VT_UI4;
            desc->PropTypeSet.Flags = 0;
            desc->MembersListCount = 0;
            desc->Reserved = 0;
            PropertyRequest->ValueSize = sizeof(KSPROPERTY_DESCRIPTION);
            return STATUS_SUCCESS;
        }
        else if (PropertyRequest->ValueSize >= sizeof(ULONG))
        {
            *(PULONG)PropertyRequest->Value = KSPROPERTY_TYPE_GET | KSPROPERTY_TYPE_SET | KSPROPERTY_TYPE_BASICSUPPORT;
            PropertyRequest->ValueSize = sizeof(ULONG);
            return STATUS_SUCCESS;
        }
        else
        {
            PropertyRequest->ValueSize = sizeof(ULONG);
            return STATUS_BUFFER_TOO_SMALL;
        }
    }
    else if (PropertyRequest->Verb & KSPROPERTY_TYPE_GET)
    {
        if (PropertyRequest->ValueSize < sizeof(KSAUDIO_CHANNEL_CONFIG))
        {
            PropertyRequest->ValueSize = sizeof(KSAUDIO_CHANNEL_CONFIG);
            return STATUS_BUFFER_TOO_SMALL;
        }

        PKSAUDIO_CHANNEL_CONFIG pConfig = (PKSAUDIO_CHANNEL_CONFIG)PropertyRequest->Value;
        pConfig->ActiveSpeakerPositions = pTopology->GetChannelConfig();
        PropertyRequest->ValueSize = sizeof(KSAUDIO_CHANNEL_CONFIG);
        return STATUS_SUCCESS;
    }
    else if (PropertyRequest->Verb & KSPROPERTY_TYPE_SET)
    {
        if (PropertyRequest->ValueSize < sizeof(KSAUDIO_CHANNEL_CONFIG))
        {
            return STATUS_BUFFER_TOO_SMALL;
        }

        PKSAUDIO_CHANNEL_CONFIG pConfig = (PKSAUDIO_CHANNEL_CONFIG)PropertyRequest->Value;
        pTopology->SetChannelConfig(pConfig->ActiveSpeakerPositions);
        AURA_TRACE("ChannelConfig set to 0x%08X", pConfig->ActiveSpeakerPositions);
        return STATUS_SUCCESS;
    }

    return STATUS_NOT_SUPPORTED;
}
