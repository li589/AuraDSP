#pragma once
// 无 SDK 依赖的 VST3 元数据查询入口。

#include "plugin_host.h"

#include <string>
#include <vector>

namespace auradsp {

bool queryVst3Metadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& outPlugins);

} // namespace auradsp
