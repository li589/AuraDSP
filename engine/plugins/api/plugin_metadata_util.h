#pragma once
// 扫描/加载共用的元数据填充原语。只依赖 PluginMetadata，不依赖任何格式 SDK。

#include "plugin_host.h"

#include <string>

namespace auradsp {

inline void fillMetadataIfEmpty(std::string& dst, const std::string& src) {
    if (dst.empty() && !src.empty()) dst = src;
}

/* 以扫描期元数据为基准初始化加载路 meta：只搬描述性字段，
 * 运行期字段（latency / isCompatible / errorMessage）一律重置。 */
inline void seedMetadataFromScan(PluginMetadata& dst, const PluginMetadata& src) {
    dst.path = src.path;
    dst.id = src.id;
    dst.name = src.name;
    dst.bundleName = src.bundleName;
    dst.vendor = src.vendor;
    dst.version = src.version;
    dst.category = src.category;
    dst.description = src.description;
    dst.format = src.format;
    dst.is64Bit = src.is64Bit;
    dst.latency = 0;
    dst.isCompatible = true;
    dst.errorMessage.clear();
}

} // namespace auradsp
