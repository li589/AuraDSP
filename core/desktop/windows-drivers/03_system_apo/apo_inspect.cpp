// apo_inspect.cpp — APO 只读检测 CLI（smoke 用）。
// 输出单行 JSON。不提权、不写注册表、不碰音频服务。
#include <cstdio>
#include <string>

#include "ApoInspector.h"

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

int main() {
    const ApoInspect r = ApoInspectRun();
    printf("{\"endpoints\":[");
    bool first = true;
    for (const auto& e : r.endpoints) {
        if (!first) printf(",");
        first = false;
        printf("{\"id\":\"%s\",\"direction\":\"%s\",\"name\":\"%s\",\"state\":%lu,"
               "\"enhancementsDisabled\":%s,\"readable\":%s,\"friendlyName\":\"%s\",\"fx\":[",
               JsonEscape(e.id).c_str(), e.direction.c_str(), JsonEscape(e.name).c_str(), e.state,
               e.enhancementsDisabled ? "true" : "false", e.readable ? "true" : "false",
               JsonEscape(e.friendlyName).c_str());
        bool f2 = true;
        for (const auto& s : e.fx) {
            if (!f2) printf(",");
            f2 = false;
            printf("{\"key\":\"%s\",\"value\":\"%s\"}", JsonEscape(s.key).c_str(),
                   JsonEscape(s.value).c_str());
        }
        printf("]}");
    }
    printf("],\"protectedAudioDG\":%d,\"note\":\"%s\"}\n", r.protectedAudioDG,
           JsonEscape(r.note).c_str());
    return 0;
}
