#pragma once

#include "auradsp_engine.h"

#include <cstdint>

namespace auradsp {

bool plugin_chain_prepare(auradsp_handle h, double sampleRate,
                          uint32_t maxBlockSize);
void plugin_chain_reset(auradsp_handle h);
void plugin_chain_process(auradsp_handle h, int stage, float* interleaved,
                          uint32_t frames) noexcept;
void plugin_chain_process_n(auradsp_handle h, int stage, float* interleaved,
                            uint32_t frames, uint32_t channels) noexcept;
void plugin_chain_set_channel_hint(auradsp_handle h, int channels) noexcept;

} // namespace auradsp
