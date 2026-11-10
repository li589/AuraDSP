#pragma once
// apo_install_plan.h — 安装计划解析（纯逻辑、无 Win32 依赖，可独立
// 单测，见 apo_plan_test.cpp）。模式 + 前后混限定 + 端点方向 + OS
// 代际 → 本次安装要写的槽位集合与要跨模式清理的槽位集合。
//
// 槽位以 apo_config.cpp SlotKeys() 的下标指代（两处必须同序）：
//   0=Fx,0 Association   1=Fx,1 LFX    2=Fx,2 GFX
//   3=Fx,5 SFX           4=Fx,6 MFX    5=Fx,7 EFX
//   6=Fx,13 CompSFX      7=Fx,14 CompMFX   8=Fx,15 CompEFX
//   9=DisableEnh,5       10..12=ProcModes,5/6/7
//
// 借鉴 EqualizerAPO 的三点（计划书 Part II W1）：
//  - 跨模式清理：装一档时其他代际/模式的槽位恢复原始值（foreignIdx），
//    消除换模式残留双注册；
//  - 前后混独立：--only pre 只装流侧（LFX/SFX/CompSFX），
//    --only post 只装设备侧（GFX/MFX/EFX/CompMFX）；
//  - 捕获端点默认只装 pre（post 从不上捕获端，EAPO 同）；显式
//    --only post 时以操作者意图为准。
// 全量（无 --only）各模式的写集合与 2026-11-10 前的既有行为逐项
// 一致（回归基线，apo_plan_test 钉死）。
#include <algorithm>
#include <string>
#include <vector>

namespace apoplan {

enum class Only { None, Pre, Post };

struct InstallPlan {
    std::wstring mode;            // 生效模式（Win7 强制改写后；未知模式原样保留、槽位按 sfx-efx 回退）
    Only only = Only::None;       // 生效限定（捕获默认改写后）
    bool capturePreOnly = false;  // only 由捕获默认改写而来
    bool valid = true;            // 组合合法性（sfx-only + post 不合法）
    std::vector<int> singleIdx;   // 写 REG_SZ=我方 CLSID 的槽位下标
    std::vector<int> multiIdx;    // 复合多值追加的槽位下标
    std::vector<int> procModePos; // 写 ProcModes 的位置号（5/6/7 子集）
    std::vector<int> foreignIdx;  // 跨模式清理：恢复原始值的槽位下标
};

inline InstallPlan ResolveInstallPlan(std::wstring mode, Only only,
                                      bool isCapture, bool osWin7) {
    InstallPlan p;
    if (osWin7 && mode == L"sfx-efx") mode = L"win7-sapo";
    p.mode = mode;
    if (isCapture && only == Only::None) {
        only = Only::Pre;
        p.capturePreOnly = true;
    }
    p.only = only;
    // 按 only 在（流侧, 设备侧）两组里取子集；None = 全取。
    auto keep = [&](std::vector<int> pre, std::vector<int> post) {
        if (only == Only::Pre) return pre;
        if (only == Only::Post) return post;
        pre.insert(pre.end(), post.begin(), post.end());
        return pre;
    };
    if (mode == L"win7-sapo") {
        p.singleIdx = keep({1}, {2});
        // ProcModes 只存在于 SFX 代位置：全量且非 Win7 OS 时沿现状
        // 写 5/6/7；带 --only 时本模式不装任何 SFX 代位置，不写。
        if (only == Only::None && !osWin7) p.procModePos = {5, 6, 7};
    } else if (mode == L"composite") {
        p.multiIdx = keep({6}, {7});
        p.procModePos = keep({5}, {6, 7});
    } else if (mode == L"sfx-only") {
        if (only == Only::Post) p.valid = false;
        p.singleIdx = {3};
        p.procModePos = {5, 6, 7};
    } else {  // sfx-efx 与未知模式（沿既有回退语义：按 sfx-efx 写）
        p.singleIdx = keep({3}, {4, 5});
        p.procModePos = keep({5}, {6, 7});
    }
    if (osWin7) p.procModePos.clear();  // Win7 OS 一律不写（既有行为）
    // 跨模式清理集合 = 全部位置槽 − 本次要写的槽。
    const int kAllPos[] = {1, 2, 3, 4, 5, 6, 7, 8};
    for (int i : kAllPos) {
        if (std::find(p.singleIdx.begin(), p.singleIdx.end(), i) ==
                p.singleIdx.end() &&
            std::find(p.multiIdx.begin(), p.multiIdx.end(), i) ==
                p.multiIdx.end()) {
            p.foreignIdx.push_back(i);
        }
    }
    return p;
}

}  // namespace apoplan
