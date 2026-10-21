#include "vst3_metadata.h"

#include "plugin_metadata_util.h"
#include "win32_util.h"

#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IPluginFactory.h>
#include <steinberg/vst3/base/IPluginFactory2.h>
#include <steinberg/vst3/base/IPluginFactory3.h>
#include <steinberg/vst3/vst/IAudioProcessor.h>

#include <windows.h>

#include <cstring>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace auradsp {
namespace {

std::string cidToHexString(const Steinberg::TUID tuid) {
    std::ostringstream ss;
    for (int i = 0; i < 16; ++i) {
        ss << std::hex << std::setw(2) << std::setfill('0') << (static_cast<int>(static_cast<uint8_t>(tuid[i])));
    }
    return ss.str();
}

} // namespace

/// 用 VST3 工厂信息填充 meta。扫描路与加载路共用同一实现。
/// index 处的 class 若不是音频效果类则返回 false，且不修改 meta。
/// seeded=false（扫描路）：保持历史优先级 —— factory3 先写、factory2 后覆盖，
///   空值与占位（"Unknown"/"1.0"）允许被后续来源补写。
/// seeded=true（加载路）：扫描种子已给的描述性字段一律是最终值（仅补空），
///   从而「扫描值 == 加载值」逐字段成立；id 是身份键，两种模式都权威重写。
bool applyVstAudioEffectClass(PluginMetadata& meta,
                              Steinberg::IPluginFactory* factory,
                              Steinberg::IPluginFactory2* factory2,
                              Steinberg::IPluginFactory3* factory3,
                              Steinberg::int32 index,
                              const std::wstring& binaryPath,
                              const std::string& bundlePath,
                              bool seeded,
                              Steinberg::TUID* outTuid) {
    if (!factory) return false;
    Steinberg::PClassInfo classInfo;
    if (factory->getClassInfo(index, &classInfo) != Steinberg::kResultOk) return false;
    if (std::strcmp(classInfo.category, kVstAudioEffectClass) != 0) return false;

    meta.format = PluginFormat::VST3;
    // id 是实例化身份键：快扫拿不到 CID（为空），加载路必须权威解析，
    // 深扫种子里的 id 又与目标 class 相同，重写不会造成扫描/加载分歧。
    meta.id = cidToHexString(classInfo.cid);
    // 描述性字段：seeded 时"已有非空值不覆盖"，否则历史的后写覆盖。
    auto put = [seeded](std::string& dst, const std::string& src) {
        if (src.empty()) return;
        if (seeded) fillMetadataIfEmpty(dst, src);
        else dst = src;
    };
    // 占位放行条件：扫描路允许 "Unknown"/"1.0" 被更真来源替换；
    // 加载路不放行 —— 扫描期给出占位也是扫描期的答案。
    auto wantVendor = [seeded](const std::string& v) {
        return v.empty() || (!seeded && v == "Unknown");
    };
    auto wantVersion = [seeded](const std::string& v) {
        return v.empty() || (!seeded && v == "1.0");
    };

    put(meta.name, classInfo.name);
    put(meta.category, classInfo.category);
    fillMetadataIfEmpty(meta.bundleName, fs::path(bundlePath).stem().string());

    // 工厂级厂商
    std::string factoryVendor;
    Steinberg::PFactoryInfo factoryInfo;
    if (factory->getFactoryInfo(&factoryInfo) == Steinberg::kResultOk &&
        factoryInfo.vendor[0] != '\0') {
        factoryVendor = factoryInfo.vendor;
    }

    // IPluginFactory3：Unicode 类信息，先写（优先级最高的描述符来源）
    if (factory3) {
        Steinberg::PClassInfoW classInfoW;
        if (factory3->getClassInfoUnicode(index, &classInfoW) == Steinberg::kResultOk) {
            if (classInfoW.name[0] != 0) {
                std::string u = wideToUtf8(Steinberg::wscast(classInfoW.name));
                put(meta.name, u);
            }
            if (classInfoW.vendor[0] != 0) {
                std::string u = wideToUtf8(Steinberg::wscast(classInfoW.vendor));
                put(meta.vendor, u);
            }
            if (classInfoW.version[0] != 0) {
                std::string u = wideToUtf8(Steinberg::wscast(classInfoW.version));
                put(meta.version, u);
            }
            if (classInfoW.subCategories[0] != 0) {
                // subCategories 是 char8（ASCII），直接赋值；只有 name/vendor/version
                // 才是 char16，需要 wideToUtf8 转换。
                put(meta.category, classInfoW.subCategories);
            }
        }
    }

    // IPluginFactory2：ASCII 补充（保持历史扫描路的优先级：后写覆盖前写）
    if (factory2) {
        Steinberg::PClassInfo2 classInfo2;
        if (factory2->getClassInfo2(index, &classInfo2) == Steinberg::kResultOk) {
            if (wantVendor(meta.vendor)) {
                if (classInfo2.vendor[0]) meta.vendor = classInfo2.vendor;
            }
            if (wantVersion(meta.version)) {
                if (classInfo2.version[0]) meta.version = classInfo2.version;
            }
            put(meta.category, classInfo2.subCategories);
        }
    }

    // 多级兜底厂商：factory -> PE -> 上级目录 -> 知名签名
    if (wantVendor(meta.vendor)) {
        if (!factoryVendor.empty()) meta.vendor = factoryVendor;
        else {
            std::string peV = extractCompanyFromVersionInfo(binaryPath);
            if (!peV.empty()) meta.vendor = peV;
            else {
                std::string dirV = extractVendorFromPath(bundlePath);
                if (!dirV.empty()) meta.vendor = dirV;
            }
        }
    }
    // 多级兜底版本
    if (wantVersion(meta.version)) {
        std::string peVer = extractProductVersionFromVersionInfo(binaryPath);
        if (!peVer.empty()) meta.version = peVer;
    }

    // 与 CLAP / fill32BitIncompatible 对称的末端兜底：
    // 工厂、PE 版本资源、目录、签名全链都拿不到厂商/版本时，必须落到
    // "Unknown"/"1.0" 占位而非空串。
    if (meta.vendor.empty()) meta.vendor = "Unknown";
    if (meta.version.empty()) meta.version = "1.0";

    if (outTuid) std::memcpy(outTuid, classInfo.cid, sizeof(Steinberg::TUID));
    return true;
}

bool queryVst3Metadata(const std::string& bundlePath,
                       const std::string& binaryPath,
                       std::vector<PluginMetadata>& outPlugins) {
    std::wstring wpath = utf8ToWide(binaryPath);
    HMODULE module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module) return false;

    bool success = false;
    try {
        typedef Steinberg::IPluginFactory* (PLUGIN_API *GetFactoryFunc)();
        auto getFactory = reinterpret_cast<GetFactoryFunc>(GetProcAddress(module, "GetPluginFactory"));
        if (getFactory) {
            Steinberg::IPluginFactory* factory = getFactory();
            if (factory) {
                Steinberg::IPluginFactory2* factory2 = nullptr;
                Steinberg::IPluginFactory3* factory3 = nullptr;
                factory->queryInterface(Steinberg::IPluginFactory2::iid, reinterpret_cast<void**>(&factory2));
                factory->queryInterface(Steinberg::IPluginFactory3::iid, reinterpret_cast<void**>(&factory3));

                Steinberg::int32 classCount = factory->countClasses();
                for (Steinberg::int32 i = 0; i < classCount; ++i) {
                    PluginMetadata meta;
                    meta.path = bundlePath;
                    meta.is64Bit = true;
                    meta.isCompatible = true;
                    if (applyVstAudioEffectClass(meta, factory, factory2, factory3, i, wpath, bundlePath)) {
                        outPlugins.push_back(meta);
                        success = true;
                    }
                }

                if (factory3) factory3->release();
                if (factory2) factory2->release();
            }
        }
    } catch (...) {
        success = false;
    }
    FreeLibrary(module);
    return success;
}

} // namespace auradsp
