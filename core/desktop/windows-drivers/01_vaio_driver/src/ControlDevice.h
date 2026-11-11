/*++

Module Name:

    ControlDevice.h

Abstract:

    Control device object and shared memory ring buffer management for
    the AuraVAIO kernel driver.

    Exposes \\Device\\AuraVaioControl (\\.\AuraVaioControl) for user-mode
    IOCTL communication and zero-copy shared ring buffer mapping.

--*/

#ifndef _CONTROL_DEVICE_H_
#define _CONTROL_DEVICE_H_

#include "AuraVaio.h"
#include "../../common/AuraVaioIpc.h"

#ifdef __cplusplus
extern "C" {
#endif

//
// Lifecycle
//
NTSTATUS
AuraControlDevice_Create(
    _In_ PDRIVER_OBJECT DriverObject
    );

VOID
AuraControlDevice_Destroy(
    _In_ PDRIVER_OBJECT DriverObject
    );

BOOLEAN
AuraControlDevice_IsControlDevice(
    _In_ PDEVICE_OBJECT DeviceObject
    );

//
// IRP Dispatchers
//
NTSTATUS
AuraControlDevice_DispatchCreate(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    );

NTSTATUS
AuraControlDevice_DispatchClose(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    );

NTSTATUS
AuraControlDevice_DispatchCleanup(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    );

NTSTATUS
AuraControlDevice_DispatchDeviceControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP        Irp
    );

//
// Audio Stream Integration (called from MiniportWaveRTStream)
//
VOID
AuraControlDevice_OnStreamStateChange(
    _In_ BOOLEAN Capture,
    _In_ KSSTATE State
    );

//
// Active-stream counting on RUN edges only （全面复审 S5 / VAIO-3):
// called by the stream when it enters (Entering=TRUE) or leaves
// KSSTATE_RUN, including destruction while running. Plain state
// notifications go through OnStreamStateChange and never count.
//
VOID
AuraControlDevice_OnStreamRunEdge(
    _In_ BOOLEAN Capture,
    _In_ BOOLEAN Entering
    );

//
// 全面复审 S5（VAIO-1)：共享头几何（SampleRate/Channels/Bits +
// g_ulCurrent*）只描述渲染方向——环内数据流与桥的协商都以渲染
// 端点格式为准。Capture=TRUE 的调用不发布头几何（捕获格式只存
// 流自身的成员），避免麦克风端点协商把播放几何冲掉。
//
VOID
AuraControlDevice_OnFormatChange(
    _In_ BOOLEAN Capture,
    _In_ ULONG SampleRate,
    _In_ ULONG Channels,
    _In_ ULONG BitsPerSample
    );

VOID
AuraControlDevice_WriteRenderSamples(
    _In_reads_bytes_(ByteCount) const BYTE * Buffer,
    _In_ ULONG ByteCount
    );

VOID
AuraControlDevice_ReadCaptureSamples(
    _Out_writes_bytes_(ByteCount) BYTE * Buffer,
    _In_ ULONG ByteCount
    );

VOID
AuraControlDevice_LogIntersection(
    _In_ const AURA_INTERSECTION_LOG_ENTRY * Entry
    );

#ifdef __cplusplus
}
#endif

#endif // _CONTROL_DEVICE_H_
