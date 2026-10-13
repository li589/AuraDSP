// vm_detect.cpp — Voicemeeter 三级自省探针 CLI（smoke 用）。
// 输出单行 JSON（UTF-8），供 test/smoke/smoke_vm_detect.py 解析断言。
#include <cstdio>
#include <string>

#include "VmRemoteLoader.h"

namespace {

std::string JsonEscape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 2);
    for (const char c : s) {
        if (c == '"' || c == '\\')
            o += '\\';
        o += c;
    }
    return o;
}

}  // namespace

int main() {
    const AuraVmDetect d = AuraVmDetectRun();
    printf("{\"found\":%s,\"edition\":%d,\"editionName\":\"%s\","
           "\"installDir\":\"%s\",\"appVersion\":\"%s\",\"remoteVersion\":\"%s\","
           "\"tierReached\":%d}\n",
           d.found ? "true" : "false", d.edition, d.editionName.c_str(),
           JsonEscape(d.installDir).c_str(), JsonEscape(d.appVersion).c_str(),
           JsonEscape(d.remoteVersion).c_str(), d.tierReached);
    return 0;
}
