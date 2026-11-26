// ApoEngineHost.h — AuraApo 的引擎宿主（System APO 真处理，设计 P2）
//
// docs/10-架构/SystemAPO引擎嵌入设计-2026-11-10.md D1/D3/D5/D6/D8：
// 每个 CAuraApo 实例持有一台宿主。LockForProcess（非 RT）时：
//   抢「引擎座位」（telemetry 块 CAS，全系统唯一）→ 按 D1 搜索序
//   加载 auradsp_engine_apo.dll（纪律版，/MT+/guard:cf/无插件）
//   → auradsp_create → 声道决议 → 起 worker 线程。
// worker（非 RT）：50ms 轮询参数块（seqlock 快照→diff→逐项
//   auradsp_set_param）+ 泵 viz 到 telemetry。set_param 的锁与
//   文件钩子只在本线程，与桥的控制/泵分工同构。
// APOProcess（RT）只调 Process()：异常 SEH 闩锁 fault 后恒透传，
//   绝不让引擎故障波及 audiodg。任何一步失败都保持 v1 透传语义。
#pragma once

#include <windows.h>
#include <atomic>
#include <cstdint>
#include <string>

#include "ApoParamIndex.h"
#include "ApoShared.h"
#include "../common/HostGeometry.h"
#include "auradsp_engine.h"  // 仅类型与签名（符号运行期解析，不静态链接）

class ApoEngineHost {
 public:
    ApoEngineHost() = default;
    ~ApoEngineHost();
    ApoEngineHost(const ApoEngineHost&) = delete;
    ApoEngineHost& operator=(const ApoEngineHost&) = delete;

    // 端点上下文（第四十一轮多端点 v2）：Initialize 时自 FX 属性
    // 存储读到的身份与声道族覆写。endpointId 为空 = 无令牌，宿主
    // 回落 v1 全局块/全局座位；覆写无效时对应项跟随全局参数块。
    struct EndpointContext {
        const wchar_t* endpointId = nullptr;
        bool modeValid = false;
        int32_t mode = 0;
        bool fillValid = false;
        int32_t fill = 0;
    };

    // LockForProcess 尾调用。成功（抢到座位且引擎就绪）返回 true；
    // 失败保持透传，不影响 APO 锁定结果。
    bool TryStart(UINT32 rate, UINT32 streamChannels,
                  const EndpointContext& ep = EndpointContext());
    // UnlockForProcess 首调用（亦由析构兜底）：停 worker → 销毁
    // 引擎 → 卸载 DLL → 释放座位 → 关映射。幂等。
    void Stop();

    bool Active() const { return active_.load(std::memory_order_acquire); }

    // APOProcess（RT 线程）调用：真处理一块。未就绪/旁路/故障
    // 闩锁时返回 false，调用方走 v1 透传拷贝。src/dst 可同址
    // （INPLACE；引擎内部先抄入 scratch，适配路径先 gather 后
    // scatter，均别名安全）。
    bool Process(const float* src, float* dst, UINT32 frames);

    // GetLatency 用（非 RT 调用点）：引擎报告的毫秒延迟。
    double LatencyMs();

 private:
    using FnAbi = uint32_t (*)();
    using FnCreate = auradsp_handle (*)(float, int);
    using FnDestroy = void (*)(auradsp_handle);
    using FnProcessGeometry = auradsp_status (*)(
        auradsp_handle, const float*, float*, int, const auradsp_geometry*);
    using FnRequestGeometry = auradsp_status (*)(auradsp_handle, int32_t, int32_t,
                                                 uint64_t*);
    using FnGetActiveGeometry = auradsp_status (*)(auradsp_handle,
                                                   auradsp_geometry*);
    using FnSetParam = auradsp_status (*)(auradsp_handle, const char*, const void*, uint32_t);
    // 生效值回读（第三十五轮）：可选符号，缺失则 v6 段不写。
    using FnGetParam = auradsp_status (*)(auradsp_handle, const char*, void*, uint32_t);
    using FnLastError = const char* (*)(auradsp_handle);
    using FnGetLatencyMs = double (*)(auradsp_handle);
    using FnVizRead = uint32_t (*)(auradsp_handle, auradsp_viz_frame*, uint32_t);
    // Part I Q2 插件通道（可选解析：旧/stub 引擎缺符号时整通道
    // 静默禁用，引擎本体不受影响）。
    using FnPluginSlotLoad = int (*)(auradsp_handle, int, const char*, const char*);
    using FnPluginSlot = int (*)(auradsp_handle, int);
    using FnPluginSlotInt = int (*)(auradsp_handle, int, int);
    using FnPluginSlotPreset = int (*)(auradsp_handle, int, const char*);
    using FnPluginSlotStatus = int (*)(auradsp_handle, int, char*, int);
    using FnPluginFlag = int (*)(auradsp_handle, int);

    bool LoadEngine();
    void ReleaseResources();  // 仅 worker 已确认退出（或从未创建）后调用
    bool ClaimSeat();
    void ReleaseSeat();
    bool OpenTelemetry();
    static DWORD WINAPI WorkerMain(LPVOID ctx);
    void WorkerLoop();
    void ApplySnapshot(const uint8_t* snap, const uint32_t* hdr);
    void RecordFileError(uint32_t slot, auradsp_status status,
                         const char* explicitReason = nullptr);
    void PublishFileErrors();
    void ReadbackEffective();
    // Part I Q2：插件块 diff 应用 + telemetry v3 插件段回填
    // （worker 线程内调用；通道不可用时自跳过）。
    void ApplyPlugins();
    bool ApplyPluginState(int slot, const uint8_t* state, uint32_t bytes);
    bool ProcessGuarded(const float* src, float* dst, UINT32 frames);
    void ProcessDirect(const float* src, float* dst, UINT32 frames);

    static constexpr int kMaxBlock = 8192;

    std::atomic<bool> active_{false};
    std::atomic<bool> fault_{false};
    std::atomic<bool> bypass_{false};

    HMODULE hEngineDll_ = nullptr;
    auradsp_handle engine_ = nullptr;
    FnCreate fnCreate_ = nullptr;
    FnDestroy fnDestroy_ = nullptr;
    FnProcessGeometry fnProcessGeometry_ = nullptr;
    FnRequestGeometry fnRequestGeometry_ = nullptr;
    FnGetActiveGeometry fnGetActiveGeometry_ = nullptr;
    FnSetParam fnSetParam_ = nullptr;
    FnGetParam fnGetParam_ = nullptr;
    FnLastError fnLastError_ = nullptr;
    FnGetLatencyMs fnLatency_ = nullptr;
    FnVizRead fnVizRead_ = nullptr;
    FnPluginSlotLoad fnSlotLoad_ = nullptr;
    FnPluginSlot fnSlotUnload_ = nullptr;
    FnPluginSlotInt fnSlotBypass_ = nullptr;
    FnPluginSlotInt fnSlotStage_ = nullptr;
    FnPluginSlotInt fnSlotChannels_ = nullptr;
    FnPluginSlotPreset fnSlotLoadPreset_ = nullptr;
    FnPluginSlotStatus fnSlotStatus_ = nullptr;
    FnPluginFlag fnSetPdc_ = nullptr;
    FnPluginFlag fnChainEnabled_ = nullptr;
    bool pluginsOk_ = false;

    // 加载诊断（第五轮 S3，telemetry v4）：LoadEngine/TryStart 把
    // 结局记在这里，TryStart 失败/成功出口统一 PublishLoadDiag
    // 写入 telemetry 块——App 面板据此区分「心跳活跃」与「引擎
    // 未就绪（加载失败）」，不再单凭心跳报处理中。
    uint32_t loadStage_ = APO_LOAD_STAGE_NONE;
    uint32_t loadErr_ = 0;
    uint64_t enginePathHash_ = 0;
    uint32_t engineLoadGen_ = 0;
    void PublishLoadDiag();

    UINT32 rate_ = 48000;
    UINT32 streamCh_ = 2;
    UINT32 engCh_ = 2;
    bool adapt_ = false;  // engCh_ != streamCh_：需要 gather/scatter
    float* inBuf_ = nullptr;   // kMaxBlock * max(streamCh_, 2)
    float* outBuf_ = nullptr;

    // 生效宽决议（第四十六轮 S2）：推翻「流声道是几何真相、
    // 压过 channels.count」的旧决议——引擎宽 = min{流宽，
    // 参数块 channels.count（用户设置，合法 {2,4,6,8} 时）}，
    // 与其它模式同义（设 5.1 放 7.1 不再全宽跑）。userCh_
    // 为块侧最近值（0 = 未写）；effMode_ 为有效 channels.
    // mode（端点覆写优先、否则块值），决定 gather 用折叠
    // （矩阵）还是截断（离散）。live* 是发布给 RT 路径的
    // 只读视图（worker 决议后原子发布，RT 只读不锁）。
    UINT32 userCh_ = 0;
    int32_t lastBlockMode_ = 0;
    int32_t effMode_ = 0;
    std::atomic<UINT32> liveEngCh_{2};
    std::atomic<bool> liveTrunc_{false};
    aurahost::GeometryState requestedGeometry_;
    UINT32 ResolveEngCh() const;
    // 返回成功应用的有效几何分量位：bit0=count，bit1=mode。
    uint32_t ApplyEngChResolution();

    // telemetry（座位与回传）
    HANDLE hTeleMap_ = nullptr;
    ApoTelemetryBlock* tele_ = nullptr;
    bool seatOwner_ = false;

    // 端点上下文（第四十一轮）：座位/telemetry 按端点分块的键 +
    // 声道族覆写与已应用哨兵（覆写在 ApplySnapshot 中压过参数块）。
    std::wstring endpointId_;
    unsigned long long endpointHash_ = 0;
    bool epModeValid_ = false;
    int32_t epMode_ = 0;
    bool epFillValid_ = false;
    int32_t epFill_ = 0;
    int32_t appliedEpMode_ = -1;  // -1 = 尚未向引擎下发覆写
    int32_t appliedEpFill_ = -1;
    bool ovrWasActive_ = false;  // 覆写撤除沿检测（回落块值用）

    // 参数块（worker 打开）
    HANDLE hParamMap_ = nullptr;
    const uint8_t* paramView_ = nullptr;

    // 插件块（Part I Q2；本进程创建保活，口径同参数块）
    HANDLE hPluginMap_ = nullptr;
    const uint8_t* pluginView_ = nullptr;
    // ApplyPlugins 的整槽快照缓冲（全面复审 S4 / APO-10）：堆分配
    // 一次复用，Stop 时释放。载荷只从快照读，不直读活映射。
    uint8_t* pluginSnap_ = nullptr;
    struct AppliedPlugin {
        uint32_t loadGen = 0, stateGen = 0;
        uint32_t stage = 0, mask = 0, bypass = 0;
        bool loaded = false;
        bool seen = false;
    };
    AppliedPlugin appliedPlugins_[APO_PLUGIN_SLOTS];
    uint32_t appliedChainEnabled_ = 1, appliedPdc_ = 0;
    bool pluginHdrSeen_ = false;
    std::wstring pluginTempDir_;

    // worker
    HANDLE hThread_ = nullptr;
    HANDLE hStop_ = nullptr;

    // 已应用快照（worker 独占）：数值槽原样 + 字符串槽字节
    uint32_t appliedNum_[APO_NUM_PARAM_COUNT];
    std::string appliedStr_[APO_STR_SLOT_COUNT];
    // 失败账本与 appliedStr_ 分离：相同失败值不每 50ms 反复做文件 IO，
    // 但从失败值切回此前成功的同一路径时仍必须真实重试。
    std::string failedStr_[APO_STR_SLOT_COUNT];
    std::string fileErrors_[APO_STR_SLOT_COUNT];
    bool fileFailed_[APO_STR_SLOT_COUNT] = {};
    bool snapshotValid_ = false;
    // 生效值回读节流（worker 独占）：应用计数变化即读、另每
    // 20 轮（约 1s）兜底读一次。
    uint32_t effReadbackApplied_ = 0xFFFFFFFFu;
    int effReadbackTick_ = 0;
    uint32_t appliedTotal_ = 0;
    auradsp_viz_frame vizFrames_[4];
};
