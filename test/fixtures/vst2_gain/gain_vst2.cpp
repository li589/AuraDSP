// AuraTestVST2 — AuraDSP VST2 驱动自建探针（2026-11-03）。
//
// 最小 VST2 效果器：立体声入/出，process_float 逐样本乘 0.5，一个参数，
// 支持 chunk 存取。仅用于自动化门禁，不随产品分发。
// 导出宏按平台分开（Win: dllexport / POSIX: 默认可见性），Linux 门禁亦编本文件。

#include "vst2/vst.h"

#include <cstring>

namespace {

float g_param = 0.5f;
unsigned char g_chunk[sizeof(float)] = {};
int g_idleCount = 0;
bool g_callbackOk = false;
vst_rect_t g_editorRect = {0, 0, 100, 200};

void copyString(void* dst, const char* src) {
    if (!dst || !src) return;
    std::strncpy(static_cast<char*>(dst), src, 63);
    static_cast<char*>(dst)[63] = '\0';
}

intptr_t VST_FUNCTION_INTERFACE control(vst_effect_t* effect, int32_t opcode, int32_t index,
                                        intptr_t value, void* ptr, float opt) {
    (void)effect;
    (void)index;
    (void)opt;
    switch (opcode) {
        case VST_EFFECT_OPCODE_CREATE:
        case VST_EFFECT_OPCODE_DESTROY:
        case VST_EFFECT_OPCODE_SET_SAMPLE_RATE:
        case VST_EFFECT_OPCODE_SET_BLOCK_SIZE:
        case VST_EFFECT_OPCODE_SUSPEND_RESUME:
        case VST_EFFECT_OPCODE_PROCESS_BEGIN:
        case VST_EFFECT_OPCODE_PROCESS_END:
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_EDITOR_GET_RECT:
            if (ptr) *static_cast<vst_rect_t**>(ptr) = &g_editorRect;
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_EDITOR_OPEN:
        case VST_EFFECT_OPCODE_EDITOR_CLOSE:
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_EDITOR_KEEP_ALIVE:
            ++g_idleCount;
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_NAME:
        case VST_EFFECT_OPCODE_PRODUCT_NAME:
            copyString(ptr, "AuraTestVST2");
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_VENDOR_NAME:
            copyString(ptr, "AuraDSP");
            return VST_STATUS_TRUE;
        case VST_EFFECT_OPCODE_VENDOR_VERSION:
            return 1000;
        case VST_EFFECT_OPCODE_CATEGORY:
            return VST_EFFECT_CATEGORY_EFFECT;
        case VST_EFFECT_OPCODE_GET_CHUNK_DATA:
            if (ptr && value != 0) {
                std::memcpy(g_chunk, &g_param, sizeof(g_param));
                *static_cast<void**>(ptr) = g_chunk;
                return static_cast<intptr_t>(sizeof(g_chunk));
            }
            return 0;
        case VST_EFFECT_OPCODE_SET_CHUNK_DATA:
            if (ptr && value >= static_cast<intptr_t>(sizeof(float))) {
                std::memcpy(&g_param, ptr, sizeof(float));
                return VST_STATUS_TRUE;
            }
            return VST_STATUS_FALSE;
        default:
            return 0;
    }
}

void VST_FUNCTION_INTERFACE processFloat(vst_effect_t* effect, const float* const* inputs,
                                         float** outputs, int32_t samples) {
    (void)effect;
    if (!inputs || !outputs) return;
    for (int ch = 0; ch < 2; ++ch) {
        if (!outputs[ch]) continue;
        const float* in = inputs[ch] ? inputs[ch] : inputs[0];
        for (int32_t i = 0; i < samples; ++i) {
            // 回调 ABI 校验失败时输出 0，让门禁的 0.8→0.4 断言直接转红。
            outputs[ch][i] = (in ? in[i] : 0.0f) * (g_callbackOk ? 0.5f : 0.0f);
        }
    }
}

void VST_FUNCTION_INTERFACE setParameter(vst_effect_t* effect, uint32_t index, float value) {
    (void)effect;
    if (index == 0) g_param = value;
}

float VST_FUNCTION_INTERFACE getParameter(vst_effect_t* effect, uint32_t index) {
    (void)effect;
    return index == 0 ? g_param : 0.0f;
}

vst_effect_t g_effect = {};

} // namespace

#if defined(_WIN32)
#define VST2_FIXTURE_EXPORT __declspec(dllexport)
#else
#define VST2_FIXTURE_EXPORT __attribute__((visibility("default")))
#endif

extern "C" VST2_FIXTURE_EXPORT vst_effect_t* VST_FUNCTION_INTERFACE
VSTPluginMain(vst_host_callback_t callback) {
    // 真实走一遍 audioMaster：32 位宿主若把 p_int2 声明成 int64_t，
    // 这里 p_str / p_float 会错位（写坏地址或返回垃圾），g_callbackOk=false。
    // 注意：本探针也必须用 intptr_t 的修正签名，否则它在 32 位下会以
    // Xaymar 头的 int64_t 调用宿主，自己制造错位（真实插件按官方 ABI 调用）。
    using FixedCallback = intptr_t(VST_FUNCTION_INTERFACE*)(vst_effect_t*, int32_t,
                                                            int32_t, intptr_t, void*,
                                                            float);
    auto cb = reinterpret_cast<FixedCallback>(callback);
    g_callbackOk = false;
    if (cb) {
        const intptr_t version =
            cb(nullptr, VST_HOST_OPCODE_VST_VERSION, 0, 0, nullptr, 0.0f);
        char vendor[64] = {};
        const intptr_t got =
            cb(nullptr, VST_HOST_OPCODE_VENDOR_NAME, 0, 64, vendor, 0.0f);
        g_callbackOk = (version == 2400) && (got == VST_STATUS_TRUE) &&
                       (std::strcmp(vendor, "AuraDSP") == 0);
    }

    std::memset(&g_effect, 0, sizeof(g_effect));
    g_effect.magic_number = static_cast<int32_t>(VST_MAGICNUMBER);
    g_effect.control = &control;
    g_effect.set_parameter = &setParameter;
    g_effect.get_parameter = &getParameter;
    g_effect.num_programs = 1;
    g_effect.num_params = 1;
    g_effect.num_inputs = 2;
    g_effect.num_outputs = 2;
    g_effect.flags = VST_EFFECT_FLAG_SUPPORTS_FLOAT | VST_EFFECT_FLAG_CHUNKS |
                     VST_EFFECT_FLAG_EDITOR;
    g_effect.unique_id = static_cast<int32_t>(VST_FOURCC('A', 'u', 'r', 'a'));
    g_effect.version = 1000;
    g_effect.process_float = &processFloat;
    return &g_effect;
}
