// AuraAsioWasapiSink.h — AuraDSP 虚拟 ASIO 驱动 WASAPI 直通渲染输出汇
//
// 职责：
//   在 Phase 2 提供将 DAW 灌入的音频数据直通渲染到系统默认物理音频端点能力。
//   内部实现自适应重采样与解耦环形缓冲，确保无论 DAW 使用何种采样率/块大小，
//   均可稳定、低抖动、无爆音输出到物理声卡。
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#include <vector>
#include <cstdint>

class AuraAsioWasapiSink {
public:
    AuraAsioWasapiSink();
    ~AuraAsioWasapiSink();

    bool Open();
    void Close();
    bool IsOpen() const { return m_open; }

    // 写入立体声浮点音频 [-1.0f, +1.0f]
    void PushSamples(const float* inL, const float* inR, long count, double sourceSampleRate);

    double GetTargetSampleRate() const { return m_targetSampleRate; }
    int GetTargetChannels() const { return m_targetChannels; }
    uint64_t GetTotalFramesRendered() const { return m_totalFramesRendered; }

private:
    void DrainToWasapi();

    bool m_open = false;
    IMMDeviceEnumerator* m_pEnumerator = nullptr;
    IMMDevice* m_pDevice = nullptr;
    IAudioClient* m_pAudioClient = nullptr;
    IAudioRenderClient* m_pRenderClient = nullptr;

    double m_targetSampleRate = 48000.0;
    int m_targetChannels = 2;
    bool m_isFloat = true;
    int m_bitsPerSample = 32;
    UINT32 m_bufferFrames = 0;

    // 重采样相位累加器
    double m_resamplePhase = 0.0;

    // 单线程无锁环形缓冲（单生产者单消费者位于同一泵线程）
    static constexpr size_t kFifoCapacity = 16384;
    std::vector<float> m_fifo;
    size_t m_fifoRead = 0;
    size_t m_fifoWrite = 0;
    size_t m_fifoCount = 0;

    uint64_t m_totalFramesRendered = 0;
};
