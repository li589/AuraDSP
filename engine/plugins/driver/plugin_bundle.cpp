#include "plugin_bundle.h"

#include <algorithm>
#include <filesystem>
#include <vector>

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
#if defined(_WIN32)
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
#else
        // Linux bundle 布局（Steinberg 规范）：内层二进制是共享库
        // Contents/x86_64-linux/<Name>.so，32 位为 x86-linux。此前
        // 只有 Windows 架构目录，Linux 下 .vst3 bundle 恒解析为空、
        // 扫描枚举直接丢弃（目录型 VST3 在 Linux 完全不可见），
        // 双宿主路由也因 resolveBinary 失败落不到真实二进制。
        // 偏好顺序同 Windows 口径：本机架构优先，32 位可发现。
        static const char* const kArchDirs[] = {
            "x86_64-linux", "i686-linux", "i386-linux", "x86-linux"
        };
        const std::string bundleStem = fs::path(bundlePath).stem().string();
        for (const char* arch : kArchDirs) {
            fs::path subDir = fs::path(bundlePath) / "Contents" / arch;
            if (!fs::exists(subDir, ec)) continue;
            std::vector<fs::path> matches;
            for (const auto& entry : fs::directory_iterator(subDir, ec)) {
                if (!entry.is_regular_file(ec)) continue;
                // 内层以 .so 为准；个别打包把二进制命名为 .vst3
                // 后缀，一并接受（防御性）。
                if (extensionEqualsCI(entry.path(), ".so") ||
                    extensionEqualsCI(entry.path(), lowerExtension)) {
                    matches.push_back(entry.path());
                }
            }
            if (matches.empty()) continue;
            // 目录迭代序不确定：排序后优先与 bundle 同名的二进制，
            // 保证多文件目录下解析结果确定。
            std::sort(matches.begin(), matches.end());
            fs::path pick = matches.front();
            for (const auto& m : matches) {
                if (m.stem().string() == bundleStem) {
                    pick = m;
                    break;
                }
            }
            if (outArch) *outArch = arch;
            return pick.string();
        }
#endif
        // It is a directory, but does not contain a supported plugin binary -> invalid
        return "";
    }
    return bundlePath;
}

} // namespace auradsp
