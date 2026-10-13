// VmAudioCallback.h — Voicemeeter OUTPUT INSERT 回调 + 引擎桥（SPEC §2.2）。
//
// v1 范围（故意收敛）：只处理 A1 主混音立体声对（ch0/1），其余 62 通道原样透传；
// 引擎以默认参数建 handle（全效果 off，中性透传），只验证泵 + 桥 + 静音旁路。
// 多总线逐对处理、参数下发面 = 后续 slice。
//
// RT 铁律（VB 头文件原话）：回调跑在单条 TIME CRITICAL 线程，不可重入，
// 禁止一切等待（锁/分配/显示/磁盘/通信）。本文件 RT 路径只做：
// 平面↔交织搬运、silent 计数、engine process（RT-safe 契约）、结果累加。
// 所有分配/打印/DLL 加载都在主线程（STARTING 内只允许初始化性分配，此处连它都不用）。
#pragma once

#include <cstdint>
#include <string>

struct AuraVmPump {
    // 输入（主线程，Run 前填好）
    std::string engineDll;  // "" = 自动搜索
    int seconds = 5;
    // 输出（主线程，Run 后读）
    bool ran = false;
    uint64_t frames = 0;     // 处理的总帧数（samples per channel）
    double maxDiff = 0.0;    // 非旁路时 |out-in| 最大值（中性引擎≈0）
    bool bypassEntered = false;  // 静音旁路是否进入过
    int startRc = -99;       // register rc（1 = 被别的应用占住）
    int sampleRate = 0;
    int nbs = 0;             // 每回调帧样点数
    long changes = 0;        // CHANGE 到达计数（v1 只观测，重启面后续 slice）
    std::string note;        // ran=false 时的原因
};

// 阻塞式跑一次：register → start → sleep(seconds) → stop → unregister。
// 返回 0 = 跑过（看 ran/frames 判定）；VM 不存在/被占位时 ran=false + note，同样返回 0。
int AuraVmPumpRun(AuraVmPump& p);
