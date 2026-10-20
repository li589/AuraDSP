#pragma once

#include <memory>

namespace auradsp {

class PluginChainComponent;

struct PluginEngineState {
    PluginEngineState();
    ~PluginEngineState();

    PluginEngineState(const PluginEngineState&) = delete;
    PluginEngineState& operator=(const PluginEngineState&) = delete;
    PluginEngineState(PluginEngineState&&) = delete;
    PluginEngineState& operator=(PluginEngineState&&) = delete;

    PluginChainComponent* component() const noexcept { return chain.get(); }

    std::unique_ptr<PluginChainComponent> chain;
};

} // namespace auradsp
