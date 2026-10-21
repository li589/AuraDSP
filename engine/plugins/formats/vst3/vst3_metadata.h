#pragma once
// VST3 元数据查询与工厂信息填充。SDK 类型只在 formats/vst3 内可见。

#include "plugin_host.h"

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IPluginFactory.h>
#include <steinberg/vst3/base/IPluginFactory2.h>
#include <steinberg/vst3/base/IPluginFactory3.h>

#include <string>
#include <vector>

namespace auradsp {

bool applyVstAudioEffectClass(PluginMetadata& meta,
                              Steinberg::IPluginFactory* factory,
                              Steinberg::IPluginFactory2* factory2,
                              Steinberg::IPluginFactory3* factory3,
                              Steinberg::int32 index,
                              const std::wstring& binaryPath,
                              const std::string& bundlePath,
                              bool seeded = false,
                              Steinberg::TUID* outTuid = nullptr);

} // namespace auradsp
