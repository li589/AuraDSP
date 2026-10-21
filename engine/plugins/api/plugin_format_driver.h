/*
 * plugin_format_driver.h — 插件格式驱动边界（Phase 2）。
 *
 * driver/scanner 只依赖本头暴露的能力：扩展名匹配、bundle 解析、元数据查询、
 * 实例创建。VST3/CLAP SDK 头只允许出现在 formats/ 下，api/driver 不再直接
 * 认识具体格式。
 */

#ifndef AURADSP_PLUGIN_FORMAT_DRIVER_H
#define AURADSP_PLUGIN_FORMAT_DRIVER_H

#include "plugin_host.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace auradsp {

class IPluginFormatDriver {
public:
    virtual ~IPluginFormatDriver() = default;

    virtual PluginFormat format() const = 0;
    virtual const char* name() const = 0;

    /* 仅做扩展名判定，不触碰文件系统。 */
    virtual bool matchesPath(const std::string& path) const = 0;

    /* bundle 根路径 -> 真实二进制；outArch 语义同 PluginScanner。 */
    virtual std::string resolveBinary(const std::string& bundlePath,
                                      std::string* outArch = nullptr) const = 0;

    /* 快扫是否也值得走格式元数据（CLAP 可轻量查询，VST3 需 LoadLibrary）。 */
    virtual bool supportsQuickMetadata() const = 0;

    /* queryMetadata 的调用方已完成 32 位检测与 binaryPath 解析。 */
    virtual bool queryMetadata(const std::string& bundlePath,
                               const std::string& binaryPath,
                               std::vector<PluginMetadata>& out) = 0;

    virtual std::unique_ptr<IPluginInstance> createInstance() = 0;
};

class PluginDriverRegistry {
public:
    static PluginDriverRegistry& instance();

    PluginDriverRegistry(const PluginDriverRegistry&) = delete;
    PluginDriverRegistry& operator=(const PluginDriverRegistry&) = delete;

    IPluginFormatDriver* find(PluginFormat format) const;
    IPluginFormatDriver* findForPath(const std::string& path) const;
    std::vector<PluginFormat> formats() const;

    /* 后注册者优先：测试可用 fake driver 覆盖同格式内置实现。 */
    bool registerDriver(std::unique_ptr<IPluginFormatDriver> driver);
    bool unregisterDriver(IPluginFormatDriver* driver);

private:
    PluginDriverRegistry();

    mutable std::mutex m_mutex;
    std::vector<std::unique_ptr<IPluginFormatDriver>> m_drivers;
};

std::unique_ptr<IPluginFormatDriver> createVst3FormatDriver();
std::unique_ptr<IPluginFormatDriver> createClapFormatDriver();

} // namespace auradsp

#endif // AURADSP_PLUGIN_FORMAT_DRIVER_H
