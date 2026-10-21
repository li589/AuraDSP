#include "plugin_json.h"

#include "plugin_host.h"

#include <iomanip>
#include <sstream>

namespace auradsp {

std::string escapeJsonString(const std::string& input) {
    std::ostringstream ss;
    for (char c : input) {
        switch (c) {
            case '"':  ss << "\\\""; break;
            case '\\': ss << "\\\\"; break;
            case '\b': ss << "\\b";  break;
            case '\f': ss << "\\f";  break;
            case '\n': ss << "\\n";  break;
            case '\r': ss << "\\r";  break;
            case '\t': ss << "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < ' ') {
                    ss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                } else {
                    ss << c;
                }
        }
    }
    return ss.str();
}

std::string PluginMetadata::toJson() const {
    std::ostringstream ss;
    ss << "{"
       << "\"path\":\"" << escapeJsonString(path) << "\","
       << "\"id\":\"" << escapeJsonString(id) << "\","
       << "\"name\":\"" << escapeJsonString(name) << "\","
       << "\"bundleName\":\"" << escapeJsonString(bundleName) << "\","
       << "\"vendor\":\"" << escapeJsonString(vendor) << "\","
       << "\"version\":\"" << escapeJsonString(version) << "\","
       << "\"category\":\"" << escapeJsonString(category) << "\","
       << "\"description\":\"" << escapeJsonString(description) << "\","
       << "\"format\":\"" << (format == PluginFormat::VST3 ? "VST3" : (format == PluginFormat::CLAP ? "CLAP" : "Unknown")) << "\","
       << "\"is64Bit\":" << (is64Bit ? "true" : "false") << ","
       << "\"latency\":" << latency << ","
       << "\"isCompatible\":" << (isCompatible ? "true" : "false") << ","
       << "\"errorMessage\":\"" << escapeJsonString(errorMessage) << "\""
       << "}";
    return ss.str();
}

} // namespace auradsp
