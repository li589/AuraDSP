// asio_probe.cpp — ASIO 驱动枚举 + 能力探测（04_asio_engine Phase 1）
//
// 无音频、零声学风险：只枚举注册表 → 逐个 open/query/close。
// 输出 JSON（stdout）：
//   {"tool":"asio_probe","count":N,"drivers":[{...}, ...]}
// 每个驱动条目含注册表信息（name/dll/clsid）与能力快照（ok 或 err）。
// 用法：
//   asio_probe [--only <子串>]     # 只探测名称含子串的驱动（调试用）
// 退出码：0=枚举完成（个别驱动 open 失败不视为工具失败）；1=枚举本身失败。

#include <windows.h>
#include <objbase.h>
#include <cstdio>
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
        case '\b': out += "\\b";  break;
        case '\f': out += "\\f";  break;
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

}  // namespace

int main(int argc, char* argv[]) {
    std::string only;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--only") && i + 1 < argc) only = argv[++i];
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("usage: asio_probe [--only <substr>]\n");
            return 0;
        }
    }

    // 防御性 COM 初始化（AsioDriverList 构造时也可能已 Init；重复 STA 调用返回 S_FALSE）
    const HRESULT comHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool comOurs = SUCCEEDED(comHr);

    std::vector<auraasio::DriverEntry> drivers;
    try {
        drivers = auraasio::enumerate_drivers();
    } catch (...) {
        printf("{\"tool\":\"asio_probe\",\"error\":\"enumerate threw\"}\n");
        if (comOurs) CoUninitialize();
        return 1;
    }

    std::string j = "{\"tool\":\"asio_probe\",\"count\":";
    j += std::to_string(drivers.size());
    j += ",\"drivers\":[";
    bool first = true;
    int opened = 0;
    for (const auto& d : drivers) {
        if (!only.empty() && d.nameUtf8.find(only) == std::string::npos) continue;
        if (!first) j += ",";
        first = false;
        j += "{\"name\":\"";   json_escape(j, d.nameUtf8);
        j += "\",\"dll\":\"";  json_escape(j, d.dllPath);
        j += "\",\"clsid\":\""; json_escape(j, d.clsid);
        j += "\",";

        auraasio::AsioHost host;
        std::string why;
        const HWND console = GetConsoleWindow();
        if (host.open(d.name.c_str(), (void*)console, why)) {
            ++opened;
            auraasio::DriverCaps caps;
            if (host.query_caps(caps)) {
                j += "\"ok\":true";
                j += ",\"driverName\":\""; json_escape(j, caps.driverName); j += "\"";
                j += ",\"asioVersion\":" + std::to_string(caps.asioVersion);
                j += ",\"driverVersion\":" + std::to_string(caps.driverVersion);
                j += ",\"inChannels\":" + std::to_string(caps.inChannels);
                j += ",\"outChannels\":" + std::to_string(caps.outChannels);
                j += ",\"minBuf\":" + std::to_string(caps.minBuf);
                j += ",\"maxBuf\":" + std::to_string(caps.maxBuf);
                j += ",\"prefBuf\":" + std::to_string(caps.prefBuf);
                j += ",\"granularity\":" + std::to_string(caps.granularity);
                j += ",\"inLatency\":" + std::to_string(caps.inLatency);
                j += ",\"outLatency\":" + std::to_string(caps.outLatency);
                char b[64];
                _snprintf_s(b, sizeof(b), _TRUNCATE, "%.1f", caps.sampleRate);
                j += ",\"sampleRate\":"; j += b;
                j += ",\"out0Type\":" + std::to_string(caps.out0Type);
                j += ",\"out0TypeName\":\""; json_escape(j, caps.out0TypeName); j += "\"";
                j += ",\"out0Name\":\""; json_escape(j, caps.out0Name); j += "\"";
                j += ",\"out0Active\":" + std::to_string(caps.out0Active);
            } else {
                j += "\"ok\":false,\"err\":\""; json_escape(j, caps.errorMessage); j += "\"";
            }
            host.close();
        } else {
            j += "\"ok\":false,\"err\":\""; json_escape(j, why); j += "\"";
        }
        j += "}";
    }
    j += "]}";
    printf("%s\n", j.c_str());
    fprintf(stderr, "asio_probe: %d drivers enumerated, %d opened\n",
            (int)drivers.size(), opened);

    if (comOurs) CoUninitialize();
    return 0;
}
