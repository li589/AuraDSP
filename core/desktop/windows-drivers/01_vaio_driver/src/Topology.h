/*++

Module Name:

    Topology.h

Abstract:

    The AuraVAIO topology miniport (IMiniportTopology).

    A render endpoint needs two KS filters: a WaveRT filter (the byte stream)
    and a topology filter (the "device" side).  This increment's topology is
    deliberately empty -- one bridge pin feeding one speaker pin, no nodes --
    so the endpoint is formed without any mixer property surface.  Volume /
    mute / peak-meter nodes and their KSPROPSETID_Audio handlers are a
    follow-up increment.

--*/

#ifndef _AURA_TOPOLOGY_H_
#define _AURA_TOPOLOGY_H_

#include "AuraVaio.h"
#include "AdapterCommon.h"

class CMiniportTopology : public IMiniportTopology
{
public:
    explicit CMiniportTopology(_In_opt_ CAdapterCommon * AdapterCommon);
    virtual ~CMiniportTopology();

    // ---- IUnknown ----
    STDMETHODIMP_(NTSTATUS) QueryInterface(
        _In_  REFIID InterfaceId,
        _COM_Outptr_ PVOID * Interface
        );
    AURA_REFCOUNT_BOILERPLATE

    // ---- IMiniportTopology ----
    STDMETHODIMP_(NTSTATUS) Init(
        _In_ PUNKNOWN        UnknownAdapter,
        _In_ PRESOURCELIST   ResourceList,
        _In_ PPORTTOPOLOGY   Port
        );

    // ---- IMiniport ----
    STDMETHODIMP_(NTSTATUS) GetDescription(
        _Out_ PPCFILTER_DESCRIPTOR * Description
        );
    STDMETHODIMP_(NTSTATUS) DataRangeIntersection(
        _In_  ULONG        PinId,
        _In_  PKSDATARANGE ClientDataRange,
        _In_  PKSDATARANGE MyDataRange,
        _In_  ULONG        OutputBufferLength,
        _Out_writes_bytes_to_opt_(OutputBufferLength, *ResultantFormatLength)
              PVOID        ResultantFormat,
        _Out_ PULONG       ResultantFormatLength
        );

    // ---- AuraVAIO ----
    CAdapterCommon * GetAdapterCommon() const { return m_pAdapterCommon; }

    ULONG GetChannelConfig() const { return m_ulChannelConfig; }
    void  SetChannelConfig(ULONG ulConfig) { m_ulChannelConfig = ulConfig; }

private:
    LONG                m_lRefCount;
    PPORTTOPOLOGY       m_pPort;
    CAdapterCommon *    m_pAdapterCommon;
    ULONG               m_ulChannelConfig;
};

//
// Factory used by CAdapterCommon::InstallSubdevice().
//
NTSTATUS
CreateMiniportTopology(
    _Outptr_ PUNKNOWN *         OutMiniport,
    _In_     REFCLSID           MiniportClassId,
    _In_opt_ PUNKNOWN           OuterUnknown,
    _In_     POOL_FLAGS         PoolFlags,
    _In_opt_ CAdapterCommon *   AdapterCommon,
    _In_opt_ PVOID              MiniportContext
    );

#endif // _AURA_TOPOLOGY_H_
