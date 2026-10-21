#include "plugin_bundle.h"

#include <algorithm>
#include <filesystem>

namespace fs = std::filesystem;

namespace auradsp {
namespace {

bool extensionEqualsCI(const fs::path& p, const char* lowerExt) {
    std::string ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return ext == lowerExt;
}

} // namespace

std::string resolvePluginBundleBinary(const std::string& bundlePath,
                                     const char* lowerExtension,
                                     std::string* outArch) {
    std::error_code ec;
    if (outArch) outArch->clear();
    if (!lowerExtension) return "";
    if (fs::is_directory(bundlePath, ec)) {
        // 探测顺序即偏好顺序：本进程架构（x86_64-win）优先，32 位（x86-win）
        // 作为"能发现但不能加载"的条目进入列表（isCompatible=false）。
        static const char* const kArchDirs[] = {"x86_64-win", "x86-win"};
        for (const char* arch : kArchDirs) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / arch;
            if (!fs::exists(subBinary, ec)) continue;
            for (const auto& entry : fs::directory_iterator(subBinary, ec)) {
                // 大小写不敏感：内层二进制叫 Upper.VST3 时严格比较会漏掉整包。
                if (extensionEqualsCI(entry.path(), lowerExtension)) {
                    if (outArch) *outArch = arch;
                    return entry.path().string();
                }
            }
        }
        // It is a directory, but does not contain a supported plugin binary -> invalid
        return "";
    }
    return bundlePath;
}

} // namespace auradsp
