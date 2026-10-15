// driver.cpp — MODERN 主线 KMDF 骨架
// 仅用于打通 WDK 28000 + VS2026 工具链；不含任何音频逻辑。
#include "device.h"

extern "C" NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, AuraVaioEvtDeviceAdd);

    // TODO(modern): 真实驱动需注册 WaveRT 微端口、分配非分页环形缓冲、暴露设备接口给引擎。
    return WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        WDF_NO_HANDLE);
}
