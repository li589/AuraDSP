// AuraAsioWasapiSink.cpp — AuraDSP 虚拟 ASIO 驱动 WASAPI 直通输出实现
#include "AuraAsioWasapiSink.h"
#include "AsioDriverShared.h"

#include <cstring>
#include <algorithm>

AuraAsioWasapiSink::AuraAsioWasapiSink() {
    m_fifo.resize(kFifoCapacity * 2, 0.0f);
}

AuraAsioWasapiSink::~AuraAsioWasapiSink() {
    Close();
}

bool AuraAsioWasapiSink::Open() {
    if (m_open) return true;

    HRESULT hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), (void**)&m_pEnumerator
    );
    if (FAILED(hr) || !m_pEnumerator) {
        Close();
        return false;
    }

    // S3（ASIO 模式重构）：汇端点先认 App 经注册表指定的端点 id
    // （AsioDriver\RenderEndpoint），失效/缺失才回落系统默认端点。
    // 此前写死 GetDefaultAudioEndpoint——宾机默认端点恰为 AuraVAIO
    // 虚拟设备时，处理完的声音渲染进无人转送的虚拟端点，REAPER
    // 全程无声（2026-11-20 定罪）。
    {
        wchar_t idBuf[256] = {0};
        DWORD idBytes = sizeof(idBuf);
        m_usedConfiguredEndpoint = false;
        if (RegGetValueW(HKEY_CURRENT_USER, ASIO_DRIVER_REG_KEY,
                         ASIO_DRIVER_REG_RENDER_ENDPOINT, RRF_RT_REG_SZ,
                         nullptr, idBuf, &idBytes) == ERROR_SUCCESS &&
            idBuf[0] != L'\0') {
            if (SUCCEEDED(m_pEnumerator->GetDevice(idBuf, &m_pDevice)) &&
                m_pDevice) {
                m_usedConfiguredEndpoint = true;
            }
        }
        if (!m_pDevice) {
            hr = m_pEnumerator->GetDefaultAudioEndpoint(eRender, eMultimedia,
                                                        &m_pDevice);
            if (FAILED(hr) || !m_pDevice) {
                Close();
                return false;
            }
        }
        LPWSTR idRaw = nullptr;
        if (SUCCEEDED(m_pDevice->GetId(&idRaw)) && idRaw) {
            m_endpointId = idRaw;
            CoTaskMemFree(idRaw);
        }
    }

    hr = m_pDevice->Activate(
        __uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&m_pAudioClient
    );
    if (FAILED(hr) || !m_pAudioClient) {
        Close();
        return false;
    }

    WAVEFORMATEX* pMixFormat = nullptr;
    hr = m_pAudioClient->GetMixFormat(&pMixFormat);
    if (FAILED(hr) || !pMixFormat) {
        Close();
        return false;
    }

    m_targetChannels = pMixFormat->nChannels > 0 ? pMixFormat->nChannels : 2;
    m_targetSampleRate = pMixFormat->nSamplesPerSec > 0 ? (double)pMixFormat->nSamplesPerSec : 48000.0;
    m_bitsPerSample = pMixFormat->wBitsPerSample > 0 ? pMixFormat->wBitsPerSample : 32;

    if (pMixFormat->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        m_isFloat = true;
    } else if (pMixFormat->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto* pExt = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(pMixFormat);
        m_isFloat = (pExt->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    } else {
        m_isFloat = false;
    }
    // 有效位深：extensible 格式以 ValidBits 为准（24-in-32 容器时
    // wBitsPerSample=32 而有效仅 24，转换须按 24 缩放后左移对齐）。
    m_validBitsPerSample = m_bitsPerSample;
    if (pMixFormat->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto* pExt = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(pMixFormat);
        if (pExt->Samples.wValidBitsPerSample > 0 &&
            pExt->Samples.wValidBitsPerSample < m_bitsPerSample) {
            m_validBitsPerSample = pExt->Samples.wValidBitsPerSample;
        }
    }

    // 默认开 20ms 缓冲（200,000 reference time units, 100ns 进制）
    REFERENCE_TIME bufferDuration = 200000;
    hr = m_pAudioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        0,
        bufferDuration,
        0,
        pMixFormat,
        nullptr
    );
    CoTaskMemFree(pMixFormat);

    if (FAILED(hr)) {
        Close();
        return false;
    }

    hr = m_pAudioClient->GetBufferSize(&m_bufferFrames);
    if (FAILED(hr) || m_bufferFrames == 0) {
        m_bufferFrames = (UINT32)(m_targetSampleRate * 0.02);
    }

    hr = m_pAudioClient->GetService(
        __uuidof(IAudioRenderClient), (void**)&m_pRenderClient
    );
    if (FAILED(hr) || !m_pRenderClient) {
        Close();
        return false;
    }

    // 预填初始静音缓冲，防止冷启动爆音
    BYTE* pInitialBuf = nullptr;
    if (SUCCEEDED(m_pRenderClient->GetBuffer(m_bufferFrames, &pInitialBuf)) && pInitialBuf) {
        memset(pInitialBuf, 0, (size_t)m_bufferFrames * m_targetChannels * (m_bitsPerSample / 8));
        m_pRenderClient->ReleaseBuffer(m_bufferFrames, 0);
    }

    m_pAudioClient->Start();

    m_fifoRead = 0;
    m_fifoWrite = 0;
    m_fifoCount = 0;
    m_resamplePhase = 0.0;
    m_totalFramesRendered = 0;
    m_open = true;
    return true;
}

void AuraAsioWasapiSink::Close() {
    if (m_pAudioClient) {
        m_pAudioClient->Stop();
        m_pAudioClient->Release();
        m_pAudioClient = nullptr;
    }
    if (m_pRenderClient) {
        m_pRenderClient->Release();
        m_pRenderClient = nullptr;
    }
    if (m_pDevice) {
        m_pDevice->Release();
        m_pDevice = nullptr;
    }
    if (m_pEnumerator) {
        m_pEnumerator->Release();
        m_pEnumerator = nullptr;
    }
    m_open = false;
    m_endpointId.clear();
    m_usedConfiguredEndpoint = false;
    m_fifoRead = 0;
    m_fifoWrite = 0;
    m_fifoCount = 0;
}

void AuraAsioWasapiSink::PushSamples(const float* inL, const float* inR, long count, double sourceSampleRate) {
    if (!m_open || count <= 0) return;

    if (std::abs(sourceSampleRate - m_targetSampleRate) < 1.0) {
        // 采样率一致（如 48kHz 到 48kHz），直接压入
        for (long i = 0; i < count; ++i) {
            if (m_fifoCount < kFifoCapacity) {
                m_fifo[m_fifoWrite * 2 + 0] = inL ? inL[i] : 0.0f;
                m_fifo[m_fifoWrite * 2 + 1] = inR ? inR[i] : 0.0f;
                m_fifoWrite = (m_fifoWrite + 1) % kFifoCapacity;
                m_fifoCount++;
            }
        }
    } else {
        // 自适应线性重采样（如 44.1kHz 到 48kHz）
        const double step = sourceSampleRate / m_targetSampleRate;
        while (m_resamplePhase < count) {
            const long idx = (long)m_resamplePhase;
            const float frac = (float)(m_resamplePhase - idx);

            const float s0_L = inL ? inL[idx] : 0.0f;
            const float s1_L = (inL && idx + 1 < count) ? inL[idx + 1] : s0_L;
            const float s0_R = inR ? inR[idx] : 0.0f;
            const float s1_R = (inR && idx + 1 < count) ? inR[idx + 1] : s0_R;

            const float outL = s0_L + frac * (s1_L - s0_L);
            const float outR = s0_R + frac * (s1_R - s0_R);

            if (m_fifoCount < kFifoCapacity) {
                m_fifo[m_fifoWrite * 2 + 0] = outL;
                m_fifo[m_fifoWrite * 2 + 1] = outR;
                m_fifoWrite = (m_fifoWrite + 1) % kFifoCapacity;
                m_fifoCount++;
            }
            m_resamplePhase += step;
        }
        m_resamplePhase -= count;
    }

    DrainToWasapi();
}

void AuraAsioWasapiSink::DrainToWasapi() {
    if (!m_pAudioClient || !m_pRenderClient || m_fifoCount == 0) return;

    UINT32 padding = 0;
    HRESULT hr = m_pAudioClient->GetCurrentPadding(&padding);
    if (FAILED(hr)) return;

    const UINT32 framesNeeded = (m_bufferFrames > padding) ? (m_bufferFrames - padding) : 0;
    if (framesNeeded == 0) return;

    const UINT32 framesToWrite = (framesNeeded < m_fifoCount) ? framesNeeded : (UINT32)m_fifoCount;
    if (framesToWrite == 0) return;

    BYTE* pData = nullptr;
    hr = m_pRenderClient->GetBuffer(framesToWrite, &pData);
    if (FAILED(hr) || !pData) return;

    if (m_isFloat) {
        float* dst = reinterpret_cast<float*>(pData);
        for (UINT32 i = 0; i < framesToWrite; ++i) {
            const float L = m_fifo[m_fifoRead * 2 + 0];
            const float R = m_fifo[m_fifoRead * 2 + 1];
            m_fifoRead = (m_fifoRead + 1) % kFifoCapacity;
            m_fifoCount--;

            dst[i * m_targetChannels + 0] = L;
            dst[i * m_targetChannels + 1] = R;
            for (int c = 2; c < m_targetChannels; ++c) {
                dst[i * m_targetChannels + c] = 0.0f;
            }
        }
    } else if (m_bitsPerSample == 16) {
        int16_t* dst = reinterpret_cast<int16_t*>(pData);
        for (UINT32 i = 0; i < framesToWrite; ++i) {
            float L = m_fifo[m_fifoRead * 2 + 0];
            float R = m_fifo[m_fifoRead * 2 + 1];
            m_fifoRead = (m_fifoRead + 1) % kFifoCapacity;
            m_fifoCount--;

            if (L > 1.0f) L = 1.0f; else if (L < -1.0f) L = -1.0f;
            if (R > 1.0f) R = 1.0f; else if (R < -1.0f) R = -1.0f;

            dst[i * m_targetChannels + 0] = (int16_t)(L * 32767.0f);
            dst[i * m_targetChannels + 1] = (int16_t)(R * 32767.0f);
            for (int c = 2; c < m_targetChannels; ++c) {
                dst[i * m_targetChannels + c] = 0;
            }
        }
    } else if (m_bitsPerSample == 24 || m_bitsPerSample == 32) {
        // S3 格式补全：24 位打包 / 32 位整数（含 24-in-32）真转换。
        // 此前落入 memset 清零分支——端点为 24/32 位整数格式时汇
        // 输出恒为静音（宾机多个 Voicemeeter 端点即 24 位，潜伏
        // 第二雷，2026-11-20 定罪时一并查出）。
        // 口径：按有效位深缩放（2^(valid-1)-1），再左移
        // (容器-有效) 位对齐（24-in-32 为左对齐），小端写出。
        const int containerBytes = m_bitsPerSample / 8;
        const int validBits =
            (m_validBitsPerSample > 0 && m_validBitsPerSample <= m_bitsPerSample)
                ? m_validBitsPerSample
                : m_bitsPerSample;
        const int shift = m_bitsPerSample - validBits;
        const double scale =
            (double)((validBits >= 32) ? 2147483647LL
                                       : ((1LL << (validBits - 1)) - 1));
        for (UINT32 i = 0; i < framesToWrite; ++i) {
            float L = m_fifo[m_fifoRead * 2 + 0];
            float R = m_fifo[m_fifoRead * 2 + 1];
            m_fifoRead = (m_fifoRead + 1) % kFifoCapacity;
            m_fifoCount--;

            if (L > 1.0f) L = 1.0f; else if (L < -1.0f) L = -1.0f;
            if (R > 1.0f) R = 1.0f; else if (R < -1.0f) R = -1.0f;

            const float vals[2] = {L, R};
            for (int c = 0; c < m_targetChannels; ++c) {
                const float v = (c < 2) ? vals[c] : 0.0f;
                // double 乘法：float 表示不了 2^31-1，满幅会溢出成
                // 负满幅单点爆音。
                int64_t s = (int64_t)((double)v * scale);
                s <<= shift;
                uint64_t u = (uint64_t)s;
                BYTE* dst = pData + ((size_t)i * m_targetChannels + c) *
                                        (size_t)containerBytes;
                for (int b = 0; b < containerBytes; ++b) {
                    dst[b] = (BYTE)((u >> (8 * b)) & 0xFF);
                }
            }
        }
    } else {
        // 未知整数格式（真实混音格式不会落此）：保持旧静音兜底，
        // 不写坏数据。
        memset(pData, 0, (size_t)framesToWrite * m_targetChannels * (m_bitsPerSample / 8));
        m_fifoRead = (m_fifoRead + framesToWrite) % kFifoCapacity;
        m_fifoCount -= framesToWrite;
    }

    m_pRenderClient->ReleaseBuffer(framesToWrite, 0);
    m_totalFramesRendered += framesToWrite;
}
