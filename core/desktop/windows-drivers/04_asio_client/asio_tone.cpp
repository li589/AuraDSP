// asio_tone.cpp — ASIO 驱动正弦发声测试（04_asio_client Phase 1）
//
// 对标 03_system_apo/tone_play.cpp：选定驱动 → 创建输出缓冲 → 播放正弦 N 秒 →
// 干净退出。验证 open/createBuffers/bufferSwitch/start/stop 全链路可跑。
// RT 铁律：bufferSwitch 内零分配零锁（正弦相位在 AsioHost::process 内增量推进）。
//
// 用法：
//   asio_tone [--driver <名称|序号>] [--seconds 3.0] [--freq 440]
//             [--amp 0.25] [--bufsize 0(=preferred)]
// 输出 JSON（stdout）：{"rc":0,"driver":"...","index":N,"seconds":...,"switches":N,
//                      "peak":0.xx,"bufSize":N,"sampleRate":R,"sampleType":"..."}
// 退出码：0=跑完；非 0=失败（err 字段说明）。

#include <windows.h>
#include <objbase.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "AsioHost.h"

namespace {

void json_escape(std::string& out, const std::string& s) {
    for (char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n";  break;
        case '\r': out += "\\r";  break;
        case '\t': out += "\\t";  break;
        default:
            if ((unsigned char)c < 0x20) {
                char b[8];
                _snprintf_s(b, sizeof(b), _TRUNCATE, "\\u%04x", (unsigned)(unsigned char)c);
                out += b;
            } else {
                out += c;
            }
        }
    }
}

bool parse_long(const char* s, long& out) {
    if (!s || !*s) return false;
    char* end = nullptr;
    out = strtol(s, &end, 10);
    return end && *end == 0;
}

bool parse_double(const char* s, double& out) {
    if (!s || !*s) return false;
    char* end = nullptr;
    out = strtod(s, &end);
    return end && *end == 0;
}

}  // namespace

int main(int argc, char* argv[]) {
    std::string driverArg = "0";   // 默认第一个枚举到的驱动
    double seconds = 3.0;
    float freq = 440.0f;
    float amp = 0.25f;
    long bufSize = 0;              // 0 = preferred

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--driver") && i + 1 < argc) driverArg = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) parse_double(argv[++i], seconds);
        else if (!strcmp(argv[i], "--freq") && i + 1 < argc) { double v; if (parse_double(argv[++i], v)) freq = (float)v; }
        else if (!strcmp(argv[i], "--amp") && i + 1 < argc) { double v; if (parse_double(argv[++i], v)) amp = (float)v; }
        else if (!strcmp(argv[i], "--bufsize") && i + 1 < argc) parse_long(argv[++i], bufSize);
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("usage: asio_tone [--driver <name|index>] [--seconds 3.0] [--freq 440] "
                   "[--amp 0.25] [--bufsize 0]\n");
            return 0;
        }
    }

    const HRESULT comHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool comOurs = SUCCEEDED(comHr);

    std::string result = "{\"rc\":1";
    int rc = 1;
    std::string driverName;   // 显示名（UTF-8，进 JSON）
    std::string loadName;     // SDK load 键（原始 ANSI）
    long index = -1;

    std::vector<auraasio::DriverEntry> drivers;
    try {
        drivers = auraasio::enumerate_drivers();
    } catch (...) {
        result += ",\"err\":\"enumerate threw\"";
        goto done;
    }
    if (drivers.empty()) {
        result += ",\"err\":\"no ASIO drivers in registry\"";
        goto done;
    }

    // 解析 --driver：纯数字按序号，否则按精确名称（大小写敏感）
    {
        long idx = -1;
        if (parse_long(driverArg.c_str(), idx) && idx >= 0 && idx < (long)drivers.size()) {
            index = idx;
        } else {
            // 用户按显示名（UTF-8）匹配；命中后仍用原始 name 做 SDK load 键
            for (size_t k = 0; k < drivers.size(); ++k) {
                if (drivers[k].nameUtf8 == driverArg) { index = (long)k; break; }
            }
        }
        if (index < 0) {
            result += ",\"err\":\"driver not found: ";
            json_escape(result, driverArg);
            result += "\",\"available\":[";
            for (size_t k = 0; k < drivers.size(); ++k) {
                if (k) result += ",";
                result += "\""; json_escape(result, drivers[k].nameUtf8); result += "\"";
            }
            result += "]";
            goto done;
        }
        driverName = drivers[(size_t)index].nameUtf8;
        loadName = drivers[(size_t)index].name;   // 原始 ANSI：SDK 匹配键
    }

    {
        auraasio::AsioHost host;
        std::string why;
        const HWND console = GetConsoleWindow();
        if (!host.open(loadName.c_str(), (void*)console, why)) {
            result += ",\"err\":\""; json_escape(result, why); result += "\"";
            goto done;
        }
        if (!host.create_output_stereo(bufSize, why)) {
            host.close();
            result += ",\"err\":\""; json_escape(result, why); result += "\"";
            goto done;
        }
        host.tone_set(freq, amp);
        if (!host.start()) {
            host.close();
            result += ",\"err\":\"ASIOStart failed\"";
            goto done;
        }

        // 轮询等待（控制线程；RT 回调自有线程）
        const ULONGLONG t0 = GetTickCount64();
        const ULONGLONG totalMs = (ULONGLONG)(seconds * 1000.0);
        while (GetTickCount64() - t0 < totalMs) Sleep(50);

        host.stop();
        const uint64_t switches = host.switch_count();
        const float peak = host.peak_out();
        const long bs = host.buffer_size();
        const double sr = host.sample_rate();
        const char* stName = auraasio::sample_type_name(host.out_sample_type());
        host.close();

        char b[256];
        result = "{\"rc\":0,\"driver\":\""; json_escape(result, driverName);
        result += "\",\"index\":" + std::to_string(index);
        _snprintf_s(b, sizeof(b), _TRUNCATE, "%.3f", seconds); result += ",\"seconds\":"; result += b;
        result += ",\"switches\":" + std::to_string(switches);
        _snprintf_s(b, sizeof(b), _TRUNCATE, "%.4f", peak); result += ",\"peak\":"; result += b;
        result += ",\"bufSize\":" + std::to_string(bs);
        _snprintf_s(b, sizeof(b), _TRUNCATE, "%.1f", sr); result += ",\"sampleRate\":"; result += b;
        result += ",\"sampleType\":\""; result += stName; result += "\"";
        rc = 0;
    }

done:
    result += "}";
    printf("%s\n", result.c_str());
    if (comOurs) CoUninitialize();
    return rc;
}
