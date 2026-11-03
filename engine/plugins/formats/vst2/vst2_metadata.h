#pragma once
// VST2 深扫元数据（2026-11-03）。只在 Windows 编译；实现见 vst2_metadata.cpp。

#include "plugin_host.h"

#include <string>
#include <vector>

namespace auradsp {

bool queryVst2Metadata(const std::string& bundlePath, const std::string& binaryPath,
                       std::vector<PluginMetadata>& out);

} // namespace auradsp
