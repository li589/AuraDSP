// AuraTestVST2Bad — 导出 VSTPluginMain 但返回坏 magic 的 DLL（门禁用）。
// 用于验证驱动拒绝路径：不得崩溃、不得把坏插件当可用实例。

#include "vst2/vst.h"

#include <cstring>

extern "C" __declspec(dllexport) vst_effect_t* VST_FUNCTION_INTERFACE
VSTPluginMain(vst_host_callback_t callback) {
    (void)callback;
    static vst_effect_t bad = {};
    std::memset(&bad, 0, sizeof(bad));
    bad.magic_number = 0x12345678;   // 非 'VstP'
    bad.num_inputs = 2;
    bad.num_outputs = 2;
    return &bad;
}
