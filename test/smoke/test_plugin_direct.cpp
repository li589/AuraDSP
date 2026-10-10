#include <windows.h>
#include <iostream>
#include "auradsp_plugin_host.h"

int main() {
    std::cout << "Starting test..." << std::endl;
    try {
        auradsp::PluginHostManager mgr;
        std::cout << "PluginHostManager created ok." << std::endl;
        const char* path = "C:\\Program Files\\Common Files\\VST3\\ValhallaSupermassive.vst3";
        std::cout << "Calling loadPlugin..." << std::endl;
        bool ok = mgr.loadPlugin(path, "", 48000.0, 1024);
        std::cout << "loadPlugin returned: " << ok << std::endl;
    } catch (const std::exception& e) {
        std::cout << "Caught std::exception: " << e.what() << std::endl;
    } catch (...) {
        std::cout << "Caught unknown exception!" << std::endl;
    }
    return 0;
}
