/*++

Module Name:

    MiniportWaveRT.h

Abstract:

    The AuraVAIO WaveRT miniport (IMiniportWaveRT).

    Its job is narrow: hand PortCls the filter descriptor, create one stream
    object per pin instantiation, and describe the (virtual) device.

--*/

#ifndef _AURA_MINIPORT_WAVERT_H_
#define _AURA_MINIPORT_WAVERT_H_

#include "AuraVaio.h"
#include "AdapterCommon.h"

class CMiniportWaveRT : public IMiniportWaveRT
{
public:
    explicit CMiniportWaveRT(_In_opt_ CAdapterCommon * AdapterCommon);
    virtual ~CMiniportWaveRT();

    // ---- IUnknown ----
    STDMETHODIMP_(NTSTATUS) QueryInterface(
        _In_  REFIID InterfaceId,
        _COM_Outptr_ PVOID * Interface
        );
    AURA_REFCOUNT_BOILERPLATE

    // ---- IMiniportWaveRT ----
    STDMETHODIMP_(NTSTATUS) Init(
        _In_ PUNKNOWN      UnknownAdapter,
        _In_ PRESOURCELIST ResourceList,
        _In_ PPORTWAVERT   Port
        );
    STDMETHODIMP_(NTSTATUS) NewStream(
        _Out_ PMINIPORTWAVERTSTREAM * Stream,
        _In_  PPORTWAVERTSTREAM       PortStream,
        _In_  ULONG                   Pin,
        _In_  BOOLEAN                 Capture,
        _In_  PKSDATAFORMAT           DataFormat
        );
    STDMETHODIMP_(NTSTATUS) GetDeviceDescription(
        _Out_ PDEVICE_DESCRIPTION DeviceDescription
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
    CAdapterCommon *    GetAdapterCommon() const { return m_pAdapterCommon; }
    ULONGLONG           GetQpcFrequency() const  { return m_ullQpcFrequency; }

private:
    LONG                m_lRefCount;
    PPORTWAVERT         m_pPort;
    CAdapterCommon *    m_pAdapterCommon;
    ULONGLONG           m_ullQpcFrequency;
};

//
// Factory used by CAdapterCommon::InstallSubdevice().
//
NTSTATUS
CreateMiniportWaveRT(
    _Outptr_ PUNKNOWN *         OutMiniport,
    _In_     REFCLSID           MiniportClassId,
    _In_opt_ PUNKNOWN           OuterUnknown,
    _In_     POOL_FLAGS         PoolFlags,
    _In_opt_ CAdapterCommon *   AdapterCommon,
    _In_opt_ PVOID              MiniportContext
    );

#endif // _AURA_MINIPORT_WAVERT_H_
