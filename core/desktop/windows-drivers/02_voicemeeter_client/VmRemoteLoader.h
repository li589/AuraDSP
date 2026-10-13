// VmRemoteLoader.h — Voicemeeter 三级自省检测（SPEC-WIN-DRIVER-001 §2.1）。
//
// Tier 1（注册表安全寻址）：HKLM Uninstall 下 `VB:Voicemeeter*`（含 Wow6432Node），
//   读安装目录。绝不猜安装包文件名（EqualizerAPO 式脆弱）。
// Tier 2（动态原生 API 自省，主轨道）：LoadLibrary Remote DLL → VBVMR_Login →
//   GetType（1/2/3）+ GetVersion。API 活着即 100% 准确。
// Tier 3（PE 静态校验，备选）：Voicemeeter8/Pro/Main exe 存在性定版型 +
//   GetFileVersionInfo 取真实签名版本（服务未起、API 超时时兜底）。
//
// 用户态纯 Win32 API，无需 WDK/管理员。RT 无关（进程启动/设置页查询时调一次）。
#pragma once

#include <string>

struct AuraVmDetect {
    bool found = false;       // 任一 tier 命中安装
    int edition = 0;          // 0=none 1=Standard 2=Banana 3=Potato
    std::string editionName;  // "Standard"/"Banana"/"Potato"/""
    std::string installDir;   // UTF-8
    std::string appVersion;   // 主程序签名版本，如 "3.1.1.9"（tier3）
    std::string remoteVersion;  // Remote DLL 版本（tier2 或 DLL 文件版本兜底）
    int tierReached = 0;      // 实际命中的最高 tier
};

const char* AuraVmEditionName(int edition);
AuraVmDetect AuraVmDetectRun();
