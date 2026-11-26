/*++

Module Name:

    ControlDevice.cpp

Abstract:

    Control device object and shared memory ring buffer implementation for
    the AuraVAIO kernel driver.

    Exposes \\Device\\AuraVaioControl (\\.\AuraVaioControl) for user-mode
    IOCTL communication and zero-copy shared ring buffer mapping.

--*/

#include "ControlDevice.h"
#include "RingCursor.h"
#include <wdmsec.h>

//=============================================================================
// Globals
//=============================================================================

static PDEVICE_OBJECT           g_pControlDeviceObject  = NULL;
static PBYTE                    g_pRingBuffer           = NULL;
static ULONG                    g_ulRingTotalSize       = 0;
static PMDL                     g_pRingMdl              = NULL;
static PVOID                    g_pMappedUserAddress    = NULL;
static PEPROCESS                g_pMappedProcess        = NULL;
// 处理后回写环（2026-11-23，2×2 模型 S1)：与渲染环同构的第二环。
// 生产者是用户态桥（写 WriteOffset/TotalBytesWritten），消费者是
// 驱动录制读端（维护 ReadOffset/TotalBytesRead）——与渲染环的
// 内核写/桥读正好镜像，volatile 单调计数纪律同渲染环。映射资格
// 限渲染环持有进程，归属跟踪与渲染环同式（文件对象定罪口径）。
static PBYTE                    g_pProcRingBuffer       = NULL;
static ULONG                    g_ulProcRingTotalSize   = 0;
static ULONG                    g_ulProcRingDataSize    = 0;
static PMDL                     g_pProcRingMdl          = NULL;
static PVOID                    g_pProcMappedUserAddress = NULL;
static PEPROCESS                g_pProcMappedProcess    = NULL;
static PFILE_OBJECT             g_pProcMappedFileObject = NULL;
// 映射归属的 FILE_OBJECT（第六轮项 1 定罪）：IRP_MJ_CLEANUP 在
// 同进程任意控制句柄关闭时都会到达，旧实现只按进程判定就解
// 映射——App 里 vaio_detect 开/关一次控制设备，就把正在运行
// 的桥泵线程的环映射拆了，泵下一次读共享头即 AV（WinDbg 实
// 证 auravaio_bridge+0x6d51 读 header->Channels）。CLEANUP 只
// 许拆「建立映射的那个文件对象」自己的映射。
static PFILE_OBJECT             g_pMappedFileObject     = NULL;
// GET_DEBUG_LOG 持久持有者（2026-11-08 审计·调试低6）：最近一次成功
// MAP 的进程。解映射时**不清**（校验要覆盖解映射后的窗口），持有者
// 进程退出时由 Cleanup 路径清除。受 g_RingLock 保护。
static PEPROCESS                g_pDebugLogHolder       = NULL;
// 映射同步互斥体（PASSIVE_LEVEL / APC_LEVEL）：
// MmMapLockedPagesSpecifyCache (UserMode) 与 MmUnmapLockedPages 严禁在
// DISPATCH_LEVEL 自旋锁内调用，否则引发 0x7A (1, D0000006) 页面错误蓝屏。
// 映射与解映射操作由 g_MappingMutex 串行化，保持在 APC_LEVEL。
static FAST_MUTEX               g_MappingMutex;
static KSPIN_LOCK               g_RingLock;
static LONG                     g_lActiveRenderStreams  = 0;
static LONG                     g_lActiveCaptureStreams = 0;
static ULONG                    g_ulCurrentSampleRate   = AURA_DEFAULT_SAMPLE_RATE;
static ULONG                    g_ulCurrentChannels     = AURA_DEFAULT_CHANNELS;
static ULONG                    g_ulCurrentBitsPerSample= AURA_DEFAULT_BITS_PER_SAMPLE;
// 格式升级一期（2026-11-12）：格式类别与有效位深（默认值与默认几何
// 一致——32 位 IEEE float，有效位深=容器位深）。
static ULONG                    g_ulCurrentFormatKind   = AURA_VAIO_FMT_FLOAT;
static ULONG                    g_ulCurrentValidBits    = AURA_DEFAULT_BITS_PER_SAMPLE;
// 环数据区有效尺寸（内核真值）：（总尺寸−头）向下取整到
// AURA_VAIO_RING_DATA_ALIGNMENT(288) 的倍数，见 AuraVaioIpc.h 的说明。
// 头 DataSizeBytes、MAP 应答与读写路径一律用它，不再各自现算。
static ULONG                    g_ulRingDataSize        = 0;
static ULONGLONG                g_ullTotalFramesWritten = 0;
static ULONGLONG                g_ullTotalFramesRead    = 0;

static AURA_DEBUG_LOG           g_DebugLog;
static KSPIN_LOCK               g_DebugLock;

//=============================================================================
// Lifecycle
//=============================================================================

NTSTATUS
AuraControlDevice_Create(
    _In_ PDRIVER_OBJECT DriverObject
    )
{
    NTSTATUS                ntStatus;
    UNICODE_STRING          ntDeviceName;
    UNICODE_STRING          dosDeviceName;
    PAURA_VAIO_SHARED_HEADER pHeader;
    ULONG                   allocSize;

    AURA_TRACE("AuraControlDevice_Create\n");

    KeInitializeSpinLock(&g_RingLock);
    KeInitializeSpinLock(&g_DebugLock);
    ExInitializeFastMutex(&g_MappingMutex);
    RtlZeroMemory(&g_DebugLog, sizeof(g_DebugLog));

    RtlInitUnicodeString(&ntDeviceName, AURA_VAIO_DEVICE_NAME_NT);
    RtlInitUnicodeString(&dosDeviceName, AURA_VAIO_DOS_DEVICE_NAME);

    // DRV-04: IoCreateDeviceSecure with SDDL restricting access to SYSTEM (SY),
    // Administrators (BA), and Interactive Users (IU).
    // WD (Everyone) is excluded to prevent unprivileged sandboxes or remote callers
    // from accessing or hijacking the control device.
    UNICODE_STRING sddl;
    RtlInitUnicodeString(&sddl, L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGWGX;;;IU)");

    ntStatus = IoCreateDeviceSecure(
                    DriverObject,
                    0,
                    &ntDeviceName,
                    FILE_DEVICE_UNKNOWN,
                    FILE_DEVICE_SECURE_OPEN,
                    FALSE,
                    &sddl,
                    NULL,
                    &g_pControlDeviceObject);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("IoCreateDeviceSecure failed, 0x%08X\n", ntStatus);
        return ntStatus;
    }

    ntStatus = IoCreateSymbolicLink(&dosDeviceName, &ntDeviceName);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("IoCreateSymbolicLink failed, 0x%08X\n", ntStatus);
        IoDeleteDevice(g_pControlDeviceObject);
        g_pControlDeviceObject = NULL;
        return ntStatus;
    }

    //
    // Allocate the shared non-paged memory pool for the circular audio buffer.
    //
    allocSize = sizeof(AURA_VAIO_SHARED_HEADER) + AURA_VAIO_DEFAULT_RING_SIZE;
    allocSize = (allocSize + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1); // Page-aligned

    g_pRingBuffer = (PBYTE)AuraAllocatePool(POOL_FLAG_NON_PAGED, allocSize, AURA_POOLTAG);
    if (g_pRingBuffer == NULL)
    {
        AURA_TRACE("Failed to allocate %u bytes for ring buffer\n", allocSize);
        IoDeleteSymbolicLink(&dosDeviceName);
        IoDeleteDevice(g_pControlDeviceObject);
        g_pControlDeviceObject = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(g_pRingBuffer, allocSize);
    g_ulRingTotalSize = allocSize;
    // 格式升级一期：数据区尺寸贴 288 帧格对齐（尾部不足一格的字节闲置）。
    g_ulRingDataSize = (allocSize - sizeof(AURA_VAIO_SHARED_HEADER)) /
                       AURA_VAIO_RING_DATA_ALIGNMENT * AURA_VAIO_RING_DATA_ALIGNMENT;

    //
    // Allocate and build the MDL so user processes can map this memory.
    //
    g_pRingMdl = IoAllocateMdl(g_pRingBuffer, allocSize, FALSE, FALSE, NULL);
    if (g_pRingMdl == NULL)
    {
        AURA_TRACE("IoAllocateMdl failed\n");
        ExFreePoolWithTag(g_pRingBuffer, AURA_POOLTAG);
        g_pRingBuffer = NULL;
        IoDeleteSymbolicLink(&dosDeviceName);
        IoDeleteDevice(g_pControlDeviceObject);
        g_pControlDeviceObject = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    MmBuildMdlForNonPagedPool(g_pRingMdl);

    //
    // Initialize shared header
    //
    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);
    pHeader->Magic                  = AURA_VAIO_MAGIC_RING;
    pHeader->Version                = AURA_VAIO_IPC_VERSION;
    pHeader->HeaderSizeBytes        = sizeof(AURA_VAIO_SHARED_HEADER);
    pHeader->TotalBufferSizeBytes   = allocSize;
    pHeader->DataOffsetBytes        = sizeof(AURA_VAIO_SHARED_HEADER);
    pHeader->DataSizeBytes          = g_ulRingDataSize;
    pHeader->SampleRate             = g_ulCurrentSampleRate;
    pHeader->Channels               = g_ulCurrentChannels;
    pHeader->BitsPerSample          = g_ulCurrentBitsPerSample;
    pHeader->BlockAlign             = g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
    pHeader->FormatKind             = g_ulCurrentFormatKind;
    pHeader->ValidBitsPerSample     = g_ulCurrentValidBits;
    pHeader->WriteOffset            = 0;
    pHeader->ReadOffset             = 0;
    pHeader->TotalBytesWritten      = 0;
    pHeader->TotalBytesRead         = 0;
    pHeader->StreamState            = 0; // STOP

    //
    // 处理后回写环（2026-11-23 S1)：与渲染环同尺寸同构，Create 时
    // 一并分配（1MiB 非分页池，常驻成本可接受，换取运行期零分配）。
    //
    g_pProcRingBuffer = (PBYTE)AuraAllocatePool(POOL_FLAG_NON_PAGED, allocSize, AURA_POOLTAG);
    if (g_pProcRingBuffer == NULL)
    {
        AURA_TRACE("Failed to allocate %u bytes for processed ring\n", allocSize);
        IoFreeMdl(g_pRingMdl);
        g_pRingMdl = NULL;
        ExFreePoolWithTag(g_pRingBuffer, AURA_POOLTAG);
        g_pRingBuffer = NULL;
        IoDeleteSymbolicLink(&dosDeviceName);
        IoDeleteDevice(g_pControlDeviceObject);
        g_pControlDeviceObject = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(g_pProcRingBuffer, allocSize);
    g_ulProcRingTotalSize = allocSize;
    g_ulProcRingDataSize = g_ulRingDataSize;

    g_pProcRingMdl = IoAllocateMdl(g_pProcRingBuffer, allocSize, FALSE, FALSE, NULL);
    if (g_pProcRingMdl == NULL)
    {
        AURA_TRACE("IoAllocateMdl (processed) failed\n");
        ExFreePoolWithTag(g_pProcRingBuffer, AURA_POOLTAG);
        g_pProcRingBuffer = NULL;
        IoFreeMdl(g_pRingMdl);
        g_pRingMdl = NULL;
        ExFreePoolWithTag(g_pRingBuffer, AURA_POOLTAG);
        g_pRingBuffer = NULL;
        IoDeleteSymbolicLink(&dosDeviceName);
        IoDeleteDevice(g_pControlDeviceObject);
        g_pControlDeviceObject = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    MmBuildMdlForNonPagedPool(g_pProcRingMdl);

    {
        PAURA_VAIO_SHARED_HEADER pProcHeader =
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pProcRingBuffer);
        pProcHeader->Magic               = AURA_VAIO_MAGIC_RING;
        pProcHeader->Version             = AURA_VAIO_IPC_VERSION;
        pProcHeader->HeaderSizeBytes     = sizeof(AURA_VAIO_SHARED_HEADER);
        pProcHeader->TotalBufferSizeBytes = allocSize;
        pProcHeader->DataOffsetBytes     = sizeof(AURA_VAIO_SHARED_HEADER);
        pProcHeader->DataSizeBytes       = g_ulProcRingDataSize;
        pProcHeader->SampleRate          = g_ulCurrentSampleRate;
        pProcHeader->Channels            = g_ulCurrentChannels;
        pProcHeader->BitsPerSample       = g_ulCurrentBitsPerSample;
        pProcHeader->BlockAlign          = g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
        pProcHeader->FormatKind          = g_ulCurrentFormatKind;
        pProcHeader->ValidBitsPerSample  = g_ulCurrentValidBits;
        pProcHeader->WriteOffset         = 0;
        pProcHeader->ReadOffset          = 0;
        pProcHeader->TotalBytesWritten   = 0;
        pProcHeader->TotalBytesRead      = 0;
        pProcHeader->StreamState         = 0; // STOP
    }

    // Control device is ready
    g_pControlDeviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    AURA_TRACE("AuraControlDevice_Create OK (ring=%u B, data=%u B)\n",
               allocSize, pHeader->DataSizeBytes);

    return STATUS_SUCCESS;
}

VOID
AuraControlDevice_Destroy(
    _In_ PDRIVER_OBJECT DriverObject
    )
{
    UNICODE_STRING dosDeviceName;

    UNREFERENCED_PARAMETER(DriverObject);

    AURA_TRACE("AuraControlDevice_Destroy\n");

    ExAcquireFastMutex(&g_MappingMutex);
    if (g_pMappedUserAddress != NULL && g_pRingMdl != NULL)
    {
        __try
        {
            MmUnmapLockedPages(g_pMappedUserAddress, g_pRingMdl);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            AURA_TRACE("Exception unmapping pages in destroy: 0x%08X\n", GetExceptionCode());
        }
        g_pMappedUserAddress = NULL;
        g_pMappedProcess = NULL;
        g_pMappedFileObject = NULL;
        // 驱动整体拆解：录制静音标记随环一并失效，清零防残留。
        if (g_pRingBuffer != NULL)
        {
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer)->CaptureMuted = 0;
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer)->CaptureSource = 0;
        }
    }
    if (g_pProcMappedUserAddress != NULL && g_pProcRingMdl != NULL)
    {
        __try
        {
            MmUnmapLockedPages(g_pProcMappedUserAddress, g_pProcRingMdl);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            AURA_TRACE("Exception unmapping processed pages in destroy: 0x%08X\n", GetExceptionCode());
        }
        g_pProcMappedUserAddress = NULL;
        g_pProcMappedProcess = NULL;
        g_pProcMappedFileObject = NULL;
    }
    ExReleaseFastMutex(&g_MappingMutex);

    if (g_pProcRingMdl != NULL)
    {
        IoFreeMdl(g_pProcRingMdl);
        g_pProcRingMdl = NULL;
    }

    if (g_pProcRingBuffer != NULL)
    {
        ExFreePoolWithTag(g_pProcRingBuffer, AURA_POOLTAG);
        g_pProcRingBuffer = NULL;
        g_ulProcRingTotalSize = 0;
        g_ulProcRingDataSize = 0;
    }

    if (g_pRingMdl != NULL)
    {
        IoFreeMdl(g_pRingMdl);
        g_pRingMdl = NULL;
    }

    if (g_pRingBuffer != NULL)
    {
        ExFreePoolWithTag(g_pRingBuffer, AURA_POOLTAG);
        g_pRingBuffer = NULL;
        g_ulRingTotalSize = 0;
        g_ulRingDataSize = 0;
    }

    if (g_pControlDeviceObject != NULL)
    {
        RtlInitUnicodeString(&dosDeviceName, AURA_VAIO_DOS_DEVICE_NAME);
        IoDeleteSymbolicLink(&dosDeviceName);
        IoDeleteDevice(g_pControlDeviceObject);
        g_pControlDeviceObject = NULL;
    }
}

BOOLEAN
AuraControlDevice_IsControlDevice(
    _In_ PDEVICE_OBJECT DeviceObject
    )
{
    return (DeviceObject != NULL && DeviceObject == g_pControlDeviceObject);
}

//=============================================================================
// IRP Dispatchers
//=============================================================================

NTSTATUS
AuraControlDevice_DispatchCreate(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    UNREFERENCED_PARAMETER(DeviceObject);
    AURA_TRACE("ControlDevice Create\n");

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS
AuraControlDevice_DispatchClose(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    UNREFERENCED_PARAMETER(DeviceObject);
    AURA_TRACE("ControlDevice Close\n");

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS
AuraControlDevice_DispatchCleanup(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    PEPROCESS currentProc = PsGetCurrentProcess();
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);

    UNREFERENCED_PARAMETER(DeviceObject);
    AURA_TRACE("ControlDevice Cleanup (proc=%p)\n", currentProc);

    ExAcquireFastMutex(&g_MappingMutex);
    // 只拆建立映射的文件对象本身的 cleanup（第六轮项 1 定罪）：
    // 同进程其他句柄（detect 探测等）的关闭不得拆在用映射。
    if (g_pMappedUserAddress != NULL && g_pMappedProcess == currentProc &&
        g_pMappedFileObject != NULL && stack->FileObject == g_pMappedFileObject &&
        g_pRingMdl != NULL)
    {
        __try
        {
            MmUnmapLockedPages(g_pMappedUserAddress, g_pRingMdl);
            AURA_TRACE("Unmapped user address %p on process cleanup\n", g_pMappedUserAddress);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            AURA_TRACE("Exception unmapping in cleanup: 0x%08X\n", GetExceptionCode());
        }
        g_pMappedUserAddress = NULL;
        g_pMappedProcess = NULL;
        g_pMappedFileObject = NULL;
        // 桥消失（正常停桥走桥侧清零，此处是进程崩溃兜底）：
        // 录制静音标记不得残留，否则普通管线的回环录制被误哑。
        if (g_pRingBuffer != NULL)
        {
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer)->CaptureMuted = 0;
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer)->CaptureSource = 0;
        }
    }
    // 处理后环映射同口径兜底：建立映射的文件对象 cleanup 时拆
    // 映射并清录制源（源=2 时生产者已死，留值会让录制端点永远
    // 读一条无人写的环）。
    if (g_pProcMappedUserAddress != NULL && g_pProcMappedProcess == currentProc &&
        g_pProcMappedFileObject != NULL && stack->FileObject == g_pProcMappedFileObject &&
        g_pProcRingMdl != NULL)
    {
        __try
        {
            MmUnmapLockedPages(g_pProcMappedUserAddress, g_pProcRingMdl);
            AURA_TRACE("Unmapped processed user address %p on process cleanup\n", g_pProcMappedUserAddress);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            AURA_TRACE("Exception unmapping processed in cleanup: 0x%08X\n", GetExceptionCode());
        }
        g_pProcMappedUserAddress = NULL;
        g_pProcMappedProcess = NULL;
        g_pProcMappedFileObject = NULL;
        if (g_pRingBuffer != NULL)
        {
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer)->CaptureSource = 0;
        }
    }
    // 持有者进程退出：释放 GET_DEBUG_LOG 的持久持有记录（审计低6）。
    if (g_pDebugLogHolder == currentProc)
    {
        g_pDebugLogHolder = NULL;
    }
    ExReleaseFastMutex(&g_MappingMutex);

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS
AuraControlDevice_DispatchDeviceControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    )
{
    PIO_STACK_LOCATION  stack;
    ULONG               controlCode;
    ULONG               inBufLen;
    ULONG               outBufLen;
    PVOID               systemBuffer;
    NTSTATUS            ntStatus = STATUS_INVALID_DEVICE_REQUEST;
    ULONG_PTR           bytesReturned = 0;
    KIRQL               oldIrql;

    UNREFERENCED_PARAMETER(DeviceObject);

    stack        = IoGetCurrentIrpStackLocation(Irp);
    controlCode  = stack->Parameters.DeviceIoControl.IoControlCode;
    inBufLen     = stack->Parameters.DeviceIoControl.InputBufferLength;
    outBufLen    = stack->Parameters.DeviceIoControl.OutputBufferLength;
    systemBuffer = Irp->AssociatedIrp.SystemBuffer;

    switch (controlCode)
    {
    case IOCTL_AURAVAIO_GET_VERSION:
        if (outBufLen < sizeof(AURA_VAIO_VERSION_INFO))
        {
            ntStatus = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        {
            PAURA_VAIO_VERSION_INFO pVer = reinterpret_cast<PAURA_VAIO_VERSION_INFO>(systemBuffer);
            RtlZeroMemory(pVer, sizeof(*pVer));
            pVer->DriverVersionMajor = 1;
            pVer->DriverVersionMinor = 0;
#if (defined(KMDF_VERSION_MINOR) && (KMDF_VERSION_MINOR == 11)) || defined(AURA_LEGACY_TRACK)
            pVer->KmdfMajor          = 1;
            pVer->KmdfMinor          = 11;
            pVer->Track              = 2; // Legacy (Win7/8/8.1)
#else
            pVer->KmdfMajor          = 1;
            pVer->KmdfMinor          = 15;
            pVer->Track              = 1; // Modern (Win10/11)
#endif
            // 全面复审 S5/S5b（VAIO-11 定案）：本驱动以 /d1nodatetime
            // 可复现构建，__DATE__/__TIME__ 被编译器禁用（S5 一度改用
            // 之，开发机 MSBuild 实测 C2065 而撤销）——BuildDate 的
            // 语义是「驱动源码版本日期」，随驱动源码变更手工同步；
            // BuildTime 在可复现构建下不跟踪钟点，恒 00:00:00。
            // 精确构建时刻看 INF 的 DriverVer（打包时由 MSBuild 盖戳）。
            RtlStringCchCopyA(pVer->BuildDate, sizeof(pVer->BuildDate), "2026-11-26");
            RtlStringCchCopyA(pVer->BuildTime, sizeof(pVer->BuildTime), "00:00:00");

            bytesReturned = sizeof(AURA_VAIO_VERSION_INFO);
            ntStatus = STATUS_SUCCESS;
        }
        break;

    case IOCTL_AURAVAIO_GET_STATUS:
        if (outBufLen < sizeof(AURA_VAIO_STATUS_INFO))
        {
            ntStatus = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        {
            PAURA_VAIO_STATUS_INFO pStatus = reinterpret_cast<PAURA_VAIO_STATUS_INFO>(systemBuffer);
            LARGE_INTEGER qpcFreq;
            KeQueryPerformanceCounter(&qpcFreq);

            KeAcquireSpinLock(&g_RingLock, &oldIrql);
            pStatus->ActiveRenderStreams  = (ULONG)g_lActiveRenderStreams;
            pStatus->ActiveCaptureStreams = (ULONG)g_lActiveCaptureStreams;
            pStatus->SampleRate           = g_ulCurrentSampleRate;
            pStatus->Channels             = g_ulCurrentChannels;
            pStatus->BitsPerSample        = g_ulCurrentBitsPerSample;
            pStatus->BlockAlign           = g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
            pStatus->RingBufferSizeBytes  = g_ulRingTotalSize;
            pStatus->MappedClientCount    = (g_pMappedUserAddress != NULL) ? 1 : 0;
            pStatus->TotalFramesWritten   = g_ullTotalFramesWritten;
            pStatus->TotalFramesRead      = g_ullTotalFramesRead;
            pStatus->QpcFrequency         = (ULONGLONG)qpcFreq.QuadPart;
            KeReleaseSpinLock(&g_RingLock, oldIrql);

            bytesReturned = sizeof(AURA_VAIO_STATUS_INFO);
            ntStatus = STATUS_SUCCESS;
        }
        break;

    case IOCTL_AURAVAIO_MAP_SHARED_RING:
        if (outBufLen < sizeof(AURA_VAIO_MAP_RESPONSE))
        {
            ntStatus = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        if (g_pRingMdl == NULL || g_pRingBuffer == NULL)
        {
            ntStatus = STATUS_DEVICE_NOT_READY;
            break;
        }
        {
            PAURA_VAIO_MAP_RESPONSE pResp = reinterpret_cast<PAURA_VAIO_MAP_RESPONSE>(systemBuffer);
            PEPROCESS currentProc = PsGetCurrentProcess();
            PVOID userVa = NULL;

            ExAcquireFastMutex(&g_MappingMutex);

            // If already mapped to this process, return existing user address
            if (g_pMappedUserAddress != NULL && g_pMappedProcess == currentProc)
            {
                userVa = g_pMappedUserAddress;
            }
            else if (g_pMappedUserAddress != NULL)
            {
                // DRV-04: Ring buffer is exclusively held by another process.
                // Reject hijack attempts with STATUS_DEVICE_BUSY instead of unmapping the owner.
                ExReleaseFastMutex(&g_MappingMutex);
                ntStatus = STATUS_DEVICE_BUSY;
                break;
            }
            else
            {
                __try
                {
                    userVa = MmMapLockedPagesSpecifyCache(
                                g_pRingMdl,
                                UserMode,
                                MmCached,
                                NULL,
                                FALSE,
                                NormalPagePriority | MdlMappingNoExecute);
                }
                __except (EXCEPTION_EXECUTE_HANDLER)
                {
                    userVa = NULL;
                    ntStatus = GetExceptionCode();
                }

                if (userVa != NULL)
                {
                    g_pMappedUserAddress = userVa;
                    g_pMappedProcess     = currentProc;
                    g_pMappedFileObject  = stack->FileObject;
                    g_pDebugLogHolder    = currentProc;
                }
            }

            if (userVa != NULL)
            {
                /* DRV-03：应答一律报内核真值——共享头在上一个映射者手里
                 * 可能已被改写，报它会把伪造几何递给新客户端。 */
                pResp->UserAddress          = userVa;
                pResp->TotalMappedSizeBytes = g_ulRingTotalSize;
                pResp->HeaderSizeBytes      = sizeof(AURA_VAIO_SHARED_HEADER);
                pResp->DataSizeBytes        = g_ulRingDataSize;
                pResp->SampleRate           = g_ulCurrentSampleRate;
                pResp->Channels             = g_ulCurrentChannels;
                pResp->BitsPerSample        = g_ulCurrentBitsPerSample;
                pResp->BlockAlign           = g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
                pResp->FormatKind           = g_ulCurrentFormatKind;
                pResp->ValidBitsPerSample   = g_ulCurrentValidBits;

                bytesReturned = sizeof(AURA_VAIO_MAP_RESPONSE);
                ntStatus = STATUS_SUCCESS;
                AURA_TRACE("MAP_SHARED_RING: userVa=%p, dataSize=%u\n", userVa, pResp->DataSizeBytes);
            }

            ExReleaseFastMutex(&g_MappingMutex);
        }
        break;

    case IOCTL_AURAVAIO_UNMAP_SHARED_RING:
        {
            PVOID reqAddress = NULL;
            if (inBufLen >= sizeof(AURA_VAIO_UNMAP_REQUEST) && systemBuffer != NULL)
            {
                PAURA_VAIO_UNMAP_REQUEST pReq = reinterpret_cast<PAURA_VAIO_UNMAP_REQUEST>(systemBuffer);
                reqAddress = pReq->UserAddress;
            }

            PEPROCESS currentProc = PsGetCurrentProcess();
            ExAcquireFastMutex(&g_MappingMutex);
            if (g_pMappedUserAddress != NULL)
            {
                if (g_pMappedProcess != NULL && g_pMappedProcess != currentProc)
                {
                    // DRV-04: Non-owning process cannot unmap another process's mapping
                    ExReleaseFastMutex(&g_MappingMutex);
                    ntStatus = STATUS_ACCESS_DENIED;
                    break;
                }

                if (reqAddress != NULL && reqAddress != g_pMappedUserAddress)
                {
                    ExReleaseFastMutex(&g_MappingMutex);
                    ntStatus = STATUS_INVALID_PARAMETER;
                    break;
                }

                if (g_pRingMdl != NULL)
                {
                    __try
                    {
                        MmUnmapLockedPages(g_pMappedUserAddress, g_pRingMdl);
                        AURA_TRACE("UNMAP_SHARED_RING: userVa=%p unmapped\n", g_pMappedUserAddress);
                    }
                    __except (EXCEPTION_EXECUTE_HANDLER)
                    {
                        ntStatus = GetExceptionCode();
                    }
                }
                g_pMappedUserAddress = NULL;
                g_pMappedProcess = NULL;
                g_pMappedFileObject = NULL;
                ntStatus = STATUS_SUCCESS;
            }
            else
            {
                ntStatus = STATUS_SUCCESS;
            }
            ExReleaseFastMutex(&g_MappingMutex);
        }
        break;

    case IOCTL_AURAVAIO_MAP_PROCESSED_RING:
        if (outBufLen < sizeof(AURA_VAIO_MAP_RESPONSE))
        {
            ntStatus = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        if (g_pProcRingMdl == NULL || g_pProcRingBuffer == NULL)
        {
            ntStatus = STATUS_DEVICE_NOT_READY;
            break;
        }
        {
            PAURA_VAIO_MAP_RESPONSE pResp = reinterpret_cast<PAURA_VAIO_MAP_RESPONSE>(systemBuffer);
            PEPROCESS currentProc = PsGetCurrentProcess();
            PVOID userVa = NULL;

            ExAcquireFastMutex(&g_MappingMutex);

            // 资格：仅渲染环持有进程（桥）可映射处理后环——处理后
            // 环是桥的写端，第三方进程拿到写权即可伪造录制内容。
            if (g_pMappedUserAddress == NULL || g_pMappedProcess != currentProc)
            {
                ExReleaseFastMutex(&g_MappingMutex);
                ntStatus = STATUS_DEVICE_NOT_READY;
                break;
            }

            if (g_pProcMappedUserAddress != NULL && g_pProcMappedProcess == currentProc)
            {
                userVa = g_pProcMappedUserAddress;
            }
            else if (g_pProcMappedUserAddress != NULL)
            {
                ExReleaseFastMutex(&g_MappingMutex);
                ntStatus = STATUS_DEVICE_BUSY;
                break;
            }
            else
            {
                __try
                {
                    userVa = MmMapLockedPagesSpecifyCache(
                                g_pProcRingMdl,
                                UserMode,
                                MmCached,
                                NULL,
                                FALSE,
                                NormalPagePriority | MdlMappingNoExecute);
                }
                __except (EXCEPTION_EXECUTE_HANDLER)
                {
                    userVa = NULL;
                    ntStatus = GetExceptionCode();
                }

                if (userVa != NULL)
                {
                    g_pProcMappedUserAddress = userVa;
                    g_pProcMappedProcess     = currentProc;
                    g_pProcMappedFileObject  = stack->FileObject;
                    /* [审查 H4 2026-11-26] 新会话锚定：处理后环的
                     * ReadOffset 与 TotalBytesRead 必须一起对齐当前写侧，
                     * 上一会话残留音频（最大约 340ms）才不会在本会话
                     * 开场被当新数据读走。仅新鲜映射时执行；同进程复用
                     * 既有映射不得跳过在途数据。g_MappingMutex 仍由外层
                     * 持有，自旋锁只保护这两个游标的更新。 */
                    if (g_pProcRingBuffer != NULL)
                    {
                        PAURA_VAIO_SHARED_HEADER pProcHdr =
                            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pProcRingBuffer);
                        KIRQL anchorOldIrql;
                        KeAcquireSpinLock(&g_RingLock, &anchorOldIrql);
                        AuraRingAnchorReadCursor(pProcHdr);
                        KeReleaseSpinLock(&g_RingLock, anchorOldIrql);
                    }
                }
            }

            if (userVa != NULL)
            {
                /* DRV-03：应答报内核真值，同 MAP_SHARED_RING。 */
                pResp->UserAddress          = userVa;
                pResp->TotalMappedSizeBytes = g_ulProcRingTotalSize;
                pResp->HeaderSizeBytes      = sizeof(AURA_VAIO_SHARED_HEADER);
                pResp->DataSizeBytes        = g_ulProcRingDataSize;
                pResp->SampleRate           = g_ulCurrentSampleRate;
                pResp->Channels             = g_ulCurrentChannels;
                pResp->BitsPerSample        = g_ulCurrentBitsPerSample;
                pResp->BlockAlign           = g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
                pResp->FormatKind           = g_ulCurrentFormatKind;
                pResp->ValidBitsPerSample   = g_ulCurrentValidBits;

                bytesReturned = sizeof(AURA_VAIO_MAP_RESPONSE);
                ntStatus = STATUS_SUCCESS;
                AURA_TRACE("MAP_PROCESSED_RING: userVa=%p, dataSize=%u\n", userVa, pResp->DataSizeBytes);
            }

            ExReleaseFastMutex(&g_MappingMutex);
        }
        break;

    case IOCTL_AURAVAIO_UNMAP_PROCESSED_RING:
        {
            PVOID reqAddress = NULL;
            if (inBufLen >= sizeof(AURA_VAIO_UNMAP_REQUEST) && systemBuffer != NULL)
            {
                PAURA_VAIO_UNMAP_REQUEST pReq = reinterpret_cast<PAURA_VAIO_UNMAP_REQUEST>(systemBuffer);
                reqAddress = pReq->UserAddress;
            }

            PEPROCESS currentProc = PsGetCurrentProcess();
            ExAcquireFastMutex(&g_MappingMutex);
            if (g_pProcMappedUserAddress != NULL)
            {
                if (g_pProcMappedProcess != NULL && g_pProcMappedProcess != currentProc)
                {
                    ExReleaseFastMutex(&g_MappingMutex);
                    ntStatus = STATUS_ACCESS_DENIED;
                    break;
                }

                if (reqAddress != NULL && reqAddress != g_pProcMappedUserAddress)
                {
                    ExReleaseFastMutex(&g_MappingMutex);
                    ntStatus = STATUS_INVALID_PARAMETER;
                    break;
                }

                if (g_pProcRingMdl != NULL)
                {
                    __try
                    {
                        MmUnmapLockedPages(g_pProcMappedUserAddress, g_pProcRingMdl);
                        AURA_TRACE("UNMAP_PROCESSED_RING: userVa=%p unmapped\n", g_pProcMappedUserAddress);
                    }
                    __except (EXCEPTION_EXECUTE_HANDLER)
                    {
                        ntStatus = GetExceptionCode();
                    }
                }
                g_pProcMappedUserAddress = NULL;
                g_pProcMappedProcess = NULL;
                g_pProcMappedFileObject = NULL;
                /* [审查 L2 2026-11-25] 纵深防御：映射已拆而录制源
                 * 仍指处理后环是语义错误中间态（此前靠桥侧自觉与
                 * Cleanup 兜底）；UNMAP 成功后在同一把锁内顺手清 0
                 * （回环源），不等桥侧复位。 */
                if (g_pRingBuffer != NULL)
                {
                    PAURA_VAIO_SHARED_HEADER pHdr =
                        reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);
                    if (pHdr->CaptureSource == AURA_VAIO_CAPTURE_PROCESSED)
                    {
                        pHdr->CaptureSource = AURA_VAIO_CAPTURE_LOOPBACK;
                    }
                }
                ntStatus = STATUS_SUCCESS;
            }
            else
            {
                ntStatus = STATUS_SUCCESS;
            }
            ExReleaseFastMutex(&g_MappingMutex);
        }
        break;

    case IOCTL_AURAVAIO_GET_DEBUG_LOG:
        if (outBufLen < sizeof(AURA_DEBUG_LOG))
        {
            ntStatus = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        // DRV-04 follow-up: reading the debug log drains it (copy + clear),
        // so while the ring is mapped, only the holding process may read it.
        // A non-holder must not be able to wipe the owner's diagnostics.
        // The holder snapshot is taken under g_RingLock and released before
        // g_DebugLock is acquired (no nested locking anywhere in this file).
        {
            PEPROCESS currentProc = PsGetCurrentProcess();
            BOOLEAN denied = FALSE;
            ExAcquireFastMutex(&g_MappingMutex);
            // 审计·调试低6：校验不能只在映射期生效——解映射后旧实现
            // 任意本地进程都能读走并清掉日志。映射中以当前持有者为
            // 准；解映射后以 g_pDebugLogHolder（最近一次成功 MAP 的
            // 进程）为准，直到该进程退出由 Cleanup 清除记录。从未
            // MAP 过时不设防（此时日志只有格式协商记录，探针工具的
            // 独立读取依赖这一点）。
            {
                const PEPROCESS holder = (g_pMappedUserAddress != NULL)
                                             ? g_pMappedProcess
                                             : g_pDebugLogHolder;
                if (holder != NULL && holder != currentProc)
                {
                    denied = TRUE;
                }
            }
            ExReleaseFastMutex(&g_MappingMutex);
            if (denied)
            {
                ntStatus = STATUS_ACCESS_DENIED;
                break;
            }
        }
        {
            PAURA_DEBUG_LOG pLog = reinterpret_cast<PAURA_DEBUG_LOG>(systemBuffer);
            KeAcquireSpinLock(&g_DebugLock, &oldIrql);
            RtlCopyMemory(pLog, &g_DebugLog, sizeof(AURA_DEBUG_LOG));
            g_DebugLog.Count = 0;
            g_DebugLog.WriteIndex = 0;
            RtlZeroMemory(g_DebugLog.Entries, sizeof(g_DebugLog.Entries));
            KeReleaseSpinLock(&g_DebugLock, oldIrql);
            bytesReturned = sizeof(AURA_DEBUG_LOG);
            ntStatus = STATUS_SUCCESS;
        }
        break;

    default:
        ntStatus = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    Irp->IoStatus.Status = ntStatus;
    Irp->IoStatus.Information = bytesReturned;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return ntStatus;
}

//=============================================================================
// Audio Stream Integration
//=============================================================================

VOID
AuraControlDevice_OnStreamStateChange(
    _In_ BOOLEAN Capture,
    _In_ KSSTATE State
    )
{
    // Capture 自 VAIO-3 起不再参与计数（边沿函数专责），保留形参
    // 是为调用面稳定；状态字段本身与方向无关。
    UNREFERENCED_PARAMETER(Capture);
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;

    if (g_pRingBuffer == NULL) return;

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);

    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    // 共享头 StreamState 口径（AuraVaioIpc.h：0=STOP/1=ACQUIRE/
    // 2=PAUSE/3=RUN）与 KSSTATE 枚举原值（ks.h：KSSTATE_STOP=0 起）
    // 本就逐一对应，直写原值即文档编码——全面复审 VAIO-4 曾误判
    // KSSTATE 自 1 起、险些引入差一错误，特此钉注勿「修正」。
    // 活跃计数已移至 RUN 边沿通知 OnStreamRunEdge（VAIO-3)，本
    // 函数只维护状态字段。
    pHeader->StreamState = (ULONG)State;
    KeReleaseSpinLock(&g_RingLock, oldIrql);
}

VOID
AuraControlDevice_OnStreamRunEdge(
    _In_ BOOLEAN Capture,
    _In_ BOOLEAN Entering
    )
{
    // 边沿计数：每条流在 RUN 期间恰贡献 +1，离开（或运行中析构）
    // 恰 -1，与状态机调用次数无关（VAIO-3)。
    if (Capture)
    {
        if (Entering) InterlockedIncrement(&g_lActiveCaptureStreams);
        else InterlockedDecrement(&g_lActiveCaptureStreams);
        if (g_lActiveCaptureStreams < 0) g_lActiveCaptureStreams = 0;
    }
    else
    {
        if (Entering) InterlockedIncrement(&g_lActiveRenderStreams);
        else InterlockedDecrement(&g_lActiveRenderStreams);
        if (g_lActiveRenderStreams < 0) g_lActiveRenderStreams = 0;
    }
}

VOID
AuraControlDevice_OnFormatChange(
    _In_ BOOLEAN Capture,
    _In_ ULONG SampleRate,
    _In_ ULONG Channels,
    _In_ ULONG BitsPerSample,
    _In_ ULONG FormatKind,
    _In_ ULONG ValidBitsPerSample
    )
{
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;

    // 全面复审 S5（VAIO-1)：共享头几何与 g_ulCurrent* 只描述渲染
    // 方向（环数据流与桥协商的真源）；捕获流的格式变化此前会把
    // 播放几何整组冲掉（麦克风协商 44.1k 后桥按错几何读渲染环）。
    // 捕获格式只活在流自身成员里（DMA 步进用），此处直接返回。
    if (Capture) return;

    if (g_pRingBuffer == NULL) return;

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);

    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    g_ulCurrentSampleRate    = SampleRate;
    g_ulCurrentChannels      = Channels;
    g_ulCurrentBitsPerSample = BitsPerSample;
    g_ulCurrentFormatKind    = FormatKind;
    g_ulCurrentValidBits     = ValidBitsPerSample;

    pHeader->SampleRate      = SampleRate;
    pHeader->Channels        = Channels;
    pHeader->BitsPerSample   = BitsPerSample;
    pHeader->BlockAlign      = Channels * (BitsPerSample / 8);
    pHeader->FormatKind      = FormatKind;
    pHeader->ValidBitsPerSample = ValidBitsPerSample;
    // 处理后环格式恒跟随渲染流（桥按渲染协商格式写入），同批镜像。
    if (g_pProcRingBuffer != NULL)
    {
        PAURA_VAIO_SHARED_HEADER pProcHeader =
            reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pProcRingBuffer);
        pProcHeader->SampleRate         = SampleRate;
        pProcHeader->Channels           = Channels;
        pProcHeader->BitsPerSample      = BitsPerSample;
        pProcHeader->BlockAlign         = Channels * (BitsPerSample / 8);
        pProcHeader->FormatKind         = FormatKind;
        pProcHeader->ValidBitsPerSample = ValidBitsPerSample;
    }
    KeReleaseSpinLock(&g_RingLock, oldIrql);
}

VOID
AuraControlDevice_WriteRenderSamples(
    _In_reads_bytes_(ByteCount) const BYTE * Buffer,
    _In_ ULONG ByteCount
    )
{
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;
    PBYTE pPayload;
    ULONG dataSize;
    ULONG writeOffset;
    ULONG chunk1, chunk2;

    if (g_pRingBuffer == NULL || Buffer == NULL || ByteCount == 0) return;

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);
    /* DRV-03（全项目审查 S7）：几何必须由内核自有真值派生，绝不能读
     * 共享头——共享头对映射进程可写，DataOffsetBytes/DataSizeBytes 被
     * 改大即可让下面的 RtlCopyMemory 写出环外（蓝屏/提权级）。共享头
     * 里的同名字段今后只作展示副本；WriteOffset/TotalBytes 等仍经
     * dataSize 取模/钳制，影响面被关进环内。 */
    if (g_ulRingTotalSize <= sizeof(AURA_VAIO_SHARED_HEADER)) return;
    pPayload = g_pRingBuffer + sizeof(AURA_VAIO_SHARED_HEADER);
    dataSize = g_ulRingDataSize;   // 格式升级一期：288 贴格后的内核真值

    if (dataSize == 0) return;

    KeAcquireSpinLock(&g_RingLock, &oldIrql);

    writeOffset = pHeader->WriteOffset % dataSize;

    if (ByteCount >= dataSize)
    {
        // Wrap overflow: keep latest dataSize bytes
        Buffer += (ByteCount - dataSize);
        ByteCount = dataSize;
    }

    chunk1 = dataSize - writeOffset;
    if (chunk1 >= ByteCount)
    {
        RtlCopyMemory(pPayload + writeOffset, Buffer, ByteCount);
        writeOffset = (writeOffset + ByteCount) % dataSize;
    }
    else
    {
        chunk2 = ByteCount - chunk1;
        RtlCopyMemory(pPayload + writeOffset, Buffer, chunk1);
        RtlCopyMemory(pPayload, Buffer + chunk1, chunk2);
        writeOffset = chunk2 % dataSize;
    }

    pHeader->WriteOffset = writeOffset;
    pHeader->TotalBytesWritten += ByteCount;
    /* DRV-03：帧计数同样只用内核侧格式真值，不读共享头 BlockAlign。 */
    {
        const ULONG blockAlign =
            g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
        if (blockAlign > 0)
            g_ullTotalFramesWritten += (ByteCount / blockAlign);
    }

    KeReleaseSpinLock(&g_RingLock, oldIrql);
}

// 处理后回写环读端（2026-11-23 S1)：与渲染环读端同纪律——可用
// 量由单调计数差派生、超环钳制 snap、不足补静音；几何一律内核
// 真值（DRV-03)，不读处理后环共享头的几何字段。生产者（桥）不
// 在 g_RingLock 内更新 WriteOffset/TotalBytesWritten:volatile 单
// 调计数保证此处读到的差值只会偏小、不会越界（与桥读渲染环时
// 读内核计数同式）。
static VOID
ReadProcessedCaptureSamples(
    _Out_writes_bytes_(ByteCount) BYTE * Buffer,
    _In_ ULONG ByteCount
    )
{
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;
    PBYTE pPayload;
    ULONG dataSize;
    ULONG readOffset;
    ULONG chunk1, chunk2;

    if (g_pProcRingBuffer == NULL || g_ulProcRingDataSize == 0 ||
        g_ulProcRingTotalSize <= sizeof(AURA_VAIO_SHARED_HEADER))
    {
        RtlZeroMemory(Buffer, ByteCount);
        return;
    }

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pProcRingBuffer);
    pPayload = g_pProcRingBuffer + sizeof(AURA_VAIO_SHARED_HEADER);
    dataSize = g_ulProcRingDataSize;

    KeAcquireSpinLock(&g_RingLock, &oldIrql);

    ULONGLONG totalWritten = pHeader->TotalBytesWritten;
    ULONGLONG totalRead    = pHeader->TotalBytesRead;
    ULONG     available    = 0;

    if (totalWritten > totalRead)
    {
        ULONGLONG diff = totalWritten - totalRead;
        if (diff > (ULONGLONG)dataSize)
        {
            diff = (ULONGLONG)dataSize;
            pHeader->ReadOffset = (pHeader->WriteOffset + dataSize - (ULONG)diff) % dataSize;
            pHeader->TotalBytesRead = totalWritten - diff;
        }
        available = (ULONG)diff;
    }

    ULONG bytesToCopy  = (ByteCount < available) ? ByteCount : available;
    ULONG silenceBytes = ByteCount - bytesToCopy;

    if (bytesToCopy > 0)
    {
        readOffset = pHeader->ReadOffset % dataSize;
        chunk1 = dataSize - readOffset;
        if (chunk1 >= bytesToCopy)
        {
            RtlCopyMemory(Buffer, pPayload + readOffset, bytesToCopy);
            readOffset = (readOffset + bytesToCopy) % dataSize;
        }
        else
        {
            chunk2 = bytesToCopy - chunk1;
            RtlCopyMemory(Buffer, pPayload + readOffset, chunk1);
            RtlCopyMemory(Buffer + chunk1, pPayload, chunk2);
            readOffset = chunk2 % dataSize;
        }

        pHeader->ReadOffset = readOffset;
        pHeader->TotalBytesRead += bytesToCopy;
        {
            const ULONG blockAlign =
                g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
            if (blockAlign > 0)
                g_ullTotalFramesRead += (bytesToCopy / blockAlign);
        }
    }

    if (silenceBytes > 0)
    {
        RtlZeroMemory(Buffer + bytesToCopy, silenceBytes);
    }

    KeReleaseSpinLock(&g_RingLock, oldIrql);
}

VOID
AuraControlDevice_ReadCaptureSamples(
    _Out_writes_bytes_(ByteCount) BYTE * Buffer,
    _In_ ULONG ByteCount
    )
{
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;
    PBYTE pPayload;
    ULONG dataSize;
    ULONG readOffset;
    ULONG chunk1, chunk2;

    if (Buffer == NULL || ByteCount == 0) return;

    if (g_pRingBuffer == NULL)
    {
        RtlZeroMemory(Buffer, ByteCount);
        return;
    }

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);
    /* 录制源选择（2026-11-23 S1 三态，A 案静音并入其一）：源只是
     * 语义开关、非几何，DRV-03 的「不读共享头几何」纪律不适用。
     * 静音时不回放处理前原始流、不推进读偏移（桥按
     * TotalBytesWritten 自行记账，录制侧消费与否不影响它）；
     * 源字段为 0 而静音标记置位时按静音处理，兼容只认静音标记
     * 的 r64 桥。 */
    {
        ULONG captureSource = pHeader->CaptureSource;
        if (captureSource == AURA_VAIO_CAPTURE_LOOPBACK &&
            pHeader->CaptureMuted != 0)
        {
            captureSource = AURA_VAIO_CAPTURE_MUTED;
        }
        if (captureSource == AURA_VAIO_CAPTURE_MUTED)
        {
            RtlZeroMemory(Buffer, ByteCount);
            return;
        }
        if (captureSource == AURA_VAIO_CAPTURE_PROCESSED)
        {
            ReadProcessedCaptureSamples(Buffer, ByteCount);
            return;
        }
    }
    /* DRV-03：同 WriteRenderSamples——几何由内核真值派生，不读共享头。 */
    if (g_ulRingTotalSize <= sizeof(AURA_VAIO_SHARED_HEADER))
    {
        RtlZeroMemory(Buffer, ByteCount);
        return;
    }
    pPayload = g_pRingBuffer + sizeof(AURA_VAIO_SHARED_HEADER);
    dataSize = g_ulRingDataSize;   // 格式升级一期：288 贴格后的内核真值

    if (dataSize == 0)
    {
        RtlZeroMemory(Buffer, ByteCount);
        return;
    }

    KeAcquireSpinLock(&g_RingLock, &oldIrql);

    ULONGLONG totalWritten = pHeader->TotalBytesWritten;
    ULONGLONG totalRead    = pHeader->TotalBytesRead;
    ULONG     available    = 0;

    if (totalWritten > totalRead)
    {
        ULONGLONG diff = totalWritten - totalRead;
        if (diff > (ULONGLONG)dataSize)
        {
            diff = (ULONGLONG)dataSize;
            pHeader->ReadOffset = (pHeader->WriteOffset + dataSize - (ULONG)diff) % dataSize;
            pHeader->TotalBytesRead = totalWritten - diff;
        }
        available = (ULONG)diff;
    }

    ULONG bytesToCopy  = (ByteCount < available) ? ByteCount : available;
    ULONG silenceBytes = ByteCount - bytesToCopy;

    if (bytesToCopy > 0)
    {
        readOffset = pHeader->ReadOffset % dataSize;
        chunk1 = dataSize - readOffset;
        if (chunk1 >= bytesToCopy)
        {
            RtlCopyMemory(Buffer, pPayload + readOffset, bytesToCopy);
            readOffset = (readOffset + bytesToCopy) % dataSize;
        }
        else
        {
            chunk2 = bytesToCopy - chunk1;
            RtlCopyMemory(Buffer, pPayload + readOffset, chunk1);
            RtlCopyMemory(Buffer + chunk1, pPayload, chunk2);
            readOffset = chunk2 % dataSize;
        }

        pHeader->ReadOffset = readOffset;
        pHeader->TotalBytesRead += bytesToCopy;
        {
            const ULONG blockAlign =
                g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
            if (blockAlign > 0)
                g_ullTotalFramesRead += (bytesToCopy / blockAlign);
        }
    }

    if (silenceBytes > 0)
    {
        RtlZeroMemory(Buffer + bytesToCopy, silenceBytes);
    }

    KeReleaseSpinLock(&g_RingLock, oldIrql);
}

VOID
AuraControlDevice_LogIntersection(
    _In_ const AURA_INTERSECTION_LOG_ENTRY * Entry
    )
{
    KIRQL oldIrql;
    KeAcquireSpinLock(&g_DebugLock, &oldIrql);
    // 审计·调试低7：真环形（写满后覆盖最旧）+ 驱动侧盖系统时间戳。
    // 旧实现是 32 条写满即丢弃新条目且无时间：长会话里最关键的首
    // 发交集记录反而留不住，也无法与用户态日志对时。
    {
        AURA_INTERSECTION_LOG_ENTRY stamped = *Entry;
        LARGE_INTEGER now = {0};
        KeQuerySystemTime(&now);
        stamped.Timestamp100ns = static_cast<ULONGLONG>(now.QuadPart);
        g_DebugLog.Entries[g_DebugLog.WriteIndex % 32] = stamped;
        g_DebugLog.WriteIndex++;
        if (g_DebugLog.Count < 32)
        {
            g_DebugLog.Count++;
        }
    }
    KeReleaseSpinLock(&g_DebugLock, oldIrql);
}
