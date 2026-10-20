#include "clap_metadata.h"

#include "plugin_metadata_util.h"
#include "win32_util.h"

#include <clap/clap.h>
#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace auradsp {
namespace {

// 规范正典：source/clap/include/clap/plugin-features.h（CLAP v1.2.10）。
// category 级 feature —— 决定插件"是什么"。
const char* const kClapCategoryFeatures[] = {
    "instrument", "audio-effect", "note-effect", "note-detector", "analyzer"};

// sub-category 级 feature —— 决定插件"更具体是什么"，命中后追加为 "|xxx"。
const char* const kClapSubCategoryFeatures[] = {
    "synthesizer", "sampler", "drum", "drum-machine", "filter", "phaser",
    "equalizer", "de-esser", "phase-vocoder", "granular", "frequency-shifter",
    "pitch-shifter", "distortion", "transient-shaper", "compressor", "expander",
    "gate", "limiter", "flanger", "chorus", "delay", "reverb", "tremolo", "glitch",
    "utility", "pitch-correction", "restoration", "multi-effects", "mixing",
    "mastering"};

bool isOneOf(const std::string& s, const char* const* list, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        if (s == list[i]) return true;
    }
    return false;
}

/// 从 CLAP descriptor->features 推出分类串。
/// 例：['audio-effect']                -> "audio-effect"
///     ['audio-effect','reverb']       -> "audio-effect|reverb"
///     ['reverb']（只有子分类）         -> "reverb"
/// 无任何分类级 feature 时返回空，由调用方兜底。
std::string clapCategoryFromFeatures(const char* const* features) {
    if (!features) return "";
    std::vector<std::string> feats;
    for (size_t i = 0; features[i] != nullptr; ++i) {
        if (features[i][0] != '\0') feats.emplace_back(features[i]);
    }
    std::string cat;
    std::string sub;
    for (const auto& f : feats) {
        if (cat.empty() && isOneOf(f, kClapCategoryFeatures,
                                   sizeof(kClapCategoryFeatures) / sizeof(char*))) {
            cat = f;
        } else if (sub.empty() && isOneOf(f, kClapSubCategoryFeatures,
                                          sizeof(kClapSubCategoryFeatures) / sizeof(char*))) {
            sub = f;
        }
    }
    if (cat.empty()) cat = sub;          // 没有分类级就退到子分类级
    else if (!sub.empty()) cat += "|" + sub;
    return cat;
}

} // namespace

void applyClapDescriptor(PluginMetadata& meta,
                         const clap_plugin_descriptor* d,
                         const std::wstring& binaryPath,
                         const std::string& bundlePath) {
    if (!d) return;
    meta.format = PluginFormat::CLAP;

    fillMetadataIfEmpty(meta.id, (d->id && d->id[0]) ? d->id : "");
    fillMetadataIfEmpty(meta.name, (d->name && d->name[0]) ? d->name : "");
    fillMetadataIfEmpty(meta.description, (d->description && d->description[0]) ? d->description : "");
    // bundle 名单独存：KV-Element-FX.clap 的自报名是 "Element FX"，
    // 但用户选的是文件名 KV-Element-FX —— 两者都必须可取得，不可互相顶替。
    fillMetadataIfEmpty(meta.bundleName, fs::path(bundlePath).stem().string());

    // category 只能来自 features。
    // descriptor->description 是自由文本：实测 KV-Element-FX 的 description 就是
    // "KV-Element-FX"（bundle 名），拿它当 category 会得出假分类。
    std::string cat = clapCategoryFromFeatures(d->features);
    if (cat.empty()) cat = "AudioEffect";
    fillMetadataIfEmpty(meta.category, cat);

    fillMetadataIfEmpty(meta.version, (d->version && d->version[0]) ? d->version : "");

    // 厂商兜底链：descriptor -> PE 公司名 -> LegalCopyright -> 上级目录
    std::string vendor = (d->vendor && d->vendor[0]) ? d->vendor : "";
    if (vendor.empty()) {
        vendor = extractCompanyFromVersionInfo(binaryPath);
        if (vendor.empty()) vendor = extractVendorFromLegalCopyright(binaryPath);
        if (vendor.empty()) vendor = extractVendorFromPath(bundlePath);
    }
    fillMetadataIfEmpty(meta.vendor, vendor);

    // 版本兜底：descriptor -> PE 产品版本
    if (meta.version.empty() || meta.version == "1.0") {
        std::string peVer = extractProductVersionFromVersionInfo(binaryPath);
        if (!peVer.empty()) meta.version = peVer;
    }
    if (meta.version.empty()) meta.version = "1.0";
    if (meta.vendor.empty()) meta.vendor = "Unknown";
}

bool queryClapMetadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& outPlugins) {
    std::wstring wpath = utf8ToWide(binaryPath);
    HMODULE module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module) return false;

    bool success = false;
    try {
        auto entry = reinterpret_cast<const clap_plugin_entry_t*>(GetProcAddress(module, "clap_entry"));
        if (entry && entry->init && entry->init(bundlePath.c_str())) {
            auto factory = reinterpret_cast<const clap_plugin_factory_t*>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
            if (factory && factory->get_plugin_count) {
                uint32_t count = factory->get_plugin_count(factory);
                for (uint32_t i = 0; i < count; ++i) {
                    const clap_plugin_descriptor_t* d = factory->get_plugin_descriptor(factory, i);
                    if (!d) continue;
                    PluginMetadata meta;
                    meta.path = bundlePath;
                    meta.is64Bit = true;
                    meta.isCompatible = true;
                    applyClapDescriptor(meta, d, wpath, bundlePath);
                    outPlugins.push_back(meta);
                    success = true;
                }
            }
            if (entry->deinit) entry->deinit();
        }
    } catch (...) {
        success = false;
    }
    FreeLibrary(module);
    return success;
}

} // namespace auradsp
