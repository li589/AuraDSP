#include <windows.h>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include "auradsp_plugin_host.h"

// 实时落盘。默认 std::cout 重定向到文件时是全缓冲，进程若被超时杀掉，
// 缓冲区内容全部丢失——日志会停在最后一个 flush 点，把真正的卡点掩盖成
// "上一步之后就没输出"。诊断死锁时这是假根因的常见来源。
namespace {

using Clock = std::chrono::steady_clock;

Clock::time_point g_stageStart = Clock::now();

// 打印阶段耗时，便于把"卡住"精确定位到某一次调用而不是某个大步骤。
void stage(const char* what) {
    auto now = Clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - g_stageStart).count();
    std::cout << "[t+" << ms << "ms] " << what << std::endl;
    g_stageStart = now;
}

} // namespace

int main(int argc, char** argv) {
    std::cout << std::unitbuf; // 每条输出立即 flush，避免缓冲区吞掉卡点现场
    OleInitialize(NULL);
    std::cout << "Starting diagnostic test..." << std::endl;
    auradsp::PluginHostManager mgr;

    // B3 验收点名（docs/插件模块深度改良方案-2026-10-12.md §5/§6）：
    // 用户反馈的三个问题插件 × open → 交互 → close → unload 全生命周期。
    struct TestCase {
        const char* path;
        auradsp::PluginFormat fmt;
        const char* id;
    };

    TestCase cases[] = {
        {"C:\\Program Files\\Common Files\\VST3\\Antares\\Auto-Tune EFX+.vst3", auradsp::PluginFormat::VST3, ""},
        {"C:\\Program Files\\Common Files\\VST3\\ConvologyXT_64.vst3", auradsp::PluginFormat::VST3, ""},
        {"C:\\Program Files\\Common Files\\CLAP\\KV-Element-FX.clap", auradsp::PluginFormat::CLAP, "net.kushview.ElementFX"},
    };

    // argv[1] = 每个插件的加载-卸载循环次数（B3-④ 连跑验证），默认 1。
    int iterations = 1;
    if (argc > 1) {
        iterations = std::atoi(argv[1]);
        if (iterations < 1) iterations = 1;
    }
    std::cout << "iterations per plugin: " << iterations << std::endl;

    for (const auto& tc : cases) {
        std::cout << "\n----------------------------------------" << std::endl;
        std::cout << "Testing plugin: " << tc.path << std::endl;
        std::vector<auradsp::PluginMetadata> metaList;
        auradsp::PluginScanner::queryMetadata(tc.path, tc.fmt, metaList);
        for (const auto& m : metaList) {
            std::cout << "  Meta Class: " << m.name << " CID: " << m.id << " category: " << m.category << std::endl;
        }

        std::string targetId = tc.id;
        if (targetId.empty() && !metaList.empty()) targetId = metaList[0].id;
        std::cout << "Target ID: " << targetId << std::endl;

        for (int iter = 0; iter < iterations; ++iter) {
            if (iterations > 1) {
                std::cout << "\n  ---- iteration " << (iter + 1) << "/" << iterations << " ----" << std::endl;
            }
            stage("loadPluginSlot");
            bool loadOk = mgr.loadPluginSlot(0, tc.path, targetId, 48000.0, 1024);
            stage("loadPluginSlot done");
            std::cout << "Final mgr.loadPluginSlot returned: " << loadOk << std::endl;
            if (loadOk) {
                stage("showEditorSlot");
                bool edOk = mgr.showEditorSlot(0);
                stage("showEditorSlot done");
                std::cout << "Final mgr.showEditorSlot returned: " << edOk << std::endl;
                std::cout << "isEditorOpen: " << mgr.isEditorOpenSlot(0) << std::endl;

                Sleep(500);

                stage("closeEditorSlot");
                mgr.closeEditorSlot(0);
                stage("closeEditorSlot done");
                std::cout << "isEditorOpen after close: " << mgr.isEditorOpenSlot(0) << std::endl;

                stage("unloadPluginSlot");
                mgr.unloadPluginSlot(0);
                stage("unloadPluginSlot done");
            } else {
                // 加载失败也要卸载清理，保持迭代间状态干净
                mgr.unloadPluginSlot(0);
            }
        }
    }

    // C1（2026-10-12）：多槽挂载同一插件——共享泵线程（ModulePumpThread）验证。
    // argv[2] == "dualslot" 时执行。场景：
    //   ① 同路径同时挂槽 0/1（LoadLibrary 同模块 → 两条实例共享一条泵线程）
    //   ② 两个编辑器同时打开（标题必须可区分，见 Dart 侧槽位号）
    //   ③ 关掉槽 0 编辑器 → 槽 1 编辑器必须仍然存活可交互
    //   ④ 开着编辑器卸载槽 0 → 槽 1 不受影响
    //   ⑤ 卸载槽 1（最后一实例）→ 泵线程才停，DLL 才卸载
    // B3 之前每实例一条线程，② 即 JUCE MessageManager 死锁；共享泵下应全绿。
    if (argc > 2 && std::string(argv[2]) == "dualslot") {
        std::cout << "\n===== C1 dual-slot same-plugin test =====" << std::endl;
        struct DualCase { const char* path; auradsp::PluginFormat fmt; const char* id; };
        DualCase duals[] = {
            {"C:\\Program Files\\Common Files\\VST3\\Antares\\Auto-Tune EFX+.vst3", auradsp::PluginFormat::VST3, ""},
            {"C:\\Program Files\\Common Files\\CLAP\\KV-Element-FX.clap", auradsp::PluginFormat::CLAP, "net.kushview.ElementFX"},
        };
        for (const auto& tc : duals) {
            std::cout << "\n---- dual-slot: " << tc.path << " ----" << std::endl;
            std::vector<auradsp::PluginMetadata> metaList;
            auradsp::PluginScanner::queryMetadata(tc.path, tc.fmt, metaList);
            if (metaList.empty()) {
                std::cout << "SKIP: plugin not present" << std::endl;
                continue;
            }
            std::string targetId = tc.id;
            if (targetId.empty()) targetId = metaList[0].id;

            stage("load slot0");
            bool ok0 = mgr.loadPluginSlot(0, tc.path, targetId, 48000.0, 1024);
            stage("load slot1");
            bool ok1 = mgr.loadPluginSlot(1, tc.path, targetId, 48000.0, 1024);
            std::cout << "slot0 load=" << ok0 << " slot1 load=" << ok1 << std::endl;
            if (!ok0 || !ok1) {
                mgr.unloadPluginSlot(0);
                mgr.unloadPluginSlot(1);
                std::cout << "FAIL: dual load" << std::endl;
                continue;
            }

            stage("show editor slot0");
            bool e0 = mgr.showEditorSlot(0, "C1-Dual Slot 1");
            stage("show editor slot1");
            bool e1 = mgr.showEditorSlot(1, "C1-Dual Slot 2");
            std::cout << "editor0=" << e0 << " editor1=" << e1
                      << " open0=" << mgr.isEditorOpenSlot(0)
                      << " open1=" << mgr.isEditorOpenSlot(1) << std::endl;
            if (!e0 || !e1 || !mgr.isEditorOpenSlot(0) || !mgr.isEditorOpenSlot(1)) {
                std::cout << "FAIL: dual editors" << std::endl;
            }
            Sleep(500);

            stage("close editor slot0");
            mgr.closeEditorSlot(0);
            std::cout << "after close: open0=" << mgr.isEditorOpenSlot(0)
                      << " open1=" << mgr.isEditorOpenSlot(1) << std::endl;
            if (mgr.isEditorOpenSlot(0) || !mgr.isEditorOpenSlot(1)) {
                std::cout << "FAIL: slot1 editor must survive slot0 close" << std::endl;
            }
            Sleep(300);

            stage("unload slot0 with slot1 editor open");
            mgr.unloadPluginSlot(0);
            std::cout << "after unload0: open1=" << mgr.isEditorOpenSlot(1) << std::endl;
            if (!mgr.isEditorOpenSlot(1)) {
                std::cout << "FAIL: slot1 editor must survive slot0 unload" << std::endl;
            }
            Sleep(300);

            stage("close editor slot1");
            mgr.closeEditorSlot(1);
            stage("unload slot1 (last instance)");
            mgr.unloadPluginSlot(1);
            std::cout << "dual-slot case complete: " << tc.path << std::endl;
        }
        stage("dual-slot test done");
    }
    stage("all cases done");
    return 0;
}
