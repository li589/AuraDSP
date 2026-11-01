// plugin_chain_adapter_stub.cpp — 插件子系统裁剪（AURADSP_ENABLE_PLUGINS=OFF）时的
// 链阶段占位：所有插件阶段直通，厂商 DSP 链行为与「未挂插件」完全一致。
//
// 背景（跨平台基础审查 CP-02，2026-11-01）：插件宿主（VST3/CLAP + Win32 扫描/编辑器）
// 是 Windows 强依赖子系统。Linux/macOS 构建必须能整体裁掉，否则 windows.h/PE 读取
// 会阻断编译。本文件与 plugin_abi_stub.cpp 一起维持 C ABI 导出集不增不减（F3）。
//
// RT 契约：五个函数都是空操作/恒真，不进任何分配或系统调用，可安全进入音频路径。
#include "plugins/integration/plugin_chain_adapter.h"

namespace auradsp {

bool plugin_chain_prepare(auradsp_handle h, double sampleRate,
                          uint32_t maxBlockSize) {
    (void)h;
    (void)sampleRate;
    (void)maxBlockSize;
    return true;
}

void plugin_chain_reset(auradsp_handle h) {
    (void)h;
}

void plugin_chain_process(auradsp_handle h, int stage, float* interleaved,
                          uint32_t frames) noexcept {
    (void)h;
    (void)stage;
    (void)interleaved;
    (void)frames;
}

void plugin_chain_process_n(auradsp_handle h, int stage, float* interleaved,
                            uint32_t frames, uint32_t channels) noexcept {
    (void)h;
    (void)stage;
    (void)interleaved;
    (void)frames;
    (void)channels;
}

void plugin_chain_set_channel_hint(auradsp_handle h, int channels) noexcept {
    (void)h;
    (void)channels;
}

} // namespace auradsp
