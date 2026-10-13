// ApoInspector.h — APO 只读检测（SPEC Phase 2 前半；写操作是 Configurator 的事）。
//
// 只读 MMDevices + HKCR，不提权、不写注册表、不碰音频服务。
// 覆盖 EAPO DeviceAPOInfo::load 的检测子集（见借鉴注）：
//  端点枚举（Render/Capture）→ DeviceState → FxProperties 五槽位 GUID →
//  ProcessingModes → DisableEnhancements → FxFriendlyName →
//  全局 DisableProtectedAudioDG 签名开关。
// 自家 APO 尚不存在：只报现状（装了谁、增强开没开），不判“该装没装”。
#pragma once

#include <string>
#include <vector>

struct ApoSlot {
    std::string key;    // 如 "{d04e05a6-...},5"
    std::string value;  // GUID 字符串或 ""（无值/不可读）
};

struct ApoEndpoint {
    std::string id;          // endpoint GUID（含花括号）
    std::string direction;   // "render" / "capture"
    std::string name;        // UTF-8 friendly name
    unsigned long state = 0;  // DEVICE_STATE_*（1=active）
    bool enhancementsDisabled = false;  // {1da5d803},5 == 1（系统级 bypass）
    std::vector<ApoSlot> fx;  // LFX/GFX/SFX/MFX/EFX 五槽
    std::string friendlyName;  // FxFriendlyName（装了谁的 APO 常写这里）
    bool readable = true;     // FxProperties 可读（不可读置 false，不判 FAIL）
};

struct ApoInspect {
    std::vector<ApoEndpoint> endpoints;
    std::string defaultRender;   // 默认播放端点 id（eConsole；空=取不到）
    std::string defaultCapture;  // 默认录音端点 id
    int protectedAudioDG = -1;  // DisableProtectedAudioDG：1=关签名强制（unsigned 可载）
                                // 0/缺失=强制签名；-1=读不到
    std::string note;  // 非致命说明（如 COM 初始化失败）
};

ApoInspect ApoInspectRun();
