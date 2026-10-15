/*++

Module Name:

    AdapterCommon.h

Abstract:

    The per-adapter "common" object: PortCls power management, subdevice
    installation / teardown, and the wave <-> topology wiring.

--*/

#ifndef _AURA_ADAPTER_COMMON_H_
#define _AURA_ADAPTER_COMMON_H_

#include "AuraVaio.h"

class CAdapterCommon;

//
// Callback used to instantiate a miniport.  Matches the WDK sample convention
// so InstallSubdevice() stays generic while the concrete miniport classes
// remain private to their own translation units.
//
typedef
NTSTATUS
(*PFN_AURA_CREATE_MINIPORT)(
    _Outptr_ PUNKNOWN *         OutMiniport,
    _In_     REFCLSID           MiniportClassId,
    _In_opt_ PUNKNOWN           OuterUnknown,
    _In_     POOL_FLAGS         PoolFlags,
    _In_opt_ CAdapterCommon *   AdapterCommon,
    _In_opt_ PVOID              MiniportContext
    );

//=============================================================================
// CAdapterCommon
//
// Derives from exactly one PortCls interface chain (IAdapterPowerManagement),
// hence owns exactly one IUnknown subobject and implements QueryInterface
// itself -- no aggregation, therefore no outer-unknown indirection.
//=============================================================================

class CAdapterCommon : public IAdapterPowerManagement
{
public:
    CAdapterCommon();
    virtual ~CAdapterCommon();

    // ---- IUnknown ----
    STDMETHODIMP_(NTSTATUS) QueryInterface(
        _In_  REFIID InterfaceId,
        _COM_Outptr_ PVOID * Interface
        );
    AURA_REFCOUNT_BOILERPLATE

    // ---- IAdapterPowerManagement ----
    STDMETHODIMP_(void) PowerChangeState(
        _In_ POWER_STATE NewState
        );
    STDMETHODIMP_(NTSTATUS) QueryPowerChangeState(
        _In_ POWER_STATE NewStateQuery
        );
    STDMETHODIMP_(NTSTATUS) QueryDeviceCapabilities(
        _Inout_updates_bytes_(sizeof(DEVICE_CAPABILITIES)) PDEVICE_CAPABILITIES PowerDeviceCaps
        );

    // ---- AuraVAIO ----
    NTSTATUS        Init(_In_ PDEVICE_OBJECT DeviceObject);
    VOID            Cleanup();

    PDEVICE_OBJECT  GetDeviceObject() const { return m_pDeviceObject; }

    //
    // Creates a port object, instantiates the miniport through MiniportCreate,
    // binds the two with IPort::Init() and registers the result as a subdevice
    // of this adapter.  The returned port interface is also cached internally
    // so teardown can drop it deterministically.
    //
    NTSTATUS
    InstallSubdevice(
        _In_opt_     PIRP                    Irp,
        _In_opt_     PRESOURCELIST           ResourceList,
        _In_         PCWSTR                  Name,
        _In_         REFCLSID                PortClassId,
        _In_         REFCLSID                MiniportClassId,
        _In_         PFN_AURA_CREATE_MINIPORT MiniportCreate,
        _In_opt_     PVOID                   MiniportContext,
        _In_         REFIID                  PortInterfaceId,
        _Outptr_opt_ PUNKNOWN *              OutPortUnknown
        );

    //
    // Registers the wave <-> topology bridge physical connections.
    //
    NTSTATUS
    ConnectTopologies(
        _In_ PUNKNOWN   UnknownTopology,
        _In_ PUNKNOWN   UnknownWave
        );

    //
    // Drops the cached subdevice references (adapter teardown).
    //
    VOID
    ReleaseSubdevices();

private:
    LONG                m_lRefCount;
    PDEVICE_OBJECT      m_pDeviceObject;
    PUNKNOWN            m_WavePortUnknown;      // strong refs, for teardown
    PUNKNOWN            m_TopologyPortUnknown;
    POWER_STATE         m_PowerState;
};

//
// Factory for the adapter-common object (one instance per adapter FDO).
//
NTSTATUS
NewAdapterCommon(
    _Outptr_ PUNKNOWN * OutUnknown,
    _In_     REFCLSID   ClassId,
    _In_     POOL_FLAGS PoolFlags
    );

#endif // _AURA_ADAPTER_COMMON_H_
