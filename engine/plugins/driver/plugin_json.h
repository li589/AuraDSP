#pragma once
// 插件元数据 JSON 序列化（不依赖格式 SDK）。

#include <string>

namespace auradsp {

std::string escapeJsonString(const std::string& input);

} // namespace auradsp
