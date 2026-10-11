#include <windows.h>
#include <iostream>
#include "auradsp_plugin_host.h"

int main() {
    OleInitialize(NULL);
    std::cout << "Starting diagnostic test..." << std::endl;
    auradsp::PluginHostManager mgr;

    struct TestCase {
        const char* path;
        auradsp::PluginFormat fmt;
        const char* id;
    };

    TestCase cases[] = {
        {"C:\\Program Files\\Common Files\\CLAP\\KV-Element-FX.clap", auradsp::PluginFormat::CLAP, "net.kushview.ElementFX"},
        {"C:\\Program Files\\Common Files\\VST3\\FabFilter\\FabFilter Pro-Q 3.vst3", auradsp::PluginFormat::VST3, ""},
        {"C:\\Program Files\\Common Files\\VST3\\iZotope\\Ozone 12 Equalizer.vst3", auradsp::PluginFormat::VST3, ""}
    };

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

        bool loadOk = mgr.loadPluginSlot(0, tc.path, targetId, 48000.0, 1024);
        std::cout << "Final mgr.loadPluginSlot returned: " << loadOk << std::endl;
        if (loadOk) {
            bool edOk = mgr.showEditorSlot(0);
            std::cout << "Final mgr.showEditorSlot returned: " << edOk << std::endl;
            Sleep(500);
            mgr.closeEditorSlot(0);
            mgr.unloadPluginSlot(0);
        }
    }
    return 0;
}
