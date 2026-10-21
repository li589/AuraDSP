#include "plugin_format_driver.h"

#include "plugin_bundle.h"
#include "vst3_instance.h"
#include "vst3_query.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace auradsp {
namespace {

class Vst3FormatDriver final : public IPluginFormatDriver {
public:
    PluginFormat format() const override { return PluginFormat::VST3; }
    const char* name() const override { return "VST3"; }

    bool matchesPath(const std::string& path) const override {
        std::string ext = path;
        const size_t dot = ext.find_last_of('.');
        if (dot == std::string::npos) return false;
        ext = ext.substr(dot);
        std::transform(ext.begin(), ext.end(), ext.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return ext == ".vst3";
    }

    std::string resolveBinary(const std::string& bundlePath,
                              std::string* outArch = nullptr) const override {
        return resolvePluginBundleBinary(bundlePath, ".vst3", outArch);
    }

    bool supportsQuickMetadata() const override { return false; }

    bool queryMetadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& out) override {
        return queryVst3Metadata(bundlePath, binaryPath, out);
    }

    std::unique_ptr<IPluginInstance> createInstance() override {
        return createVst3Instance();
    }
};

} // namespace

std::unique_ptr<IPluginFormatDriver> createVst3FormatDriver() {
    return std::make_unique<Vst3FormatDriver>();
}

} // namespace auradsp
