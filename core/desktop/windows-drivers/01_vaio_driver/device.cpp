// device.cpp — MODERN 主线 KMDF 骨架
// 最小骨架：创建一个 Root 枚举的软件设备，证明驱动可加载。
// TODO(modern): 替换为 PortCls WaveRT 微端口（IMiniportWaveRT），参考
//               Windows-driver-samples/audio/sysvad。
#include "device.h"

NTSTATUS
AuraVaioEvtDeviceAdd(
    _In_    WDFDRIVER        Driver,
    _Inout_ PWDFDEVICE_INIT  DeviceInit
    )
{
    WDFDEVICE device;
    NTSTATUS status = WdfDeviceCreate(&DeviceInit, WDF_NO_OBJECT_ATTRIBUTES, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    // TODO(modern): 创建设备接口（GUID_DEVINTERFACE_...）供用户态引擎映射共享环形缓冲。
    UNREFERENCED_PARAMETER(Driver);
    return STATUS_SUCCESS;
}
