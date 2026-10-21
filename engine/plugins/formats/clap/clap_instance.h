#pragma once

#include "plugin_host.h"

#include <memory>

namespace auradsp {

std::unique_ptr<IPluginInstance> createClapInstance();

} // namespace auradsp
