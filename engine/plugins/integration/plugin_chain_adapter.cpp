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
    if (!h->plugin.chain->prepare(sampleRate, maxBlockSize)) return false;
    h->plugin.chain->setChannelHint(h->channel_count.load(std::memory_order_relaxed));
    return true;
}

void plugin_chain_reset(auradsp_handle h) {
    if (!h || !h->plugin.chain) return;
    h->plugin.chain->reset();
    h->plugin.chain.reset();
}

void plugin_chain_process(auradsp_handle h, int stage, float* interleaved,
                          uint32_t frames) noexcept {
    plugin_chain_process_n(h, stage, interleaved, frames, 2);
}

void plugin_chain_process_n(auradsp_handle h, int stage, float* interleaved,
                            uint32_t frames, uint32_t channels) noexcept {
    if (!h || !h->plugin.chain) return;
    h->plugin.chain->processInterleavedN(stage, interleaved, frames, channels);
}

void plugin_chain_set_channel_hint(auradsp_handle h, int channels) noexcept {
    if (!h || !h->plugin.chain) return;
    h->plugin.chain->setChannelHint(channels);
}

} // namespace auradsp
