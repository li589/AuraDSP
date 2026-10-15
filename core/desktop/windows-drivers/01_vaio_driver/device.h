// device.h — MODERN 主线 KMDF 骨架头文件
#pragma once
#include <ntddk.h>
#include <wdf.h>

// 真正的 AuraVAIO WaveRT 微端口入口后续在此声明（移植 sysvad）。
EVT_WDF_DRIVER_DEVICE_ADD AuraVaioEvtDeviceAdd;
