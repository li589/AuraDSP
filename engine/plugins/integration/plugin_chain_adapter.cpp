#include "plugins/integration/plugin_chain_adapter.h"

#include "engine_internal.h"
#include "plugins/driver/plugin_chain_component.h"

#include <new>

namespace auradsp {

bool plugin_chain_prepare(auradsp_handle h, double sampleRate,
                          uint32_t maxBlockSize) {
    if (!h) return false;

    if (!h->plugin.chain) {
        h->plugin.chain.reset(new (std::nothrow) PluginChainComponent());
        if (!h->plugin.chain) return false;
    }
    return h->plugin.chain->prepare(sampleRate, maxBlockSize);
}

void plugin_chain_reset(auradsp_handle h) {
    if (!h || !h->plugin.chain) return;
    h->plugin.chain->reset();
    h->plugin.chain.reset();
}

void plugin_chain_process(auradsp_handle h, int stage, float* interleaved,
                          uint32_t frames) noexcept {
    if (!h || !h->plugin.chain) return;
    h->plugin.chain->processInterleaved(stage, interleaved, frames);
}

} // namespace auradsp
