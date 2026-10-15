// AsioHost.cpp — ASIO 宿主封装实现（04_asio_engine Phase 1）
// 许可：Steinberg ASIO SDK 2.3.4，GPLv3 路线（见 04_asio_engine/README.md）。
// RT 铁律：process() 仅触碰原子量与输出缓冲；零分配/零锁/零 syscall/零日志。

#include "AsioHost.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <windows.h>
#include <objbase.h>   // StringFromGUID2

// ---- SDK 宿主侧源码（随 CMake 目标 auraasio_host 一并编译）----
// 注意：asio.h / iasiodrv.h 已由 AsioHost.h 按正确顺序包含，勿重复包含
// （iasiodrv.h 的 interface 块没有 include guard，重复包含会重定义 IASIO）。
#include "asiodrivers.h"  // loadAsioDriver（进程级单例 asioDrivers）
#include "asiolist.h"     // AsioDriverList：注册表枚举

// SDK 未在头文件导出这两个符号（仅在 asiodrivers.cpp 定义），宿主自持声明。
bool loadAsioDriver(char* name);
extern AsioDrivers* asioDrivers;

#ifndef _PI
#define _PI 3.14159265358979323846
#endif

namespace auraasio {

AsioHost* AsioHost::s_active = nullptr;

// 进程级回调结构体（头文件私有区注释：驱动长期持有并经 RT 线程回调，
// 栈局部地址会在 create_* 返回后失效）。零初始化，create 前逐字段填充。
ASIOCallbacks AsioHost::s_cb;

const char* sample_type_name(long type) {
    switch (type) {
    case ASIOSTInt16LSB:   return "Int16LSB";
    case ASIOSTInt24LSB:   return "Int24LSB";
    case ASIOSTInt32LSB:   return "Int32LSB";
    case ASIOSTFloat32LSB: return "Float32LSB";
    case ASIOSTFloat64LSB: return "Float64LSB";
    case ASIOSTInt16MSB:   return "Int16MSB";
    case ASIOSTInt24MSB:   return "Int24MSB";
    case ASIOSTInt32MSB:   return "Int32MSB";
    case ASIOSTFloat32MSB: return "Float32MSB";
    case ASIOSTFloat64MSB: return "Float64MSB";
    case ASIOSTDSDInt8LSB1: return "DSDInt8LSB1";
    case ASIOSTDSDInt8MSB1: return "DSDInt8MSB1";
    case ASIOSTDSDInt8NER8: return "DSDInt8NER8";
    default: return "Unknown";
    }
}

std::string ansi_to_utf8(const char* s) {
    if (!s || !*s) return std::string();
    // MultiByteToWideChar 为 6 参（无 lpDefaultChar/lpUsedDefaultChar，
    // 勿与 7 参的 WideCharToMultiByte 混淆）。
    const int wlen = MultiByteToWideChar(CP_ACP, 0, s, -1, nullptr, 0);
    if (wlen <= 1) return std::string();
    std::wstring w((size_t)wlen - 1, L'\0');
    MultiByteToWideChar(CP_ACP, 0, s, -1, &w[0], wlen);
    const int ulen = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (ulen <= 1) return std::string();
    std::string u((size_t)ulen - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &u[0], ulen, nullptr, nullptr);
    return u;
}

std::vector<DriverEntry> enumerate_drivers() {
    std::vector<DriverEntry> out;
    // AsioDriverList 构造即枚举 HKLM\SOFTWARE\ASIO（进程位视图）。
    // 注意：其析构会 CoUninitialize（与构造的 CoInitialize 配对）——故本函数
    // 返回后 COM 已释放；后续 loadAsioDriver 会由 SDK 懒创建 asioDrivers 单例
    // 重新 CoInitialize（2026-10-15 实测确认，Phase 2 桥依赖此行为）。
    AsioDriverList list;
    const long n = list.asioGetNumDev();
    out.reserve((size_t)(n > 0 ? n : 0));
    char name[MAXDRVNAMELEN] = {0};
    char path[MAXPATHLEN] = {0};
    CLSID clsid;
    for (long i = 0; i < n; ++i) {
        DriverEntry e;
        if (list.asioGetDriverName(i, name, (int)sizeof(name)) == 0) {
            e.name = name;                    // 原始 ANSI：SDK load 匹配键
            e.nameUtf8 = ansi_to_utf8(name);  // 显示名
        }
        if (list.asioGetDriverPath(i, path, (int)sizeof(path)) == 0) e.dllPath = path;
        if (list.asioGetDriverCLSID(i, &clsid) == 0) {
            // StringFromGUID2 为缓冲区版（3 参，返回字符数；含尾零）。
            // 勿与分配版 StringFromCLSID 混淆——后者才需要 CoTaskMemFree。
            wchar_t wbuf[64] = {0};
            const int nch = StringFromGUID2(clsid, wbuf, 64);
            if (nch > 0 && nch < 64) {
                // 返回值含尾随 L'\0'，剥掉再转 UTF-8
                int cp = nch;
                while (cp > 0 && wbuf[cp - 1] == L'\0') --cp;
                const int len = WideCharToMultiByte(CP_UTF8, 0, wbuf, cp, nullptr, 0, nullptr, nullptr);
                if (len > 0) {
                    e.clsid.resize((size_t)len);
                    WideCharToMultiByte(CP_UTF8, 0, wbuf, cp, &e.clsid[0], len, nullptr, nullptr);
                }
            }
        }
        out.push_back(std::move(e));
    }
    return out;
}

AsioHost::~AsioHost() { close(); }

void release_active_driver() {
    // 释放当前驱动 COM 对象（驱动 DLL 可能仍被单例 asioDrivers 持引用；
    // 完全卸载进程退出时由 SDK 单例析托底——宿主样例同款行为）。
    if (asioDrivers) asioDrivers->removeCurrentDriver();
}

bool AsioHost::open(const char* driverName, void* sysRef, std::string& why) {
    close();  // 幂律：重复 open 先关旧实例
    if (!driverName || !driverName[0]) { why = "empty driver name"; return false; }

    if (!loadAsioDriver(const_cast<char*>(driverName))) {
        why = "loadAsioDriver failed (not in registry or COM load failed)";
        return false;
    }
    ASIODriverInfo info;
    memset(&info, 0, sizeof(info));
    info.asioVersion = 2;   // 宿主支持 ASIO 2（asioMessage 回调可用）
    info.sysRef = sysRef;
    ASIOError rc = ASIOInit(&info);
    if (rc != ASE_OK) {
        char buf[256];
        _snprintf_s(buf, sizeof(buf), _TRUNCATE, "ASIOInit rc=%ld msg=%s", (long)rc, info.errorMessage);
        why = buf;
        // ASIOInit 失败时 SDK 会把 theAsioDriver 置空但驱动对象仍挂在单例上；
        // 强制 removeCurrentDriver 释放，避免同进程再次 open 撞 ALREADY_OPEN。
        if (asioDrivers) asioDrivers->removeCurrentDriver();
        return false;
    }
    opened_ = true;
    driverName_ = info.name;
    asioVersion_ = info.asioVersion;
    driverVersion_ = info.driverVersion;
    // 新会话从干净状态开始：清掉上一会话可能遗留的驱动请求标志
    //（asiorestart 热切换复用同一 host 实例重 open，不清会让宿主心跳
    // 把 resetPending=1 当新事件 → 无限 restart 循环）。
    resetPending_.store(false, std::memory_order_release);
    latenciesChanged_.store(false, std::memory_order_release);
    lastSwitchQpc_.store(0, std::memory_order_relaxed);
    s_active = this;
    return true;
}

void AsioHost::close() {
    if (running_) stop();
    if (buffers_) { ASIODisposeBuffers(); buffers_ = false; }
    if (opened_) { ASIOExit(); opened_ = false; }
    if (s_active == this) s_active = nullptr;
    bufSize_ = 0;
    sampleRate_ = 0.0;
    srLive_.store(0.0, std::memory_order_relaxed);
    outType_[0] = outType_[1] = -1;
    outBufs_[0][0] = outBufs_[0][1] = nullptr;
    outBufs_[1][0] = outBufs_[1][1] = nullptr;
    inType_[0] = inType_[1] = -1;
    inBufs_[0][0] = inBufs_[0][1] = nullptr;
    inBufs_[1][0] = inBufs_[1][1] = nullptr;
    free(scratchIn_); free(scratchOut_);
    scratchIn_ = scratchOut_ = nullptr;
    sink_ = nullptr;
    sinkCtx_ = nullptr;
    outPair_ = 0;
    phase_ = 0.0;
    toneOn_.store(false, std::memory_order_release);
    switches_.store(0, std::memory_order_relaxed);
    peak_.store(0.0f, std::memory_order_relaxed);
    peakIn_.store(0.0f, std::memory_order_relaxed);
    maxCbTicks_.store(0, std::memory_order_relaxed);
}

bool AsioHost::query_caps(DriverCaps& out) {
    if (!opened_) return false;
    out = DriverCaps{};
    long inCh = 0, outCh = 0;
    if (ASIOGetChannels(&inCh, &outCh) != ASE_OK) { out.errorMessage = "getChannels failed"; return false; }
    long mn = 0, mx = 0, pref = 0, gran = 0;
    if (ASIOGetBufferSize(&mn, &mx, &pref, &gran) != ASE_OK) { out.errorMessage = "getBufferSize failed"; return false; }
    long inLat = 0, outLat = 0;
    ASIOGetLatencies(&inLat, &outLat);  // 失败保持 0
    double sr = 0.0;
    if (ASIOGetSampleRate(&sr) != ASE_OK) sr = 0.0;

    ASIOChannelInfo ci;
    memset(&ci, 0, sizeof(ci));
    ci.isInput = ASIOFalse;
    ci.channel = 0;
    long out0Type = -1;
    char out0Name[32] = {0};
    long out0Active = 0;
    if (ASIOGetChannelInfo(&ci) == ASE_OK) {
        out0Type = ci.type;
        memcpy(out0Name, ci.name, sizeof(out0Name) - 1);
        out0Active = ci.isActive ? 1 : 0;
    }

    out.ok = true;
    out.driverName = driverName_;
    out.asioVersion = asioVersion_;
    out.driverVersion = driverVersion_;
    out.inChannels = inCh;
    out.outChannels = outCh;
    out.minBuf = mn; out.maxBuf = mx; out.prefBuf = pref; out.granularity = gran;
    out.inLatency = inLat; out.outLatency = outLat;
    out.sampleRate = sr;
    out.out0Type = out0Type;
    out.out0TypeName = sample_type_name(out0Type);
    out.out0Name = out0Name;
    out.out0Active = out0Active;
    return true;
}

bool AsioHost::create_output_stereo(long bufSize, std::string& why) {
    if (!opened_) { why = "host not open"; return false; }
    if (buffers_) { why = "buffers already created"; return false; }

    long inCh = 0, outCh = 0;
    if (ASIOGetChannels(&inCh, &outCh) != ASE_OK) { why = "getChannels failed"; return false; }
    if (outCh < 2) {
        char b[96];
        _snprintf_s(b, sizeof(b), _TRUNCATE, "driver has %ld output channels (<2)", outCh);
        why = b;
        return false;
    }
    long mn = 0, mx = 0, pref = 0, gran = 0;
    if (ASIOGetBufferSize(&mn, &mx, &pref, &gran) != ASE_OK) { why = "getBufferSize failed"; return false; }
    const long bs = (bufSize > 0) ? bufSize : pref;
    if (bs <= 0) { why = "invalid buffer size"; return false; }

    ASIOBufferInfo infos[2];
    infos[0].isInput = ASIOFalse; infos[0].channelNum = 0;
    infos[0].buffers[0] = infos[0].buffers[1] = nullptr;
    infos[1].isInput = ASIOFalse; infos[1].channelNum = 1;
    infos[1].buffers[0] = infos[1].buffers[1] = nullptr;

    // 回调结构体必须进程级生存期（驱动长期持有并经 RT 线程回调；见头文件注）。
    // 单实例约束下用类级静态，create 前填充、之后只读。
    ASIOCallbacks& cb = s_cb;
    memset(&cb, 0, sizeof(cb));
    cb.bufferSwitch = &AsioHost::buffer_switch;
    cb.sampleRateDidChange = &AsioHost::sample_rate_did_change;
    cb.asioMessage = &AsioHost::asio_message;
    cb.bufferSwitchTimeInfo = &AsioHost::buffer_switch_time_info;

    ASIOError rc = ASIOCreateBuffers(infos, 2, bs, &cb);
    if (rc != ASE_OK) {
        char b[96];
        _snprintf_s(b, sizeof(b), _TRUNCATE, "ASIOCreateBuffers rc=%ld", (long)rc);
        why = b;
        return false;
    }

    // 逐声道取类型与缓冲地址
    for (int ch = 0; ch < 2; ++ch) {
        ASIOChannelInfo ci;
        memset(&ci, 0, sizeof(ci));
        ci.channel = ch;
        ci.isInput = ASIOFalse;
        if (ASIOGetChannelInfo(&ci) != ASE_OK) {
            ASIODisposeBuffers();
            why = "getChannelInfo failed after createBuffers";
            return false;
        }
        outType_[ch] = ci.type;
        outBufs_[ch][0] = infos[ch].buffers[0];
        outBufs_[ch][1] = infos[ch].buffers[1];
    }
    // v1 支持集：Float32LSB 原生 + Int32/Int24/Int16LSB 换算；其余明确拒绝
    // （含全部 DSD 与 MSB 变体——Spec 风险 R-6：不猜格式）。
    for (int ch = 0; ch < 2; ++ch) {
        const long t = outType_[ch];
        if (t != ASIOSTFloat32LSB && t != ASIOSTInt32LSB &&
            t != ASIOSTInt24LSB && t != ASIOSTInt16LSB) {
            ASIODisposeBuffers();
            char b[128];
            _snprintf_s(b, sizeof(b), _TRUNCATE,
                        "unsupported output sample type ch%d: %s (%ld)",
                        ch, sample_type_name(t), t);
            why = b;
            return false;
        }
    }
    double sr = 0.0;
    if (ASIOGetSampleRate(&sr) != ASE_OK || sr <= 0.0) {
        ASIODisposeBuffers();
        why = "getSampleRate failed (cannot size tone phase)";
        return false;
    }
    bufSize_ = bs;
    sampleRate_ = sr;
    srLive_.store(sr, std::memory_order_relaxed);
    buffers_ = true;
    return true;
}

bool AsioHost::start() {
    if (!buffers_ || running_) return false;
    if (ASIOStart() != ASE_OK) return false;
    running_ = true;
    return true;
}

void AsioHost::stop() {
    if (!running_) return;
    ASIOStop();
    running_ = false;
}

// ---------------- Phase 2：输入 + sink（桥用） ----------------

// 四种受支持样本类型的逐样本换算（R-6：不猜格式，其余已在 create 期拒绝）。
// 函数级调用开销相对引擎 process 可忽略；换取输入/输出类型自由组合的简洁正确。
static float ReadSample(const void* buf, long type, long i) {
    switch (type) {
    case ASIOSTFloat32LSB: return static_cast<const float*>(buf)[i];
    case ASIOSTInt32LSB:   return static_cast<const int32_t*>(buf)[i] / 2147483648.0f;
    case ASIOSTInt24LSB: {
        const uint8_t* p = static_cast<const uint8_t*>(buf) + i * 3;
        int32_t v = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16));
        if (v & 0x800000) v |= ~0xFFFFFF;   // 符号扩展（24-bit 补码）
        return v / 8388608.0f;
    }
    case ASIOSTInt16LSB:   return static_cast<const int16_t*>(buf)[i] / 32768.0f;
    default:               return 0.0f;
    }
}

static void WriteSample(void* buf, long type, long i, float v) {
    switch (type) {
    case ASIOSTFloat32LSB: static_cast<float*>(buf)[i] = v; break;
    case ASIOSTInt32LSB:   static_cast<int32_t*>(buf)[i] = (int32_t)lrintf(v * 2147483647.0f); break;
    case ASIOSTInt24LSB: {
        const int32_t s = (int32_t)lrintf(v * 8388607.0f);
        uint8_t* p = static_cast<uint8_t*>(buf) + i * 3;
        p[0] = (uint8_t)(s & 0xFF);
        p[1] = (uint8_t)((s >> 8) & 0xFF);
        p[2] = (uint8_t)((s >> 16) & 0xFF);
        break;
    }
    case ASIOSTInt16LSB:   static_cast<int16_t*>(buf)[i] = (int16_t)lrintf(v * 32767.0f); break;
    default: break;   // create 期已拒绝，防御性静默
    }
}

static bool TypeSupported(long t) {
    return t == ASIOSTFloat32LSB || t == ASIOSTInt32LSB ||
           t == ASIOSTInt24LSB || t == ASIOSTInt16LSB;
}

void AsioHost::set_process_sink(ProcessSink fn, void* ctx) {
    sink_ = fn;
    sinkCtx_ = ctx;
}

bool AsioHost::create_stereo_io(long bufSize, long outPair, std::string& why) {
    if (!opened_) { why = "host not open"; return false; }
    if (buffers_) { why = "buffers already created"; return false; }

    long inCh = 0, outCh = 0;
    if (ASIOGetChannels(&inCh, &outCh) != ASE_OK) { why = "getChannels failed"; return false; }
    if (inCh < 2) {
        char b[96];
        _snprintf_s(b, sizeof(b), _TRUNCATE, "driver has %ld input channels (<2)", inCh);
        why = b;
        return false;
    }
    if (outCh < 2) {
        char b[96];
        _snprintf_s(b, sizeof(b), _TRUNCATE, "driver has %ld output channels (<2)", outCh);
        why = b;
        return false;
    }
    if (outPair < 0) outPair = 0;
    if (outPair + 1 >= outCh) {
        char b[128];
        _snprintf_s(b, sizeof(b), _TRUNCATE,
                    "outPair %ld out of range (outCh=%ld)", outPair, outCh);
        why = b;
        return false;
    }
    long mn = 0, mx = 0, pref = 0, gran = 0;
    if (ASIOGetBufferSize(&mn, &mx, &pref, &gran) != ASE_OK) { why = "getBufferSize failed"; return false; }
    const long bs = (bufSize > 0) ? bufSize : pref;
    if (bs <= 0) { why = "invalid buffer size"; return false; }
    if (bs > kMaxNbs) {
        char b[128];
        _snprintf_s(b, sizeof(b), _TRUNCATE, "buffer size %ld > kMaxNbs %ld", bs, kMaxNbs);
        why = b;
        return false;
    }

    // 输入 ch0/1 + 输出 outPair/outPair+1
    ASIOBufferInfo infos[4];
    int nInfos = 0;
    for (int ch = 0; ch < 2; ++ch) {
        infos[nInfos].isInput = ASIOTrue;
        infos[nInfos].channelNum = ch;
        infos[nInfos].buffers[0] = infos[nInfos].buffers[1] = nullptr;
        ++nInfos;
    }
    for (int ch = 0; ch < 2; ++ch) {
        infos[nInfos].isInput = ASIOFalse;
        infos[nInfos].channelNum = outPair + ch;
        infos[nInfos].buffers[0] = infos[nInfos].buffers[1] = nullptr;
        ++nInfos;
    }

    // 回调结构体必须进程级生存期（同 create_output_stereo；驱动存 +0xd0 后
    // 每帧回调，栈局部会被后续调用覆写 → 首次回调即踩垃圾指针）。
    ASIOCallbacks& cb = s_cb;
    memset(&cb, 0, sizeof(cb));
    cb.bufferSwitch = &AsioHost::buffer_switch;
    cb.sampleRateDidChange = &AsioHost::sample_rate_did_change;
    cb.asioMessage = &AsioHost::asio_message;
    cb.bufferSwitchTimeInfo = &AsioHost::buffer_switch_time_info;

    ASIOError rc = ASIOCreateBuffers(infos, nInfos, bs, &cb);
    if (rc != ASE_OK) {
        char b[96];
        _snprintf_s(b, sizeof(b), _TRUNCATE, "ASIOCreateBuffers rc=%ld", (long)rc);
        why = b;
        return false;
    }

    // 逐声道取类型与缓冲地址（输入条目在前、输出对在后）
    const int inBase = 0;
    const int outBase = 2;
    for (int ch = 0; ch < 2; ++ch) {
        ASIOChannelInfo ci;
        memset(&ci, 0, sizeof(ci));
        ci.channel = ch;
        ci.isInput = ASIOTrue;
        if (ASIOGetChannelInfo(&ci) != ASE_OK) {
            ASIODisposeBuffers();
            why = "getChannelInfo(input) failed after createBuffers";
            return false;
        }
        inType_[ch] = ci.type;
        inBufs_[ch][0] = infos[inBase + ch].buffers[0];
        inBufs_[ch][1] = infos[inBase + ch].buffers[1];
    }
    for (int ch = 0; ch < 2; ++ch) {
        ASIOChannelInfo ci;
        memset(&ci, 0, sizeof(ci));
        ci.channel = outPair + ch;
        ci.isInput = ASIOFalse;
        if (ASIOGetChannelInfo(&ci) != ASE_OK) {
            ASIODisposeBuffers();
            why = "getChannelInfo(output) failed after createBuffers";
            return false;
        }
        outType_[ch] = ci.type;
        outBufs_[ch][0] = infos[outBase + ch].buffers[0];
        outBufs_[ch][1] = infos[outBase + ch].buffers[1];
    }
    for (int ch = 0; ch < 2; ++ch) {
        if (!TypeSupported(inType_[ch])) {
            ASIODisposeBuffers();
            char b[160];
            _snprintf_s(b, sizeof(b), _TRUNCATE,
                        "unsupported input sample type ch%d: %s (%ld)",
                        ch, sample_type_name(inType_[ch]), inType_[ch]);
            why = b;
            return false;
        }
        if (!TypeSupported(outType_[ch])) {
            ASIODisposeBuffers();
            char b[160];
            _snprintf_s(b, sizeof(b), _TRUNCATE,
                        "unsupported output sample type ch%d: %s (%ld)",
                        ch, sample_type_name(outType_[ch]), outType_[ch]);
            why = b;
            return false;
        }
    }
    double sr = 0.0;
    if (ASIOGetSampleRate(&sr) != ASE_OK || sr <= 0.0) {
        ASIODisposeBuffers();
        why = "getSampleRate failed";
        return false;
    }
    // scratch（控制线程分配；RT 只读指针）
    scratchIn_ = (float*)malloc(sizeof(float) * 2 * (size_t)kMaxNbs);
    scratchOut_ = (float*)malloc(sizeof(float) * 2 * (size_t)kMaxNbs);
    if (!scratchIn_ || !scratchOut_) {
        free(scratchIn_); free(scratchOut_);
        scratchIn_ = scratchOut_ = nullptr;
        ASIODisposeBuffers();
        why = "scratch alloc failed";
        return false;
    }
    bufSize_ = bs;
    sampleRate_ = sr;
    srLive_.store(sr, std::memory_order_relaxed);
    outPair_ = outPair;
    buffers_ = true;
    return true;
}

void AsioHost::tone_set(float freqHz, float amp) {
    toneFreq_.store(freqHz, std::memory_order_relaxed);
    toneAmp_.store(amp, std::memory_order_relaxed);
    toneOn_.store(true, std::memory_order_release);
}

void AsioHost::tone_off() { toneOn_.store(false, std::memory_order_release); }

// ---------------- SDK 回调（RT 线程） ----------------

void AsioHost::buffer_switch(long doubleBufferIndex, ASIOBool directProcess) {
    (void)directProcess;
    if (s_active) s_active->process(doubleBufferIndex);
}

ASIOTime* AsioHost::buffer_switch_time_info(ASIOTime* params, long doubleBufferIndex,
                                            ASIOBool directProcess) {
    // 本宿主 asioMessage 对 kAsioSupportsTimeInfo 答 0，正常不会走到这里；
    // 防御性实现：直接处理并返回驱动传入的 time 结构。
    (void)directProcess;
    if (s_active) s_active->process(doubleBufferIndex);
    return params;
}

void AsioHost::sample_rate_did_change(ASIOSampleRate sRate) {
    if (s_active) s_active->srLive_.store((double)sRate, std::memory_order_relaxed);
}

long AsioHost::asio_message(long selector, long value, void* message, double* opt) {
    (void)value; (void)message; (void)opt;
    switch (selector) {
    case kAsioEngineVersion:     return 2;   // 宿主 ASIO 2
    case kAsioSupportsTimeInfo:  return 0;   // 用旧式 bufferSwitch
    case kAsioSupportsTimeCode:  return 0;
    case kAsioSupportsInputMonitor: return 0;
    case kAsioLatenciesChanged:  // Phase 4：置位等控制面消费（重建 caps/延迟展示）
        if (s_active) s_active->latenciesChanged_.store(true, std::memory_order_release);
        return 1;
    case kAsioResyncRequest:     return 1;   // 信息性：tone/桥无语序依赖
    case kAsioResetRequest:      // Phase 4：驱动请求重置（采样率/设备变化等）——
        // RT 回调上下文，绝不在此重建（buffer 重建必须控制面串行）。置位后
        // 由桥的 status 心跳带回宿主，宿主走热切换（stop→caps→create→start）。
        if (s_active) s_active->resetPending_.store(true, std::memory_order_release);
        return 1;
    default:                     return 0;
    }
}

void AsioHost::process(long doubleBufferIndex) {
    // Phase 4 掉线检测的 RT 侧唯一动作：记 QPC。Win10+ QPC 为用户态内联
    //（rdtsc/不变时钟源，不进内核），满足 RT 铁律"零 syscall"；欠载判定
    // 本身放控制面（asio_status），RT 侧只留这一个写。
    LARGE_INTEGER q;
    QueryPerformanceCounter(&q);
    lastSwitchQpc_.store((uint64_t)q.QuadPart, std::memory_order_relaxed);
    if (sink_) {
        process_io(doubleBufferIndex);
        return;
    }
    switches_.fetch_add(1, std::memory_order_relaxed);
    const bool tone = toneOn_.load(std::memory_order_relaxed);
    const float amp = toneAmp_.load(std::memory_order_relaxed);
    const double w0 = tone ? (2.0 * _PI * (double)toneFreq_.load(std::memory_order_relaxed)) : 0.0;
    double sr = srLive_.load(std::memory_order_relaxed);
    if (!(sr > 0.0)) sr = 48000.0;   // 防御：rate 未知按 48k（仅影响 tone 音高）
    const double dPhase = w0 / sr;
    const long n = bufSize_;
    float peak = 0.0f;

    for (int ch = 0; ch < 2; ++ch) {
        void* buf = outBufs_[ch][doubleBufferIndex];
        if (!buf) continue;
        const long t = outType_[ch];
        if (t == ASIOSTFloat32LSB) {
            float* p = static_cast<float*>(buf);
            for (long i = 0; i < n; ++i) {
                float s = 0.0f;
                if (tone) {
                    s = amp * (float)sin(phase_);
                    phase_ += dPhase;
                    if (phase_ >= 2.0 * _PI) phase_ -= 2.0 * _PI;
                }
                p[i] = s;
                const float a = fabsf(s);
                if (a > peak) peak = a;
            }
        } else if (t == ASIOSTInt32LSB) {
            int32_t* p = static_cast<int32_t*>(buf);
            for (long i = 0; i < n; ++i) {
                float s = 0.0f;
                if (tone) {
                    s = amp * (float)sin(phase_);
                    phase_ += dPhase;
                    if (phase_ >= 2.0 * _PI) phase_ -= 2.0 * _PI;
                }
                p[i] = (int32_t)lrintf(s * 2147483647.0f);
                const float a = fabsf(s);
                if (a > peak) peak = a;
            }
        } else if (t == ASIOSTInt24LSB) {
            uint8_t* p = static_cast<uint8_t*>(buf);
            for (long i = 0; i < n; ++i) {
                float s = 0.0f;
                if (tone) {
                    s = amp * (float)sin(phase_);
                    phase_ += dPhase;
                    if (phase_ >= 2.0 * _PI) phase_ -= 2.0 * _PI;
                }
                const int32_t v = (int32_t)lrintf(s * 8388607.0f);
                p[i * 3 + 0] = (uint8_t)(v & 0xFF);
                p[i * 3 + 1] = (uint8_t)((v >> 8) & 0xFF);
                p[i * 3 + 2] = (uint8_t)((v >> 16) & 0xFF);
                const float a = fabsf(s);
                if (a > peak) peak = a;
            }
        } else if (t == ASIOSTInt16LSB) {
            int16_t* p = static_cast<int16_t*>(buf);
            for (long i = 0; i < n; ++i) {
                float s = 0.0f;
                if (tone) {
                    s = amp * (float)sin(phase_);
                    phase_ += dPhase;
                    if (phase_ >= 2.0 * _PI) phase_ -= 2.0 * _PI;
                }
                p[i] = (int16_t)lrintf(s * 32767.0f);
                const float a = fabsf(s);
                if (a > peak) peak = a;
            }
        }
        // create_output_stereo 已保证 t 必为上述四种之一
    }
    peak_.store(peak, std::memory_order_relaxed);
}

void AsioHost::process_io(long doubleBufferIndex) {
    switches_.fetch_add(1, std::memory_order_relaxed);
    const long n = bufSize_;
    if (n <= 0) return;
    // 爆音预算：整块（搬运 + sink）耗时打点（QPC 无等待；同 05）。
    LARGE_INTEGER t0, t1;
    QueryPerformanceCounter(&t0);
    float peakIn = 0.0f, peakOut = 0.0f;
    if (n <= kMaxNbs && scratchIn_ && scratchOut_) {
        // ① 输入分声道 → 交织 float32
        for (int ch = 0; ch < 2; ++ch) {
            const void* ib = inBufs_[ch][doubleBufferIndex];
            const long t = inType_[ch];
            if (!ib) continue;
            for (long i = 0; i < n; ++i) {
                const float v = ReadSample(ib, t, i);
                scratchIn_[i * 2 + ch] = v;
                const float a = fabsf(v);
                if (a > peakIn) peakIn = a;
            }
        }
        // ② sink（桥内：测试注入 → engine process / bypass；RT 安全由桥保证）
        sink_(sinkCtx_, scratchIn_, scratchOut_, (int)n);
        // ③ 交织 → 输出分声道
        for (int ch = 0; ch < 2; ++ch) {
            void* ob = outBufs_[ch][doubleBufferIndex];
            const long t = outType_[ch];
            if (!ob) continue;
            for (long i = 0; i < n; ++i) {
                const float v = scratchOut_[i * 2 + ch];
                WriteSample(ob, t, i, v);
                const float a = fabsf(v);
                if (a > peakOut) peakOut = a;
            }
        }
    } else {
        // 超长块 / scratch 缺失（理论不可达——create 期已钳 kMaxNbs）：
        // 声道级直通，绝不吞声（逐样本换算保类型正确）。
        for (int ch = 0; ch < 2; ++ch) {
            const void* ib = inBufs_[ch][doubleBufferIndex];
            void* ob = outBufs_[ch][doubleBufferIndex];
            if (!ib || !ob) continue;
            for (long i = 0; i < n; ++i) WriteSample(ob, outType_[ch], i, ReadSample(ib, inType_[ch], i));
        }
    }
    QueryPerformanceCounter(&t1);
    const uint64_t dt = (uint64_t)(t1.QuadPart - t0.QuadPart);
    if (dt > maxCbTicks_.load(std::memory_order_relaxed))
        maxCbTicks_.store(dt, std::memory_order_relaxed);
    peakIn_.store(peakIn, std::memory_order_relaxed);
    peak_.store(peakOut, std::memory_order_relaxed);
}

}  // namespace auraasio
