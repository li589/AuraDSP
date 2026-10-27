// test_dll_dirs.cpp — F1 验收：插件依赖 DLL 搜索目录的通用化 + cookie 回收。
//
// 背景（审查 F1，P1→边界 P0）：原实现只服务 iZotope——路径含
// izotope|ozone 时加 6 条 `C:\Program Files\iZotope\Ozone 12\...` 字面量
// 目录；且 AddDllDirectory 返回的 cookie 直接丢弃、showEditor 每次都再调
// 一次 → 进程搜索路径单调增长，后续插件解析同名 DLL 可能绑到别人的私有
// 副本（ABI 不匹配 → 崩溃）。
//
// 本测试不依赖任何真插件，用临时目录树验证：
//   1) 通用化：插件目录 + 父目录 + 存在的常见子目录（win64/Cores/bin/x64/
//      lib/lib64）被登记，父目录扫描即覆盖「依赖放安装根」的厂商；
//   2) 幂等：同一路径反复 setup 200 次，目录数不增长；
//   3) 引用计数：两个插件共用父目录时，卸载其一不摘共用目录；
//   4) 回收：全部卸载后目录数回到基线（cookie 已被 RemoveDllDirectory）；
//   5) 环境变量 AURADSP_PLUGIN_DLL_DIRS 生效且不随插件卸载回收。
//
// 输出：末行单行 JSON；退出码 0 = 全过。
#include <windows.h>

#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include "win32_util.h"

namespace fs = std::filesystem;
using namespace auradsp;

namespace {

struct Fail {
    bool ok = true;
    std::string why;
    void Check(bool cond, const char* what, const std::string& detail = "") {
        if (!cond && ok) {
            ok = false;
            why = std::string(what) + (detail.empty() ? "" : (" | " + detail));
        }
    }
};

bool contains(const std::vector<std::string>& v, const std::string& needleLower) {
    for (const auto& s : v) {
        if (s.find(needleLower) != std::string::npos) return true;
    }
    return false;
}

std::string lower(std::string s) {
    for (auto& c : s) c = (char)tolower((unsigned char)c);
    return s;
}

}  // namespace

int main() {
    Fail f;
    wchar_t tmp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, tmp);
    const std::wstring rootW =
        (fs::path(tmp) / (L"auradsp_dlldir_" + std::to_wstring(GetCurrentProcessId()))).wstring();
    const fs::path root(rootW);
    std::error_code ec;
    fs::remove_all(root, ec);

    // 目录树：
    //   root/VendorA/pluginA.vst3/          （bundle 目录）
    //   root/VendorA/pluginA2.vst3/
    //   root/VendorA/win64/                 （依赖子目录）
    //   root/VendorA/Cores/                 （依赖子目录）
    //   root/sharedEnv/                     （环境变量目录）
    fs::create_directories(root / "VendorA" / "pluginA.vst3" / "win64");
    fs::create_directories(root / "VendorA" / "pluginA2.vst3");
    fs::create_directories(root / "VendorA" / "win64");
    fs::create_directories(root / "VendorA" / "Cores");
    fs::create_directories(root / "sharedEnv");

    // 环境变量必须在首次 setup 之前设置（进程级只解析一次）
    SetEnvironmentVariableW(L"AURADSP_PLUGIN_DLL_DIRS", (root / "sharedEnv").wstring().c_str());

    const std::string pluginA = wideToUtf8((root / "VendorA" / "pluginA.vst3").wstring());
    const std::string pluginA2 = wideToUtf8((root / "VendorA" / "pluginA2.vst3").wstring());

    // ---- 1) 首次 setup：环境变量目录 + 插件目录 + 父目录 + 2 个存在的子目录
    setupPluginDllDirectories(pluginA);
    const size_t afterA = pluginDllDirectoryCount();
    const auto listA = pluginDllDirectoryList();
    f.Check(contains(listA, lower(wideToUtf8((root / "sharedEnv").wstring()))),
            "env var dir registered");
    f.Check(contains(listA, lower(wideToUtf8((root / "VendorA" / "pluginA.vst3").wstring()))),
            "plugin dir registered");
    f.Check(contains(listA, lower(wideToUtf8((root / "VendorA").wstring()))),
            "parent dir registered (vendor 依赖放安装根由此覆盖)");
    f.Check(contains(listA, lower(wideToUtf8((root / "VendorA" / "win64").wstring()))),
            "common subdir win64 registered");
    f.Check(contains(listA, lower(wideToUtf8((root / "VendorA" / "Cores").wstring()))),
            "common subdir Cores registered");
    f.Check(contains(listA, lower(wideToUtf8((root / "VendorA" / "pluginA.vst3" / "win64").wstring()))),
            "bundle-internal subdir registered");
    // sharedEnv + pluginA.vst3 + VendorA + VendorA/win64 + VendorA/Cores
    // + pluginA.vst3/win64
    f.Check(afterA == 6, "dir count after first setup", std::to_string(afterA));
    const size_t refsA = pluginDllDirectoryRefs();

    // ---- 2) 幂等：反复 setup（等价于每次 showEditor 都调）不增长
    for (int i = 0; i < 200; ++i) setupPluginDllDirectories(pluginA);
    const size_t afterRepeat = pluginDllDirectoryCount();
    const size_t refsRepeat = pluginDllDirectoryRefs();
    f.Check(afterRepeat == afterA, "idempotent: dir count stable over 200 calls",
            std::to_string(afterRepeat) + " vs " + std::to_string(afterA));
    f.Check(refsRepeat == refsA, "idempotent: refs stable over 200 calls",
            std::to_string(refsRepeat) + " vs " + std::to_string(refsA));

    // ---- 3) 共用父目录：第二个插件只新增自身目录，父目录引用计数 +1
    setupPluginDllDirectories(pluginA2);
    const size_t afterA2 = pluginDllDirectoryCount();
    f.Check(afterA2 == afterA + 1, "second plugin adds only its own dir",
            std::to_string(afterA2) + " vs " + std::to_string(afterA + 1));

    // ---- 4) 回收其一：共用父目录必须保留（另一插件还在用）
    releasePluginDllDirectories(pluginA);
    const auto listAfterRel = pluginDllDirectoryList();
    f.Check(contains(listAfterRel, lower(wideToUtf8((root / "VendorA").wstring()))),
            "shared parent dir kept while another plugin uses it");
    f.Check(!contains(listAfterRel, lower(wideToUtf8((root / "VendorA" / "pluginA.vst3").wstring()))),
            "plugin A own dir released");
    f.Check(contains(listAfterRel, lower(wideToUtf8((root / "VendorA" / "win64").wstring()))),
            "parent subdir kept while another plugin uses it");
    f.Check(!contains(listAfterRel, lower(wideToUtf8((root / "VendorA" / "pluginA.vst3" / "win64").wstring()))),
            "plugin A exclusive subdir released");
    f.Check(pluginDllDirectoryCount() == 5, "count after releasing A",
            std::to_string(pluginDllDirectoryCount()));

    // ---- 5) 回收其二：回到基线（仅环境变量目录，且它不随插件回收）
    releasePluginDllDirectories(pluginA2);
    const auto listEnd = pluginDllDirectoryList();
    f.Check(contains(listEnd, lower(wideToUtf8((root / "sharedEnv").wstring()))),
            "env var dir is permanent (not released with plugin)");
    f.Check(pluginDllDirectoryCount() == 1, "count back to env-only baseline",
            std::to_string(pluginDllDirectoryCount()));
    f.Check(pluginDllDirectoryRefs() == 1, "refs back to baseline",
            std::to_string(pluginDllDirectoryRefs()));

    // ---- 6) 重复 release 无害
    releasePluginDllDirectories(pluginA);
    releasePluginDllDirectories("");
    f.Check(pluginDllDirectoryCount() == 1, "double release harmless",
            std::to_string(pluginDllDirectoryCount()));

    SetEnvironmentVariableW(L"AURADSP_PLUGIN_DLL_DIRS", nullptr);
    fs::remove_all(root, ec);

    printf("{\"ok\":%s,\"afterA\":%zu,\"afterA2\":%zu,\"afterRelease\":%zu,"
           "\"refsA\":%zu,\"refsAfterRelease\":%zu,\"note\":\"%s\"}\n",
           f.ok ? "true" : "false", afterA, afterA2, pluginDllDirectoryCount(), refsA,
           pluginDllDirectoryRefs(), f.why.c_str());
    return f.ok ? 0 : 1;
}
