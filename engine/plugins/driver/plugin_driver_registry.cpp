#include "plugin_format_driver.h"

#include <algorithm>
#include <utility>

namespace auradsp {

PluginDriverRegistry& PluginDriverRegistry::instance() {
    static PluginDriverRegistry registry;
    return registry;
}

PluginDriverRegistry::PluginDriverRegistry() {
    if (auto clap = createClapFormatDriver()) {
        m_drivers.push_back(std::move(clap));
    }
    if (auto vst3 = createVst3FormatDriver()) {
        m_drivers.push_back(std::move(vst3));
    }
#if defined(_WIN32) || defined(__linux__)
    /* VST2：2026-11-03 首落地仅 Windows 注册；2026-11-04 Linux 跟进
     * （POSIX peHasVst2Entry 按 ELF 动态符号表判定入口、驱动源编入
     * Linux 目标），两平台同口径注册。 */
    if (auto vst2 = createVst2FormatDriver()) {
        m_drivers.push_back(std::move(vst2));
    }
#endif
}

IPluginFormatDriver* PluginDriverRegistry::find(PluginFormat format) const {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto it = m_drivers.rbegin(); it != m_drivers.rend(); ++it) {
        if ((*it)->format() == format) return it->get();
    }
    return nullptr;
}

IPluginFormatDriver* PluginDriverRegistry::findForPath(const std::string& path) const {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto it = m_drivers.rbegin(); it != m_drivers.rend(); ++it) {
        if ((*it)->matchesPath(path)) return it->get();
    }
    return nullptr;
}

std::vector<PluginFormat> PluginDriverRegistry::formats() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    std::vector<PluginFormat> out;
    out.reserve(m_drivers.size());
    for (const auto& driver : m_drivers) out.push_back(driver->format());
    return out;
}

bool PluginDriverRegistry::registerDriver(std::unique_ptr<IPluginFormatDriver> driver) {
    if (!driver) return false;
    std::lock_guard<std::mutex> lock(m_mutex);
    m_drivers.push_back(std::move(driver));
    return true;
}

bool PluginDriverRegistry::unregisterDriver(IPluginFormatDriver* driver) {
    if (!driver) return false;
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = std::find_if(m_drivers.begin(), m_drivers.end(),
                           [driver](const auto& p) { return p.get() == driver; });
    if (it == m_drivers.end()) return false;
    m_drivers.erase(it);
    return true;
}

} // namespace auradsp
