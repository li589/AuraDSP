/*++

Module Name:

    Driver.cpp

Abstract:

    AuraVAIO driver entry points.

    AuraVAIO is a PortCls audio adapter that also uses KMDF for device
    creation.  The sequence below is the WDK-sanctioned mix (identical in shape
    to the Windows-driver-samples audio/sysvad sample):

        DriverEntry : WdfDriverCreate (with WdfDriverInitNoDispatchOverride,
                      so PortCls -- not KMDF -- owns the IRP dispatch table)
                      -> PcInitializeAdapterDriver
                      -> hook IRP_MJ_PNP and the unload routine
        AddDevice   : PcAddAdapterDevice
        StartDevice : create the adapter common, register power management,
                      install the WaveRT + Topology subdevices and wire their
                      bridge pins together
        PnpHandler  : release the adapter common on stop / remove

--*/

#include "AuraVaio.h"
#include "AdapterCommon.h"
#include "MiniportWaveRT.h"
#include "Topology.h"
#include "AuraVaoTables.h"
#include "ControlDevice.h"

#include <wdfminiport.h>

//
// Number of subdevices PortCls should expect on this adapter (Wave + Topology,
// with headroom for the capture endpoint and the 7.1 topology to come).
//
#define AURA_MAX_SUBDEVICES     8

//=============================================================================
// Forward declarations
//=============================================================================

DRIVER_ADD_DEVICE AddDevice;

NTSTATUS
StartDevice(
    _In_ PDEVICE_OBJECT     DeviceObject,
    _In_ PIRP               Irp,
    _In_ PRESOURCELIST      ResourceList
    );

_Dispatch_type_(IRP_MJ_PNP)
DRIVER_DISPATCH PnpHandler;

_Dispatch_type_(IRP_MJ_CREATE)
DRIVER_DISPATCH CreateHandler;

_Dispatch_type_(IRP_MJ_CLOSE)
DRIVER_DISPATCH CloseHandler;

_Dispatch_type_(IRP_MJ_CLEANUP)
DRIVER_DISPATCH CleanupHandler;

_Dispatch_type_(IRP_MJ_DEVICE_CONTROL)
DRIVER_DISPATCH DeviceControlHandler;

extern "C" VOID DriverUnload(_In_ PDRIVER_OBJECT DriverObject);

//
// PortCls installs its own DriverUnload via PcInitializeAdapterDriver; we chain
// to it so the class driver still gets torn down.
//
static PDRIVER_UNLOAD g_PcDriverUnloadRoutine = NULL;

//=============================================================================
// DriverEntry
//=============================================================================

extern "C"
NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT     DriverObject,
    _In_ PUNICODE_STRING    RegistryPathName
    )
{
    NTSTATUS            ntStatus;
    WDF_DRIVER_CONFIG   config;

    AURA_TRACE("DriverEntry\n");

    WDF_DRIVER_CONFIG_INIT(&config, WDF_NO_EVENT_CALLBACK);

    //
    // Tell KMDF not to install dispatch routines: the I/O manager's IRPs must
    // reach PortCls, not the framework.
    //
    config.DriverInitFlags |= WdfDriverInitNoDispatchOverride;
    config.DriverPoolTag    = AURA_POOLTAG;

    ntStatus = WdfDriverCreate(
                    DriverObject,
                    RegistryPathName,
                    WDF_NO_OBJECT_ATTRIBUTES,
                    &config,
                    WDF_NO_HANDLE);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("WdfDriverCreate failed, 0x%08X\n", ntStatus);
        return ntStatus;
    }

    //
    // Hand the driver over to the audio class driver.
    //
    ntStatus = PcInitializeAdapterDriver(
                    DriverObject,
                    RegistryPathName,
                    PDRIVER_ADD_DEVICE(AddDevice));
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("PcInitializeAdapterDriver failed, 0x%08X\n", ntStatus);
        WdfDriverMiniportUnload(WdfGetDriver());
        return ntStatus;
    }

    //
    // Create the control device object (\Device\AuraVaioControl) for user-mode
    // IPC and shared circular ring buffer mapping.
    //
    ntStatus = AuraControlDevice_Create(DriverObject);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("AuraControlDevice_Create failed, 0x%08X (continuing)\n", ntStatus);
    }

    //
    // Intercept stop / remove / surprise-remove so the adapter common object
    // can be released before PortCls tears the FDO down.
    //
    DriverObject->MajorFunction[IRP_MJ_PNP]            = PnpHandler;
    DriverObject->MajorFunction[IRP_MJ_CREATE]         = CreateHandler;
    DriverObject->MajorFunction[IRP_MJ_CLOSE]          = CloseHandler;
    DriverObject->MajorFunction[IRP_MJ_CLEANUP]        = CleanupHandler;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DeviceControlHandler;

    //
    // Chain the class driver's unload routine.
    //
    g_PcDriverUnloadRoutine = DriverObject->DriverUnload;
    DriverObject->DriverUnload = DriverUnload;

    AURA_TRACE("DriverEntry OK\n");

    return STATUS_SUCCESS;
}

//=============================================================================
// DriverUnload
//=============================================================================

extern "C"
VOID
DriverUnload(
    _In_ PDRIVER_OBJECT DriverObject
    )
{
    AURA_TRACE("DriverUnload\n");

    //
    // Clean up our control device and unmap/free shared ring buffer.
    //
    AuraControlDevice_Destroy(DriverObject);

    //
    // Let PortCls clean up first...
    //
    if (g_PcDriverUnloadRoutine != NULL)
    {
        g_PcDriverUnloadRoutine(DriverObject);
    }

    //
    // ...then release the KMDF driver object we created in DriverEntry.
    //
    if (WdfGetDriver() != NULL)
    {
        WdfDriverMiniportUnload(WdfGetDriver());
    }
}

//=============================================================================
// Dispatch handlers
//=============================================================================

NTSTATUS
CreateHandler(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    if (AuraControlDevice_IsControlDevice(DeviceObject))
    {
        return AuraControlDevice_DispatchCreate(DeviceObject, Irp);
    }
    return PcDispatchIrp(DeviceObject, Irp);
}

NTSTATUS
CloseHandler(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    if (AuraControlDevice_IsControlDevice(DeviceObject))
    {
        return AuraControlDevice_DispatchClose(DeviceObject, Irp);
    }
    return PcDispatchIrp(DeviceObject, Irp);
}

NTSTATUS
CleanupHandler(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    if (AuraControlDevice_IsControlDevice(DeviceObject))
    {
        return AuraControlDevice_DispatchCleanup(DeviceObject, Irp);
    }
    return PcDispatchIrp(DeviceObject, Irp);
}

NTSTATUS
DeviceControlHandler(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    if (AuraControlDevice_IsControlDevice(DeviceObject))
    {
        return AuraControlDevice_DispatchDeviceControl(DeviceObject, Irp);
    }
    return PcDispatchIrp(DeviceObject, Irp);
}

//=============================================================================
// AddDevice
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
AddDevice(
    _In_ PDRIVER_OBJECT     DriverObject,
    _In_ PDEVICE_OBJECT     PhysicalDeviceObject
    )
{
    PAGED_CODE();

    AURA_TRACE("AddDevice pdo=%p\n", PhysicalDeviceObject);

    //
    // PcAddAdapterDevice creates the functional device object, allocates the
    // (documented) PortClassDeviceContext extension and clears
    // DO_DEVICE_INITIALIZING for us.
    //
    return PcAddAdapterDevice(
                DriverObject,
                PhysicalDeviceObject,
                PCPFNSTARTDEVICE(StartDevice),
                AURA_MAX_SUBDEVICES,
                0);
}

//=============================================================================
// StartDevice
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
StartDevice(
    _In_ PDEVICE_OBJECT     DeviceObject,
    _In_ PIRP               Irp,
    _In_ PRESOURCELIST      ResourceList
    )
{
    NTSTATUS                    ntStatus;
    PUNKNOWN                    unknownCommon   = NULL;
    CAdapterCommon *            adapterCommon   = NULL;
    PUNKNOWN                    unknownWave     = NULL;
    PUNKNOWN                    unknownTopology = NULL;
    PortClassDeviceContext *    pExtension;

    PAGED_CODE();

    ASSERT(DeviceObject != NULL);
    ASSERT(Irp != NULL);

    pExtension = static_cast<PortClassDeviceContext *>(DeviceObject->DeviceExtension);
    ASSERT(pExtension != NULL);

    //
    // 1. The per-adapter common object (power management + subdevice owner).
    //
    ntStatus = NewAdapterCommon(
                    &unknownCommon,
                    IID_IAdapterPowerManagement,
                    POOL_FLAG_NON_PAGED);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("NewAdapterCommon failed, 0x%08X\n", ntStatus);
        goto Exit;
    }

    //
    // unknownCommon is the object's IAdapterPowerManagement interface and the
    // concrete type is known to us, so the down-cast is safe.
    //
    adapterCommon = static_cast<CAdapterCommon *>(unknownCommon);

    ntStatus = adapterCommon->Init(DeviceObject);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("CAdapterCommon::Init failed, 0x%08X\n", ntStatus);
        goto Exit;
    }

    //
    // 2. Register with PortCls for power-management services.
    //
    ntStatus = PcRegisterAdapterPowerManagement(unknownCommon, DeviceObject);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("PcRegisterAdapterPowerManagement failed, 0x%08X\n", ntStatus);
        goto Exit;
    }

    //
    // 3. WaveRT subdevice (the byte stream).
    //
    ntStatus = adapterCommon->InstallSubdevice(
                    Irp,
                    ResourceList,
                    AURA_KSNAME_WAVE,
                    CLSID_PortWaveRT,
                    IID_IMiniportWaveRT,
                    CreateMiniportWaveRT,
                    NULL,
                    IID_IPortWaveRT,
                    &unknownWave);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("wave subdevice install failed, 0x%08X\n", ntStatus);
        goto Exit;
    }

    //
    // 4. Topology subdevice (the "device" side of the endpoint).
    //
    ntStatus = adapterCommon->InstallSubdevice(
                    Irp,
                    ResourceList,
                    AURA_KSNAME_TOPOLOGY,
                    CLSID_PortTopology,
                    IID_IMiniportTopology,
                    CreateMiniportTopology,
                    NULL,
                    IID_IPortTopology,
                    &unknownTopology);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("topology subdevice install failed, 0x%08X\n", ntStatus);
        goto Exit;
    }

    //
    // 5. Connect the bridge pins so both filters become one endpoint.
    //
    ntStatus = adapterCommon->ConnectTopologies(unknownTopology, unknownWave);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("ConnectTopologies failed, 0x%08X\n", ntStatus);
        goto Exit;
    }

    AURA_TRACE("adapter started\n");

Exit:

    //
    // Stash the adapter common in the device extension so PnpHandler can
    // release it.  Take our own reference first, then drop the creation
    // reference below: net effect one reference owned by m_pCommon.
    //
    if (adapterCommon != NULL && NT_SUCCESS(ntStatus))
    {
        adapterCommon->AddRef();
        pExtension->m_pCommon = adapterCommon;
    }

    AURA_SAFE_RELEASE(unknownTopology);
    AURA_SAFE_RELEASE(unknownWave);
    AURA_SAFE_RELEASE(unknownCommon);

    return ntStatus;
}

//=============================================================================
// PnpHandler
//=============================================================================

#pragma code_seg("PAGE")
NTSTATUS
PnpHandler(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    IO_STACK_LOCATION *         stack;
    PortClassDeviceContext *    pExtension;

    PAGED_CODE();

    ASSERT(DeviceObject != NULL);
    ASSERT(Irp != NULL);

    stack      = IoGetCurrentIrpStackLocation(Irp);
    pExtension = static_cast<PortClassDeviceContext *>(DeviceObject->DeviceExtension);

    switch (stack->MinorFunction)
    {
    case IRP_MN_REMOVE_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
    case IRP_MN_STOP_DEVICE:
        if (pExtension != NULL && pExtension->m_pCommon != NULL)
        {
            pExtension->m_pCommon->Cleanup();
            pExtension->m_pCommon->Release();
            pExtension->m_pCommon = NULL;
        }
        break;

    default:
        break;
    }

    //
    // Always let PortCls see the IRP.
    //
    return PcDispatchIrp(DeviceObject, Irp);
}
