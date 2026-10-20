#include "plugin_thread.h"

namespace auradsp {

thread_local PluginThreadRole t_pluginThreadRole = PluginThreadRole::Main;

} // namespace auradsp
