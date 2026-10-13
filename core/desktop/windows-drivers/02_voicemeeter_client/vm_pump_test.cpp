// vm_pump_test.cpp — Voicemeeter OUTPUT INSERT 泵测试 CLI（smoke 用）。
// 用法：vm_pump_test [seconds=5] [engine_dll]
// 输出单行 JSON。VM 不存在/槽被占/启动失败 → ran=false + note，退出码仍 0。
#include <cstdio>
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
    AuraVmPumpRun(p);
    printf("{\"ran\":%s,\"frames\":%llu,\"maxDiff\":%.9f,"
           "\"bypassEntered\":%s,\"startRc\":%d,\"sampleRate\":%d,\"nbs\":%d,"
           "\"changes\":%ld,\"note\":\"%s\"}\n",
           p.ran ? "true" : "false", (unsigned long long)p.frames, p.maxDiff,
           p.bypassEntered ? "true" : "false", p.startRc, p.sampleRate, p.nbs,
           p.changes, JsonEscape(p.note).c_str());
    return 0;
}
