#pragma once
/*
 * preset_io.h — 插件预设文件的原子写与提交（2026-11-08 审计·预设中2）。
 *
 * 引擎侧三格式（VST3/CLAP/VST2）的预设保存统一口径：先写同目录 .tmp，
 * 写流无误后 rename 覆盖目标——保存途中崩溃/断电不留截断的目标文件
 * （对齐 App 侧 DocumentStore 的 APP-01 原子写口径）。rename 在 POSIX
 * 与 MSVC STL 的 std::filesystem 实现上均为原子替换既有文件。
 */
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <system_error>

namespace auradsp {
namespace preset_io {

inline std::string tmpPathFor(const std::string& targetPath) {
    return targetPath + ".tmp";
}

inline void discardTmpFile(const std::string& tmpPath) {
    std::error_code ec;
    std::filesystem::remove(tmpPath, ec);
}

// tmp 已写完并关闭后调用：rename 覆盖目标；失败清 tmp 并返回 false。
inline bool commitTmpFile(const std::string& tmpPath,
                          const std::string& targetPath) {
    std::error_code ec;
    std::filesystem::rename(tmpPath, targetPath, ec);
    if (ec) {
        discardTmpFile(tmpPath);
        return false;
    }
    return true;
}

// 缓冲型保存（VST3/VST2）：writeFn 向流写全部内容并报告流状态；
// 任一环节失败都清 tmp、目标文件保持原样。
inline bool writeFileAtomic(
    const std::string& targetPath,
    const std::function<bool(std::ofstream&)>& writeFn) {
    const std::string tmpPath = tmpPathFor(targetPath);
    {
        std::ofstream ofs(tmpPath, std::ios::binary | std::ios::trunc);
        if (!ofs) return false;
        if (!writeFn(ofs) || !ofs.good()) {
            ofs.close();
            discardTmpFile(tmpPath);
            return false;
        }
        ofs.close();
        if (ofs.fail()) {
            discardTmpFile(tmpPath);
            return false;
        }
    }
    return commitTmpFile(tmpPath, targetPath);
}

}  // namespace preset_io
}  // namespace auradsp
