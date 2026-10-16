/*++

Module Name:

    AdapterCommon.cpp

Abstract:

    See AdapterCommon.h.

--*/

#include "AdapterCommon.h"
#include "AuraVaoTables.h"

//=============================================================================
// Construction / teardown
//=============================================================================

CAdapterCommon::CAdapterCommon()
    : m_lRefCount(1)
    , m_pDeviceObject(NULL)
    , m_WavePortUnknown(NULL)
    , m_TopologyPortUnknown(NULL)
{
    m_PowerState.DeviceState = PowerDeviceD0;
}

CAdapterCommon::~CAdapterCommon()
{
    ReleaseSubdevices();
}

//
// Note: the destructor and ReleaseSubdevices() stay in the default (non-paged)
// segment because Release() can run at DISPATCH_LEVEL.
//
#pragma code_seg("PAGE")
NTSTATUS
CAdapterCommon::Init(
    _In_ PDEVICE_OBJECT DeviceObject
    )
{
    PAGED_CODE();

    if (DeviceObject == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    m_pDeviceObject = DeviceObject;

    return STATUS_SUCCESS;
}

#pragma code_seg("PAGE")
VOID
CAdapterCommon::Cleanup()
{
    PAGED_CODE();

    //
    // PortCls tears the subdevices down itself as part of the FDO remove; all
    // we do is drop our own references so the port/miniport objects can be
    // destroyed once the class driver is done with them.
    //
    ReleaseSubdevices();
}

VOID
CAdapterCommon::ReleaseSubdevices()
{
    AURA_SAFE_RELEASE(m_WavePortUnknown);
    AURA_SAFE_RELEASE(m_TopologyPortUnknown);
}

//=============================================================================
// IUnknown
//=============================================================================

#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CAdapterCommon::QueryInterface(
    _In_ REFIID InterfaceId,
    _COM_Outptr_ PVOID * Interface
    )
{
    PAGED_CODE();

    if (Interface == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Interface = NULL;

    if (IsEqualGUIDAligned(InterfaceId, IID_IUnknown) ||
        IsEqualGUIDAligned(InterfaceId, IID_IAdapterPowerManagement))
    {
        *Interface = PVOID(static_cast<IAdapterPowerManagement *>(this));
        AddRef();
        return STATUS_SUCCESS;
    }

    return STATUS_NOT_SUPPORTED;
}

//=============================================================================
// IAdapterPowerManagement
//
// AuraVAIO has no hardware to power down, so all of this is bookkeeping.
//=============================================================================

#pragma code_seg()
STDMETHODIMP_(void)
CAdapterCommon::PowerChangeState(
    _In_ POWER_STATE NewState
    )
{
    m_PowerState = NewState;
}

#pragma code_seg()
STDMETHODIMP_(NTSTATUS)
CAdapterCommon::QueryPowerChangeState(
    _In_ POWER_STATE NewStateQuery
    )
{
    UNREFERENCED_PARAMETER(NewStateQuery);

    return STATUS_SUCCESS;
}

#pragma code_seg()
STDMETHODIMP_(NTSTATUS)
CAdapterCommon::QueryDeviceCapabilities(
    _Inout_updates_bytes_(sizeof(DEVICE_CAPABILITIES)) PDEVICE_CAPABILITIES PowerDeviceCaps
    )
{
    if (PowerDeviceCaps == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // The adapter is fully functional in S0 (D0) and is simply not usable in
    // any sleeping state; report D3 everywhere else so the power manager does
    // not expect an intermediate state we cannot honour.
    //
    PowerDeviceCaps->DeviceState[PowerSystemWorking]   = PowerDeviceD0;
    PowerDeviceCaps->DeviceState[PowerSystemSleeping1] = PowerDeviceD3;
    PowerDeviceCaps->DeviceState[PowerSystemSleeping2] = PowerDeviceD3;
    PowerDeviceCaps->DeviceState[PowerSystemSleeping3] = PowerDeviceD3;
    PowerDeviceCaps->DeviceState[PowerSystemHibernate] = PowerDeviceD3;
    PowerDeviceCaps->DeviceState[PowerSystemShutdown]  = PowerDeviceD3;

    return STATUS_SUCCESS;
}

//=============================================================================
// Subdevice plumbing
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
CAdapterCommon::InstallSubdevice(
    _In_opt_     PIRP                    Irp,
    _In_opt_     PRESOURCELIST           ResourceList,
    _In_         PCWSTR                  Name,
    _In_         REFCLSID                PortClassId,
    _In_         REFCLSID                MiniportClassId,
    _In_         PFN_AURA_CREATE_MINIPORT MiniportCreate,
    _In_opt_     PVOID                   MiniportContext,
    _In_         REFIID                  PortInterfaceId,
    _Outptr_opt_ PUNKNOWN *              OutPortUnknown
    )
{
    NTSTATUS    ntStatus;
    PPORT       port     = NULL;
    PUNKNOWN    miniport = NULL;
    PUNKNOWN    portApi  = NULL;

    PAGED_CODE();

    if (OutPortUnknown != NULL)
    {
        *OutPortUnknown = NULL;
    }

    if (m_pDeviceObject == NULL || Name == NULL || MiniportCreate == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // 1. Create the port driver object.
    //
    ntStatus = PcNewPort(&port, PortClassId);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("PcNewPort failed, 0x%08X", ntStatus);
        goto Done;
    }

    //
    // 2. Create the miniport driver object.
    //
    ntStatus = MiniportCreate(
                    &miniport,
                    MiniportClassId,
                    NULL,
                    POOL_FLAG_NON_PAGED,
                    this,
                    MiniportContext);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("MiniportCreate failed, 0x%08X", ntStatus);
        goto Done;
    }

    //
    // 3. Bind port and miniport in one go.  This is what actually invokes the
    //    miniport's Init().
    //
    ntStatus = port->Init(
                    m_pDeviceObject,
                    Irp,
                    miniport,
                    PUNKNOWN(static_cast<IAdapterPowerManagement *>(this)),
                    ResourceList);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("IPort::Init failed, 0x%08X", ntStatus);
        goto Done;
    }

    //
    // 4. Register the subdevice.  The subdevice identity is the *port* object
    //    (see PcRegisterSubdevice: "the IPort interface of the port driver
    //    object that is bound to the subdevice").
    //
    ntStatus = PcRegisterSubdevice(m_pDeviceObject, const_cast<PWSTR>(Name), port);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("PcRegisterSubdevice(%ws) failed, 0x%08X", Name, ntStatus);
        goto Done;
    }

    //
    // 5. Hand back the port interface the caller asked for.
    //
    ntStatus = port->QueryInterface(PortInterfaceId, (PVOID *)&portApi);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("port->QueryInterface failed, 0x%08X", ntStatus);
        goto Done;
    }

    //
    // Cache it for teardown. QueryInterface took a reference; take an additional
    // reference for m_* so OutPortUnknown can take ownership of the caller's reference.
    //
    if (IsEqualGUIDAligned(PortClassId, CLSID_PortWaveRT))
    {
        AURA_SAFE_RELEASE(m_WavePortUnknown);
        m_WavePortUnknown = portApi;
        m_WavePortUnknown->AddRef();
    }
    else if (IsEqualGUIDAligned(PortClassId, CLSID_PortTopology))
    {
        AURA_SAFE_RELEASE(m_TopologyPortUnknown);
        m_TopologyPortUnknown = portApi;
        m_TopologyPortUnknown->AddRef();
    }

    if (OutPortUnknown != NULL)
    {
        *OutPortUnknown = portApi;
        portApi = NULL;             // ownership transferred to the caller
    }

Done:

    AURA_SAFE_RELEASE(portApi);

    if (miniport != NULL)
    {
        miniport->Release();
    }

    if (port != NULL)
    {
        port->Release();
    }

    return ntStatus;
}

#pragma code_seg("PAGE")
NTSTATUS
CAdapterCommon::ConnectTopologies(
    _In_ PUNKNOWN UnknownTopology,
    _In_ PUNKNOWN UnknownWave
    )
{
    NTSTATUS ntStatus = STATUS_SUCCESS;

    PAGED_CODE();

    if (UnknownTopology == NULL || UnknownWave == NULL || m_pDeviceObject == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    //
    // For render, data flows wave-bridge -> topology-bridge, so the wave filter
    // is the "From" side.
    //
    for (ULONG i = 0; i < SIZEOF_ARRAY(AuraPhysicalConnections); i++)
    {
        ntStatus = PcRegisterPhysicalConnection(
                        m_pDeviceObject,
                        UnknownWave,
                        AuraPhysicalConnections[i].WavePin,
                        UnknownTopology,
                        AuraPhysicalConnections[i].TopologyPin);
        if (!NT_SUCCESS(ntStatus))
        {
            AURA_TRACE("PcRegisterPhysicalConnection[%u] failed, 0x%08X", i, ntStatus);
            return ntStatus;
        }
    }

    return ntStatus;
}

//=============================================================================
// Factory
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
NewAdapterCommon(
    _Outptr_ PUNKNOWN * OutUnknown,
    _In_     REFCLSID   ClassId,
    _In_     POOL_FLAGS PoolFlags
    )
{
    CAdapterCommon * pCommon;

    PAGED_CODE();

    UNREFERENCED_PARAMETER(ClassId);

    if (OutUnknown == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *OutUnknown = NULL;

    pCommon = new (PoolFlags, AURA_POOLTAG) CAdapterCommon();
    if (pCommon == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    //
    // Hand out the IAdapterPowerManagement interface (the reference count is
    // already 1 from construction).
    //
    *OutUnknown = PUNKNOWN(static_cast<IAdapterPowerManagement *>(pCommon));

    return STATUS_SUCCESS;
}
