/*
 * vst2_metadata.cpp — VST2 深扫元数据（2026-11-03）。
 *
 * VST2 没有 bundle，也没有描述符注册表：元数据只能加载 DLL、调用
 * VSTPluginMain、用 dispatcher 逐项询问。本文件只做「扫描期一次性」查询，
 * 不参与音频路径；所有插件调用都集中在同一个线程内完成，失败即卸载。
 *
 * 编译头是 vendor/plugin-api/vst2/vst.h（Xaymar 净室，BSD-3-Clause）。
 * 该头的 vst_host_callback_t 在 32 位下把 value 声明成 int64_t，不可直接
 * 用于宿主实现——本文件的 descriptorCallback 用 intptr_t 自定义签名。
 */

#include "vst2_metadata.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "plugin_metadata_util.h"
#include "platform/port/module.h"
#include "win32_util.h"

#include "vst2/vst.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace auradsp {
namespace {

using VstPluginMainProc = vst_effect_t*(VST_FUNCTION_INTERFACE*)(vst_host_callback_t);

thread_local std::string g_descriptorDirectory;

void copyCString(void* dst, size_t cap, const char* src) {
    if (!dst || cap == 0) return;
    char* out = static_cast<char*>(dst);
    if (!src || !*src) {
        out[0] = '\0';
        return;
    }
    size_t len = std::strlen(src);
    if (len >= cap) len = cap - 1;
    std::memcpy(out, src, len);
    out[len] = '\0';
}

void copyHostString(void* dst, intptr_t capHint, const char* src) {
    // VST2 规范标准长度：Vendor/Product 均为 64 字节。capHint<=0 时上限 64，
    // 绝不使用 strncpy 填充多余 \0 导致栈溢出/踩坏插件局部变量。
    size_t cap = (capHint > 0) ? static_cast<size_t>(capHint) : 64;
    if (cap > 256) cap = 256;
    copyCString(dst, cap, src);
}

std::string trimTrailingZeros(const std::string& s) {
    std::string out = s;
    while (!out.empty() && out.back() == '0') out.pop_back();
    while (!out.empty() && out.back() == '.') out.pop_back();
    return out.empty() ? "0" : out;
}

std::string formatVst2Version(int32_t v) {
    if (v <= 0) return {};
    if (v < 1000) return std::to_string(v);
    const int major = v / 1000;
    const int minor = (v % 1000) / 100;
    const int patch = (v % 100) / 10;
    const int build = v % 10;
    char buf[64] = {};
    std::snprintf(buf, sizeof(buf), "%d.%d.%d.%d", major, minor, patch, build);
    return trimTrailingZeros(buf);
}

const char* categoryName(int32_t category) {
    switch (category) {
        case VST_EFFECT_CATEGORY_EFFECT: return "AudioEffect";
        case VST_EFFECT_CATEGORY_INSTRUMENT: return "Instrument";
        case VST_EFFECT_CATEGORY_METERING: return "Analyzer";
        case VST_EFFECT_CATEGORY_MASTERING: return "Mastering";
        case VST_EFFECT_CATEGORY_SPATIAL: return "Spatial";
        case VST_EFFECT_CATEGORY_DELAY_OR_ECHO: return "Delay";
        default: return "AudioEffect";
    }
}

intptr_t VST_FUNCTION_INTERFACE descriptorCallback(vst_effect_t* effect, int32_t opcode,
                                                   int32_t index, intptr_t value, void* ptr,
                                                   float opt) {
    (void)effect;
    (void)index;
    (void)opt;
    switch (opcode) {
        case VST_HOST_OPCODE_VST_VERSION:
            return 2400;   // VST 2.4
        case VST_HOST_OPCODE_GET_SAMPLE_RATE:
            return 44100;
        case VST_HOST_OPCODE_GET_BLOCK_SIZE:
            return 1024;
        case VST_HOST_OPCODE_GET_ACTIVE_THREAD:
            return VST_HOST_ACTIVE_THREAD_INTERFACE;
        case VST_HOST_OPCODE_VENDOR_NAME:
            copyHostString(ptr, value, "AuraDSP");
            return VST_STATUS_TRUE;
        case VST_HOST_OPCODE_PRODUCT_NAME:
            copyHostString(ptr, value, "AuraDSP");
            return VST_STATUS_TRUE;
        case VST_HOST_OPCODE_VENDOR_VERSION:
            return 5000;
        case VST_HOST_OPCODE_LANGUAGE:
            return 1;   // English
        case VST_HOST_OPCODE_GET_EFFECT_DIRECTORY:
            copyHostString(ptr, value, g_descriptorDirectory.c_str());
            return VST_STATUS_TRUE;
        case VST_HOST_OPCODE_SUPPORTS:
            // 扫描期不承诺任何可选能力；插件通常只问版本/采样率。
            return VST_STATUS_FALSE;
        default:
            return 0;
    }
}

struct TempModule {
    void* module = nullptr;
    ~TempModule() {
        if (module) platform::module_close(module);
    }
};

bool readEffectString(vst_effect_t* effect, int32_t opcode, std::string& out) {
    char buf[512] = {};
    const intptr_t ok = effect->control(effect, opcode, 0, 0, buf, 0.0f);
    if (ok == 0 && buf[0] == '\0') return false;
    out.assign(buf);
    return !out.empty();
}

} // namespace

bool queryVst2Metadata(const std::string& bundlePath, const std::string& binaryPath,
                       std::vector<PluginMetadata>& out) {
    if (binaryPath.empty()) return false;

    const std::wstring wpath = utf8ToWide(binaryPath);
    if (!peHasVst2Entry(wpath)) return false;

    setupPluginDllDirectories(bundlePath);

    TempModule module;
    module.module = platform::module_open_utf8(binaryPath.c_str());
    if (!module.module) {
        releasePluginDllDirectories(bundlePath);
        return false;
    }

    auto mainProc = reinterpret_cast<VstPluginMainProc>(
        platform::module_symbol(module.module, "VSTPluginMain"));
    if (!mainProc) {
        mainProc = reinterpret_cast<VstPluginMainProc>(
            platform::module_symbol(module.module, "main"));
    }
    if (!mainProc) {
        releasePluginDllDirectories(bundlePath);
        return false;
    }

    const fs::path p(binaryPath);
    g_descriptorDirectory = p.parent_path().string();

    vst_effect_t* effect = nullptr;
    try {
        effect = mainProc(reinterpret_cast<vst_host_callback_t>(&descriptorCallback));
    } catch (...) {
        effect = nullptr;
    }
    if (!effect || effect->magic_number != static_cast<int32_t>(VST_MAGICNUMBER) ||
        !effect->control) {
        releasePluginDllDirectories(bundlePath);
        return false;
    }

    // 宿主保留字段：元数据查询不建实例，但保持规范约定（插件不得读写）。
    effect->_unknown_00 = nullptr;

    auto ctl = [effect](int32_t op, int32_t idx, intptr_t val, void* ptr, float opt) {
        return effect->control(effect, op, idx, val, ptr, opt);
    };

    // 标准生命周期：open → sample rate → block size。查询完 close。
    ctl(VST_EFFECT_OPCODE_CREATE, 0, 0, nullptr, 0.0f);
    ctl(VST_EFFECT_OPCODE_SET_SAMPLE_RATE, 0, 0, nullptr, 44100.0f);
    ctl(VST_EFFECT_OPCODE_SET_BLOCK_SIZE, 0, 1024, nullptr, 0.0f);

    PluginMetadata meta;
    meta.path = bundlePath;
    meta.format = PluginFormat::VST2;
    meta.bundleName = fs::path(bundlePath).stem().string();
    meta.is64Bit = pluginBinaryBitness(wpath) != 32;
    meta.isCompatible = true;
    meta.hasEditor = (effect->flags & VST_EFFECT_FLAG_EDITOR) != 0;

    std::string name;
    std::string vendor;
    std::string product;
    if (readEffectString(effect, VST_EFFECT_OPCODE_NAME, name) ||
        readEffectString(effect, VST_EFFECT_OPCODE_PRODUCT_NAME, product)) {
        meta.name = !name.empty() ? name : product;
    }
    if (meta.name.empty()) meta.name = meta.bundleName;

    if (readEffectString(effect, VST_EFFECT_OPCODE_VENDOR_NAME, vendor)) {
        meta.vendor = vendor;
    }
    if (meta.vendor.empty()) meta.vendor = "Unknown";

    const int32_t version = static_cast<int32_t>(
        ctl(VST_EFFECT_OPCODE_VENDOR_VERSION, 0, 0, nullptr, 0.0f));
    meta.version = formatVst2Version(version);
    if (meta.version.empty()) meta.version = "1.0";

    const int32_t category = static_cast<int32_t>(
        ctl(VST_EFFECT_OPCODE_CATEGORY, 0, 0, nullptr, 0.0f));
    meta.category = categoryName(category);

    meta.id = [&] {
        char buf[16] = {};
        std::snprintf(buf, sizeof(buf), "%08X", static_cast<unsigned>(effect->unique_id));
        return std::string(buf);
    }();

    meta.latency = effect->delay > 0 ? static_cast<uint32_t>(effect->delay) : 0u;
    meta.description = product;

    PluginBusInfo bus;
    bus.inputBuses = effect->num_inputs > 0 ? 1 : 0;
    bus.outputBuses = effect->num_outputs > 0 ? 1 : 0;
    bus.mainInChannels = effect->num_inputs > 0 ? effect->num_inputs : 0;
    bus.mainOutChannels = effect->num_outputs > 0 ? effect->num_outputs : 0;

    out.push_back(std::move(meta));

    // effClose 后 AEffect 可能已被插件释放，不能再触碰。
    ctl(VST_EFFECT_OPCODE_DESTROY, 0, 0, nullptr, 0.0f);
    releasePluginDllDirectories(bundlePath);
    return true;
}

} // namespace auradsp
