// AuraAsioDriver.h — AuraDSP 自研虚拟 ASIO 驱动核心实现
//
// 依据：docs/adr/ADR-008-asio-driver-identity-and-architecture.md
// 架构：现代 C++20 Clean-Room COM，直接继承 IASIO，零 MFC/combase 杂质。
// 规范：Zero-DSP 分离原则，驱动内部仅做缓冲搬运与时钟驱动，音效处理委托外部引擎。
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <unknwn.h>
#include <mmsystem.h>
#include <avrt.h>

#include <atomic>
#include <cstdint>
#include <string>

// Steinberg ASIO SDK 头文件引用（外部工具链）
#include "asiosys.h"
#include "asio.h"
#include "iasiodrv.h"

#include "AuraAsioWasapiSink.h"
#include "AuraAsioEngineLoader.h"

class AuraAsioDriver : public IASIO {
public:
    AuraAsioDriver();
    virtual ~AuraAsioDriver();

    // ---------------- IUnknown ----------------
    virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppvObject) override;
    virtual ULONG STDMETHODCALLTYPE AddRef() override;
    virtual ULONG STDMETHODCALLTYPE Release() override;

    // ---------------- IASIO 21 个标准方法 ----------------
    virtual ASIOBool init(void* sysHandle) override;
    virtual void getDriverName(char* name) override;
    virtual long getDriverVersion() override;
    virtual void getErrorMessage(char* string) override;
    virtual ASIOError start() override;
    virtual ASIOError stop() override;
    virtual ASIOError getChannels(long* numInputChannels, long* numOutputChannels) override;
    virtual ASIOError getLatencies(long* inputLatency, long* outputLatency) override;
    virtual ASIOError getBufferSize(long* minSize, long* maxSize,
                                    long* preferredSize, long* granularity) override;
    virtual ASIOError canSampleRate(ASIOSampleRate sampleRate) override;
    virtual ASIOError getSampleRate(ASIOSampleRate* sampleRate) override;
    virtual ASIOError setSampleRate(ASIOSampleRate sampleRate) override;
    virtual ASIOError getClockSources(ASIOClockSource* clocks, long* numSources) override;
    virtual ASIOError setClockSource(long reference) override;
    virtual ASIOError getSamplePosition(ASIOSamples* sPos, ASIOTimeStamp* tStamp) override;
    virtual ASIOError getChannelInfo(ASIOChannelInfo* info) override;
    virtual ASIOError createBuffers(ASIOBufferInfo* bufferInfos, long numChannels,
                                    long bufferSize, ASIOCallbacks* callbacks) override;
    virtual ASIOError disposeBuffers() override;
    virtual ASIOError controlPanel() override;
    virtual ASIOError future(long selector, void* opt) override;
    virtual ASIOError outputReady() override;

    // 活跃驱动实例计数（供 DllCanUnloadNow 检查）
    static std::atomic<long> s_instanceCount;

    // 通道档位（B2c）：与引擎 channels.count 一致，仅允许 2/4/6/8。
    static constexpr long kMinChannels = 2;
    static constexpr long kMaxChannels = 8;
    static bool IsValidChannelCount(long n) {
        return n == 2 || n == 4 || n == 6 || n == 8;
    }

private:
    static DWORD WINAPI AudioPumpThreadProc(LPVOID param);
    DWORD PumpLoop();
    void LoadConfiguredChannels();  // 启动前从注册表读取档位（默认 2）

    std::atomic<long> m_refCount{1};

    bool m_active = false;
    bool m_started = false;
    bool m_timeInfoMode = false;
    bool m_buffersAllocated = false;

    double m_sampleRate = 48000.0;
    long m_bufferSize = 256;
    int64_t m_samplePosition = 0;

    ASIOCallbacks* m_callbacks = nullptr;

    // 通道映射（B2c：2/4/6/8 档，默认 2；双缓冲 [channel][half 0/1]）
    long m_channels = 2;
    float* m_inBuffers[kMaxChannels][2] = {};
    float* m_outBuffers[kMaxChannels][2] = {};
    bool m_inputActive[kMaxChannels] = {};
    bool m_outputActive[kMaxChannels] = {};

    // 时钟与线程
    HANDLE m_hThread = nullptr;
    HANDLE m_hStopEvent = nullptr;
    int m_toggle = 0;

    // Phase 2：WASAPI 默认端点直通渲染汇
    AuraAsioWasapiSink m_wasapiSink;

    // Phase 3：外部动态 DSP 引擎与旁路控制
    AuraAsioEngineLoader m_engineLoader;
    void* m_engine = nullptr;
    std::atomic<bool> m_bypass{false};
    std::atomic<uint64_t> m_dspProcessedFrames{0};
    std::string m_pendingParamString;

    // 实时音频交织与 DSP 处理中间缓冲（createBuffers 时分配，RT 线程零分配）
    // m_proc：处理后交织输出（bufferSize * m_channels）；m_foldL/R：N→立体声下混，
    // 供 WasapiSink 物理端点消费（m_channels==2 时为通道 0/1 的等价拷贝）。
    float* m_interleavedIn = nullptr;
    float* m_interleavedOut = nullptr;
    float* m_proc = nullptr;
    float* m_foldL = nullptr;
    float* m_foldR = nullptr;

    char m_errorMessage[128] = {0};
};
