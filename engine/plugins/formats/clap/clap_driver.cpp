#include "plugin_format_driver.h"

#include "clap_instance.h"
#include "clap_metadata.h"
#include "plugin_bundle.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace auradsp {
namespace {

class ClapFormatDriver final : public IPluginFormatDriver {
public:
    PluginFormat format() const override { return PluginFormat::CLAP; }
    const char* name() const override { return "CLAP"; }

    bool matchesPath(const std::string& path) const override {
        std::string ext = path;
        const size_t dot = ext.find_last_of('.');
        if (dot == std::string::npos) return false;
        ext = ext.substr(dot);
        std::transform(ext.begin(), ext.end(), ext.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return ext == ".clap";
    }

    std::string resolveBinary(const std::string& bundlePath,
                              std::string* outArch = nullptr) const override {
        return resolvePluginBundleBinary(bundlePath, ".clap", outArch);
    }

    bool supportsQuickMetadata() const override { return true; }

    bool queryMetadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& out) override {
        return queryClapMetadata(bundlePath, binaryPath, out);
    }

    std::unique_ptr<IPluginInstance> createInstance() override {
        return createClapInstance();
    }
};

} // namespace

std::unique_ptr<IPluginFormatDriver> createClapFormatDriver() {
    return std::make_unique<ClapFormatDriver>();
}

} // namespace auradsp
