#pragma once
// VST2 实例工厂（2026-11-03）。实现见 vst2_instance.cpp。

#include "plugin_host.h"

#include <memory>

namespace auradsp {

std::unique_ptr<IPluginInstance> createVst2Instance();

} // namespace auradsp
