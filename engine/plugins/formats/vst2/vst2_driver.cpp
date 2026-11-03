/*
 * vst2_driver.cpp — VST2 格式驱动（2026-11-03）。
 *
 * VST2 没有 bundle：一个 .dll 就是一个候选。扩展名匹配只做 .dll，
 * 真正的「是不是插件」由 resolveBinary 里的 PE 导出表判定（不加载 DLL）。
 */

#include "plugin_format_driver.h"

#include "vst2_instance.h"
#include "vst2_metadata.h"
#include "win32_util.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace auradsp {
namespace {

class Vst2FormatDriver final : public IPluginFormatDriver {
public:
    PluginFormat format() const override { return PluginFormat::VST2; }
    const char* name() const override { return "VST2"; }

    bool matchesPath(const std::string& path) const override {
        const size_t dot = path.find_last_of('.');
        if (dot == std::string::npos) return false;
        std::string ext = path.substr(dot);
        std::transform(ext.begin(), ext.end(), ext.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return ext == ".dll";
    }

    std::string resolveBinary(const std::string& bundlePath,
                              std::string* outArch = nullptr) const override {
        if (outArch) outArch->clear();
        std::error_code ec;
        if (fs::is_directory(bundlePath, ec)) return "";
        if (!fs::is_regular_file(bundlePath, ec)) return "";
        // PE 导出表判定：没有 VSTPluginMain / main 的 DLL 不是 VST2 插件
        // （同目录的依赖库、运行库都会被这一条挡掉）。
        return peHasVst2Entry(utf8ToWide(bundlePath)) ? bundlePath : "";
    }

    bool supportsQuickMetadata() const override { return false; }

    bool queryMetadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& out) override {
        return queryVst2Metadata(bundlePath, binaryPath, out);
    }

    std::unique_ptr<IPluginInstance> createInstance() override {
        return createVst2Instance();
    }
};

} // namespace

std::unique_ptr<IPluginFormatDriver> createVst2FormatDriver() {
    return std::make_unique<Vst2FormatDriver>();
}

} // namespace auradsp
