// vm_pump_test.cpp — Voicemeeter OUTPUT INSERT 泵测试 CLI（smoke 用）。
// 用法：vm_pump_test [seconds=5] [engine_dll] [--seti id=int] [--setf id=float]...
// 输出单行 JSON。VM 不存在/槽被占/启动失败 → ran=false + note，退出码仍 0。
#include <cstdio>
#include <cstdlib>
#include <string>

#include "VmAudioCallback.h"

namespace {

std::string JsonEscape(const std::string& s) {
    std::string o;
    for (const char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        o += c;
    }
    return o;
}

}  // namespace

int main(int argc, char** argv) {
    AuraVmPump p;
    if (argc > 1) p.seconds = atoi(argv[1]);
    if (p.seconds <= 0 || p.seconds > 60) p.seconds = 5;
    if (argc > 2) p.engineDll = argv[2];
    // --seti id=int / --setf id=float（可重复；Start 前全 handle 下发）。
    for (int i = 3; i + 1 < argc; i += 2) {
        const std::string flag(argv[i]);
        const std::string kv(argv[i + 1]);
        const size_t eq = kv.find('=');
        if ((flag != "--seti" && flag != "--setf") || eq == std::string::npos) continue;
        AuraVmParam pm;
        pm.id = kv.substr(0, eq);
        pm.isFloat = (flag == "--setf");
        if (pm.isFloat)
            pm.f = (float)atof(kv.substr(eq + 1).c_str());
        else
            pm.i = atoi(kv.substr(eq + 1).c_str());
        p.params.push_back(pm);
    }
    AuraVmPumpRun(p);
    printf("{\"ran\":%s,\"frames\":%llu,\"maxDiff\":%.9f,"
           "\"bypassEntered\":%s,\"startRc\":%d,\"sampleRate\":%d,\"nbs\":%d,"
           "\"changes\":%ld,\"edition\":%d,\"groups\":%d,\"handles\":%d,"
           "\"warmupMs\":%d,\"maxCbUs\":%.1f,\"peakIn\":%.6f,\"paramsApplied\":%d,\"paramsFailed\":%d,"
           "\"engine\":\"%s\",\"note\":\"%s\"}\n",
           p.ran ? "true" : "false", (unsigned long long)p.frames, p.maxDiff,
           p.bypassEntered ? "true" : "false", p.startRc, p.sampleRate, p.nbs,
           p.changes, p.edition, p.groups, p.handles, p.warmupMs, p.maxCbUs, p.peakIn,
           p.paramsApplied, p.paramsFailed,
           JsonEscape(p.enginePath).c_str(), JsonEscape(p.note).c_str());
    return 0;
}
