// AuraHeartbeat.h — APO 心跳共享映射布局（audiodg 内 APO 写，外部工具读）。
//
// 设计借鉴 ViPER SharedParams 的“魔数+版本+序号”三件套，但布局/名字/魔数全独立：
// dramatis personae 不同，严禁把 ViPER 的头文件/结构体抄进来（非商用边界）。
// 读取方见 test/smoke/smoke_apo_heartbeat.py（规划中；本 slice 先落布局与写入）。
#pragma once

#include <cstdint>

#define AURA_HEARTBEAT_MAP_NAME L"Global\\AuraAPO_Heartbeat"
#define AURA_HEARTBEAT_MAGIC 0x41554248u  // 'AUBH'
#define AURA_HEARTBEAT_VERSION 1u

#pragma pack(push, 4)
struct AuraHeartbeat {
    uint32_t magic;       // AURA_HEARTBEAT_MAGIC
    uint32_t version;     // AURA_HEARTBEAT_VERSION
    uint32_t seq;         // 每次 APOProcess +1（UI 判定“活着”就看它走不走）
    uint32_t sampleRate;  // LockForProcess 锁定的采样率（0=未知）
    uint64_t framesTotal;  // 累计处理帧数
    uint32_t lastNbs;     // 最近一块的帧数
    uint32_t pid;         // 写入进程（audiodg）PID，供排查多实例
};
#pragma pack(pop)

static_assert(sizeof(AuraHeartbeat) == 32, "AuraHeartbeat must be 32 bytes");
