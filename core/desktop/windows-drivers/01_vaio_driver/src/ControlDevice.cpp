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

//=============================================================================
// Globals
//=============================================================================

static PDEVICE_OBJECT           g_pControlDeviceObject  = NULL;
static PBYTE                    g_pRingBuffer           = NULL;
static ULONG                    g_ulRingTotalSize       = 0;
static PMDL                     g_pRingMdl              = NULL;
static PVOID                    g_pMappedUserAddress    = NULL;
static PEPROCESS                g_pMappedProcess        = NULL;
static KSPIN_LOCK               g_RingLock;
static LONG                     g_lActiveRenderStreams  = 0;
static LONG                     g_lActiveCaptureStreams = 0;
static ULONG                    g_ulCurrentSampleRate   = AURA_DEFAULT_SAMPLE_RATE;
static ULONG                    g_ulCurrentChannels     = AURA_DEFAULT_CHANNELS;
static ULONG                    g_ulCurrentBitsPerSample= AURA_DEFAULT_BITS_PER_SAMPLE;
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
    RtlZeroMemory(&g_DebugLog, sizeof(g_DebugLog));

    RtlInitUnicodeString(&ntDeviceName, AURA_VAIO_DEVICE_NAME_NT);
    RtlInitUnicodeString(&dosDeviceName, AURA_VAIO_DOS_DEVICE_NAME);

    ntStatus = IoCreateDevice(
                    DriverObject,
                    0,
                    &ntDeviceName,
                    FILE_DEVICE_UNKNOWN,
                    0,
                    FALSE,
                    &g_pControlDeviceObject);
    if (!NT_SUCCESS(ntStatus))
    {
        AURA_TRACE("IoCreateDevice failed, 0x%08X\n", ntStatus);
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
    pHeader->DataSizeBytes          = allocSize - sizeof(AURA_VAIO_SHARED_HEADER);
    pHeader->SampleRate             = g_ulCurrentSampleRate;
    pHeader->Channels               = g_ulCurrentChannels;
    pHeader->BitsPerSample          = g_ulCurrentBitsPerSample;
    pHeader->BlockAlign             = g_ulCurrentChannels * (g_ulCurrentBitsPerSample / 8);
    pHeader->WriteOffset            = 0;
    pHeader->ReadOffset             = 0;
    pHeader->TotalBytesWritten      = 0;
    pHeader->TotalBytesRead         = 0;
    pHeader->StreamState            = 0; // STOP

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
    KIRQL oldIrql;

    UNREFERENCED_PARAMETER(DriverObject);

    AURA_TRACE("AuraControlDevice_Destroy\n");

    KeAcquireSpinLock(&g_RingLock, &oldIrql);
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
    }
    KeReleaseSpinLock(&g_RingLock, oldIrql);

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
    KIRQL oldIrql;
    PEPROCESS currentProc = PsGetCurrentProcess();

    UNREFERENCED_PARAMETER(DeviceObject);
    AURA_TRACE("ControlDevice Cleanup (proc=%p)\n", currentProc);

    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    if (g_pMappedUserAddress != NULL && g_pMappedProcess == currentProc && g_pRingMdl != NULL)
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
    }
    KeReleaseSpinLock(&g_RingLock, oldIrql);

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
            RtlStringCchCopyA(pVer->BuildDate, sizeof(pVer->BuildDate), "2026-10-16");
            RtlStringCchCopyA(pVer->BuildTime, sizeof(pVer->BuildTime), "12:00:00");

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
            PAURA_VAIO_SHARED_HEADER pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);
            PEPROCESS currentProc = PsGetCurrentProcess();
            PVOID userVa = NULL;

            KeAcquireSpinLock(&g_RingLock, &oldIrql);

            // If already mapped to this process, return existing user address
            if (g_pMappedUserAddress != NULL && g_pMappedProcess == currentProc)
            {
                userVa = g_pMappedUserAddress;
            }
            else
            {
                // Unmap previous mapping if another process had it open
                if (g_pMappedUserAddress != NULL)
                {
                    __try
                    {
                        MmUnmapLockedPages(g_pMappedUserAddress, g_pRingMdl);
                    }
                    __except (EXCEPTION_EXECUTE_HANDLER) {}
                    g_pMappedUserAddress = NULL;
                    g_pMappedProcess = NULL;
                }

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
                }
            }

            if (userVa != NULL)
            {
                pResp->UserAddress          = userVa;
                pResp->TotalMappedSizeBytes = g_ulRingTotalSize;
                pResp->HeaderSizeBytes      = pHeader->HeaderSizeBytes;
                pResp->DataSizeBytes        = pHeader->DataSizeBytes;
                pResp->SampleRate           = pHeader->SampleRate;
                pResp->Channels             = pHeader->Channels;
                pResp->BitsPerSample        = pHeader->BitsPerSample;
                pResp->BlockAlign           = pHeader->BlockAlign;

                bytesReturned = sizeof(AURA_VAIO_MAP_RESPONSE);
                ntStatus = STATUS_SUCCESS;
                AURA_TRACE("MAP_SHARED_RING: userVa=%p, dataSize=%u\n", userVa, pHeader->DataSizeBytes);
            }

            KeReleaseSpinLock(&g_RingLock, oldIrql);
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
            KeAcquireSpinLock(&g_RingLock, &oldIrql);
            if (g_pMappedUserAddress != NULL && g_pRingMdl != NULL &&
                (reqAddress == NULL || reqAddress == g_pMappedUserAddress) &&
                (g_pMappedProcess == NULL || g_pMappedProcess == currentProc))
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
                g_pMappedUserAddress = NULL;
                g_pMappedProcess = NULL;
                ntStatus = STATUS_SUCCESS;
            }
            else
            {
                ntStatus = (g_pMappedUserAddress == NULL) ? STATUS_SUCCESS : STATUS_INVALID_PARAMETER;
            }
            KeReleaseSpinLock(&g_RingLock, oldIrql);
        }
        break;

    case IOCTL_AURAVAIO_GET_DEBUG_LOG:
        if (outBufLen < sizeof(AURA_DEBUG_LOG))
        {
            ntStatus = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        {
            PAURA_DEBUG_LOG pLog = reinterpret_cast<PAURA_DEBUG_LOG>(systemBuffer);
            KeAcquireSpinLock(&g_DebugLock, &oldIrql);
            RtlCopyMemory(pLog, &g_DebugLog, sizeof(AURA_DEBUG_LOG));
            g_DebugLog.Count = 0;
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
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;

    if (g_pRingBuffer == NULL) return;

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);

    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    if (Capture)
    {
        if (State == KSSTATE_RUN) InterlockedIncrement(&g_lActiveCaptureStreams);
        else if (State == KSSTATE_STOP) InterlockedDecrement(&g_lActiveCaptureStreams);
    }
    else
    {
        if (State == KSSTATE_RUN) InterlockedIncrement(&g_lActiveRenderStreams);
        else if (State == KSSTATE_STOP) InterlockedDecrement(&g_lActiveRenderStreams);
    }

    if (g_lActiveRenderStreams < 0) g_lActiveRenderStreams = 0;
    if (g_lActiveCaptureStreams < 0) g_lActiveCaptureStreams = 0;

    pHeader->StreamState = (ULONG)State;
    KeReleaseSpinLock(&g_RingLock, oldIrql);
}

VOID
AuraControlDevice_OnFormatChange(
    _In_ ULONG SampleRate,
    _In_ ULONG Channels,
    _In_ ULONG BitsPerSample
    )
{
    KIRQL oldIrql;
    PAURA_VAIO_SHARED_HEADER pHeader;

    if (g_pRingBuffer == NULL) return;

    pHeader = reinterpret_cast<PAURA_VAIO_SHARED_HEADER>(g_pRingBuffer);

    KeAcquireSpinLock(&g_RingLock, &oldIrql);
    g_ulCurrentSampleRate    = SampleRate;
    g_ulCurrentChannels      = Channels;
    g_ulCurrentBitsPerSample = BitsPerSample;

    pHeader->SampleRate      = SampleRate;
    pHeader->Channels        = Channels;
    pHeader->BitsPerSample   = BitsPerSample;
    pHeader->BlockAlign      = Channels * (BitsPerSample / 8);
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
    pPayload = g_pRingBuffer + pHeader->DataOffsetBytes;
    dataSize = pHeader->DataSizeBytes;

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
    if (pHeader->BlockAlign > 0)
    {
        g_ullTotalFramesWritten += (ByteCount / pHeader->BlockAlign);
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
    pPayload = g_pRingBuffer + pHeader->DataOffsetBytes;
    dataSize = pHeader->DataSizeBytes;

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
        if (pHeader->BlockAlign > 0)
        {
            g_ullTotalFramesRead += (bytesToCopy / pHeader->BlockAlign);
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
    if (g_DebugLog.Count < 32)
    {
        g_DebugLog.Entries[g_DebugLog.Count] = *Entry;
        g_DebugLog.Count++;
    }
    KeReleaseSpinLock(&g_DebugLock, oldIrql);
}
