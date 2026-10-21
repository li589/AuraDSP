#pragma once
// CLAP 元数据查询与描述符填充。SDK 类型只在 formats/clap 内可见。

#include "plugin_host.h"

#include <string>
#include <vector>

struct clap_plugin_descriptor;

namespace auradsp {

void applyClapDescriptor(PluginMetadata& meta,
                         const clap_plugin_descriptor* d,
                         const std::wstring& binaryPath,
                         const std::string& bundlePath);

bool queryClapMetadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& outPlugins);

} // namespace auradsp
