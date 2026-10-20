#include "plugin_host.h"

#include <windows.h>
#include <winver.h>
#pragma comment(lib, "version.lib")
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <algorithm>
#include <cstring>
#include <thread>
#include <future>
#include <functional>
#include <deque>
#include <map>
#include <set>
#include <unordered_set>
#include <array>

// CLAP headers
#include <clap/clap.h>

// Steinberg VST3 headers
// VST3 接口声明（定义见 formats/plugin_instances.cpp 的静态锚点）
#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IPluginFactory.h>
#include <steinberg/vst3/base/IPluginFactory2.h>
#include <steinberg/vst3/base/IPluginFactory3.h>
#include <steinberg/vst3/vst/IAudioProcessor.h>

#include "plugin_host_util.h"

namespace fs = std::filesystem;

namespace auradsp {
std::string escapeJsonString(const std::string& input) {
    std::ostringstream ss;
    for (char c : input) {
        switch (c) {
            case '"':  ss << "\\\""; break;
            case '\\': ss << "\\\\"; break;
            case '\b': ss << "\\b";  break;
            case '\f': ss << "\\f";  break;
            case '\n': ss << "\\n";  break;
            case '\r': ss << "\\r";  break;
            case '\t': ss << "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < ' ') {
                    ss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                } else {
                    ss << c;
                }
        }
    }
    return ss.str();
}

std::string cidToHexString(const Steinberg::TUID tuid) {
    std::ostringstream ss;
    for (int i = 0; i < 16; ++i) {
        ss << std::hex << std::setw(2) << std::setfill('0') << (static_cast<int>(static_cast<uint8_t>(tuid[i])));
    }
    return ss.str();
}

bool hexStringToCid(const std::string& hex, Steinberg::TUID tuid) {
    if (hex.length() != 32) return false;
    for (size_t i = 0; i < 16; ++i) {
        std::string byteStr = hex.substr(i * 2, 2);
        char* end = nullptr;
        tuid[i] = static_cast<char>(std::strtoul(byteStr.c_str(), &end, 16));
    }
    return true;
}

void setupPluginDllDirectories(const std::string& pluginPath) {
    try {
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_USER_DIRS);
        fs::path p(pluginPath);
        fs::path dir = fs::is_directory(p) ? p : p.parent_path();
        AddDllDirectory(dir.wstring().c_str());

        std::string pLow = pluginPath;
        std::transform(pLow.begin(), pLow.end(), pLow.begin(), ::tolower);
        if (pLow.find("izotope") != std::string::npos || pLow.find("ozone") != std::string::npos) {
            const wchar_t* izDirs[] = {
                L"C:\\Program Files\\iZotope\\Ozone 12\\Cores",
                L"C:\\Program Files\\iZotope\\Ozone 12\\win64",
                L"C:\\Program Files\\iZotope\\Ozone 12",
                L"C:\\Program Files\\iZotope\\Ozone 12 Equalizer\\Crash Reporter",
                L"C:\\Program Files\\iZotope\\RX 12 Audio Editor\\Cores",
                L"C:\\Program Files\\iZotope\\RX 12 Audio Editor\\win64"
            };
            for (const auto* d : izDirs) {
                if (fs::exists(d)) {
                    AddDllDirectory(d);
                }
            }
        }
    } catch (...) {}
}

/// 扩展名大小写不敏感比较（lowerExt 必须已是小写）。
/// Windows 文件系统不区分大小写：bundle 内二进制叫 foo.VST3 与 foo.vst3
/// 必须等价。严格比较曾让大写扩展名的整包在扫描中静默消失（违反 D 类契约），
/// scan() 入口已做 ::tolower 归一化，这里补上内层探测的同款归一化。
static bool extensionEqualsCI(const fs::path& p, const char* lowerExt) {
    std::string ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return ext == lowerExt;
}

std::string extractVendorFromPath(const std::string& filePath) {
    try {
        fs::path p(filePath);
        while (p.has_filename() && (extensionEqualsCI(p, ".vst3") || extensionEqualsCI(p, ".clap") ||
               p.filename() == "Contents" || p.filename() == "x86_64-win" ||
               p.filename() == "x86-win" || p.filename() == "Resources")) {
            p = p.parent_path();
        }

        while (p.has_filename()) {
            std::string folderName = p.filename().string();
            std::string lowerName = folderName;
            std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(), ::tolower);

            if (lowerName != "vst3" && lowerName != "clap" && lowerName != "common files" &&
                lowerName != "plugins" && lowerName != "vstplugins" && lowerName != "program files" &&
                lowerName != "program files (x86)" && lowerName != "steinberg" && !lowerName.empty() &&
                folderName.back() != ':') {
                return folderName;
            }
            p = p.parent_path();
        }
    } catch (...) {
    }
    return "";
}

/// 读取 PE 头的 IMAGE_FILE_MACHINE。无法解析（非 PE / 读失败）返回 0。
/// 0x014c = IMAGE_FILE_MACHINE_I386（32 位）
/// 0x8664 = IMAGE_FILE_MACHINE_AMD64（64 位）
/// 0xaa64 = IMAGE_FILE_MACHINE_ARM64（64 位）
static WORD peMachineType(const std::wstring& binaryPath) {
    std::ifstream f(binaryPath, std::ios::binary);
    if (!f) return 0;
    IMAGE_DOS_HEADER dos{};
    f.read(reinterpret_cast<char*>(&dos), sizeof(dos));
    if (!f || dos.e_magic != IMAGE_DOS_SIGNATURE) return 0;
    if (dos.e_lfanew <= 0) return 0;
    f.seekg(static_cast<std::streamoff>(dos.e_lfanew));
    DWORD signature = 0;
    f.read(reinterpret_cast<char*>(&signature), sizeof(signature));
    if (!f || signature != IMAGE_NT_SIGNATURE) return 0;
    WORD machine = 0;
    f.read(reinterpret_cast<char*>(&machine), sizeof(machine));
    if (!f) return 0;
    return machine;
}

/// 由 PE 头判定是否为 64 位二进制。解析失败时按 64 位处理
/// （本进程是 x64；历史行为即默认 true，缺失 PE 信息不应把插件误判为不兼容）。
bool peIs64Bit(const std::wstring& binaryPath) {
    const WORD m = peMachineType(binaryPath);
    if (m == IMAGE_FILE_MACHINE_I386) return false;
    if (m == IMAGE_FILE_MACHINE_AMD64 || m == IMAGE_FILE_MACHINE_ARM64) return true;
    return true;
}

std::string extractCompanyFromVersionInfo(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        struct LANGANDCODEPAGE {
            WORD wLanguage;
            WORD wCodePage;
        } *lpTranslate = nullptr;
        UINT cbTranslate = 0;
        if (VerQueryValueW(buffer.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<LPVOID*>(&lpTranslate), &cbTranslate) &&
            cbTranslate >= sizeof(LANGANDCODEPAGE) && lpTranslate != nullptr) {
            for (unsigned int i = 0; i < (cbTranslate / sizeof(LANGANDCODEPAGE)); i++) {
                wchar_t subBlock[64];
                swprintf_s(subBlock, L"\\StringFileInfo\\%04x%04x\\CompanyName", lpTranslate[i].wLanguage, lpTranslate[i].wCodePage);
                LPWSTR companyName = nullptr;
                UINT companyLen = 0;
                if (VerQueryValueW(buffer.data(), subBlock, reinterpret_cast<LPVOID*>(&companyName), &companyLen) &&
                    companyLen > 0 && companyName && companyName[0] != L'\0') {
                    std::string comp = wideToUtf8(companyName);
                    if (!comp.empty()) return comp;
                }
            }
        }

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\CompanyName",
            L"\\StringFileInfo\\040904E4\\CompanyName",
            L"\\StringFileInfo\\000004b0\\CompanyName",
            L"\\StringFileInfo\\04090000\\CompanyName"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR companyName = nullptr;
            UINT companyLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&companyName), &companyLen) &&
                companyLen > 0 && companyName && companyName[0] != L'\0') {
                std::string comp = wideToUtf8(companyName);
                if (!comp.empty()) return comp;
            }
        }
    } catch (...) {
    }
    return "";
}

std::string extractProductVersionFromVersionInfo(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\ProductVersion",
            L"\\StringFileInfo\\040904E4\\ProductVersion",
            L"\\StringFileInfo\\000004b0\\ProductVersion",
            L"\\StringFileInfo\\040904b0\\FileVersion"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR ver = nullptr;
            UINT verLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&ver), &verLen) &&
                verLen > 0 && ver && ver[0] != L'\0') {
                std::string v = wideToUtf8(ver);
                if (!v.empty()) return v;
            }
        }
    } catch (...) {
    }
    return "";
}

std::string extractVendorFromLegalCopyright(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\LegalCopyright",
            L"\\StringFileInfo\\040904E4\\LegalCopyright",
            L"\\StringFileInfo\\000004b0\\LegalCopyright",
            L"\\StringFileInfo\\04090000\\LegalCopyright"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR copyText = nullptr;
            UINT copyLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&copyText), &copyLen) &&
                copyLen > 0 && copyText && copyText[0] != L'\0') {
                std::string comp = wideToUtf8(copyText);
                if (!comp.empty()) {
                    std::string clean = comp;
                    const char* prefixes[] = {"Copyright (C) ", "Copyright (c) ", "Copyright ", "\xc2\xa9 "};
                    for (const char* pfx : prefixes) {
                        size_t pos = clean.find(pfx);
                        if (pos != std::string::npos) {
                            clean = clean.substr(pos + std::strlen(pfx));
                            break;
                        }
                    }
                    while (clean.size() >= 5 && isdigit((unsigned char)clean[0]) && isdigit((unsigned char)clean[1]) &&
                           isdigit((unsigned char)clean[2]) && isdigit((unsigned char)clean[3]) && (clean[4] == ' ' || clean[4] == '-')) {
                        clean = clean.substr(5);
                    }
                    if (!clean.empty()) return clean;
                    return comp;
                }
            }
        }
    } catch (...) {}
    return "";
}

//------------------------------------------------------------------------------
// 元数据单一真相源
//
// 历史包袱：扫描路（PluginScanner::queryMetadata）与加载路
// （ClapPluginInstance::load / Vst3PluginInstance::load）各自实现了一遍字段提取，
// 且优先级不同，于是同一插件两条路给出互相矛盾的结论。实测：
//   FabFilter Pro-Q 3  扫描 vendor='FabFilter'  加载后 vendor=''
//   KV-Element-FX      扫描 name='Element FX' category='KV-Element-FX'
//                      加载后 name='Element FX' category='Fx'
// 用户看到的"厂商读不出来 / 名字对不上 / 分类是假的"全部源于此。
//
// 规则：
//   1. 一条填充实现，扫描路与加载路共用；
//   2. 静态描述符优先（CLAP descriptor / VST3 classInfo），实例化查询仅补空；
//   3. 已有非空值一律不覆盖（fillIfEmpty）；
//   4. category 只允许来自「分类级」来源，绝不用自由文本顶替。
//------------------------------------------------------------------------------
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

/// 仅当目标为空时写入 —— "已有非空值不覆盖"的唯一执行点。
void fillIfEmpty(std::string& dst, const std::string& src) {
    if (dst.empty() && !src.empty()) dst = src;
}

/// 以扫描期元数据为基准初始化加载路 meta：只搬描述性字段，
/// 运行期字段（latency / isCompatible / errorMessage）一律重置。
/// 之后再调 applyClapDescriptor / applyVstAudioEffectClass 补空，
/// 于是「扫描值 == 加载值」对扫描期已有的字段恒成立。

/// 32 位插件的"可发现但不可加载"条目（D2）。
/// 不 LoadLibrary —— x64 进程加载 32 位 DLL 必然 ERROR_BAD_EXE_FORMAT(193)，
/// 旧路把 193 当普通"加载失败"抛出，用户无法区分架构问题与文件损坏；
/// 这里仅用 PE 版本资源与路径推导描述性字段，产出留在扫描结果里的
/// 不兼容条目。errorMessage 文案与 load() 的 32 位拒绝保持一致。
void fill32BitIncompatible(PluginMetadata& meta, const std::string& filePath,
                           PluginFormat format, const std::wstring& wpath) {
    meta.path = filePath;
    meta.format = format;
    meta.name = fs::path(filePath).stem().string();
    // 与 makeQuickMeta / applyClapDescriptor 同一规则：bundleName = 路径 stem。
    meta.bundleName = meta.name;
    meta.is64Bit = false;
    meta.isCompatible = false;
    meta.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";

    // vendor 兜底链与 makeQuickMeta / applyClapDescriptor 完全一致：
    // PE CompanyName -> LegalCopyright -> 上级目录 -> "Unknown"。
    // 不再含硬编码厂商签名表（2026-10-19：厂商识别数据移往 UI 层 vendor_table）。
    std::string vendor = extractCompanyFromVersionInfo(wpath);
    if (vendor.empty()) vendor = extractVendorFromLegalCopyright(wpath);
    if (vendor.empty()) vendor = extractVendorFromPath(filePath);
    if (vendor.empty()) vendor = "Unknown";
    meta.vendor = vendor;

    std::string peVer = extractProductVersionFromVersionInfo(wpath);
    meta.version = !peVer.empty() ? peVer : "1.0";
    // 与 makeQuickMeta 快扫缺省一致；深扫才有 subCategories，32 位拿不到。
    meta.category = "AudioEffect";
}

/// 用 CLAP descriptor 填充 meta。扫描路与加载路共用同一实现。

/// 用 VST3 工厂信息填充 meta。扫描路与加载路共用同一实现。
/// index 处的 class 若不是音频效果类则返回 false，且不修改 meta。
/// seeded=false（扫描路）：保持历史优先级 —— factory3 先写、factory2 后覆盖，
///   空值与占位（"Unknown"/"1.0"）允许被后续来源补写。
/// seeded=true（加载路）：扫描种子已给的描述性字段一律是最终值（仅补空），
///   从而「扫描值 == 加载值」逐字段成立；id 是身份键，两种模式都权威重写。

}  // namespace

void seedMetadataFromScan(PluginMetadata& dst, const PluginMetadata& src) {
    dst.path = src.path;
    dst.id = src.id;
    dst.name = src.name;
    dst.bundleName = src.bundleName;
    dst.vendor = src.vendor;
    dst.version = src.version;
    dst.category = src.category;
    dst.description = src.description;
    dst.format = src.format;
    dst.is64Bit = src.is64Bit;
    dst.latency = 0;
    dst.isCompatible = true;
    dst.errorMessage.clear();
}

void applyClapDescriptor(PluginMetadata& meta,
                         const clap_plugin_descriptor_t* d,
                         const std::wstring& binaryPath,
                         const std::string& bundlePath) {
    if (!d) return;
    meta.format = PluginFormat::CLAP;

    fillIfEmpty(meta.id, (d->id && d->id[0]) ? d->id : "");
    fillIfEmpty(meta.name, (d->name && d->name[0]) ? d->name : "");
    fillIfEmpty(meta.description, (d->description && d->description[0]) ? d->description : "");
    // bundle 名单独存：KV-Element-FX.clap 的自报名是 "Element FX"，
    // 但用户选的是文件名 KV-Element-FX —— 两者都必须可取得，不可互相顶替。
    fillIfEmpty(meta.bundleName, fs::path(bundlePath).stem().string());

    // category 只能来自 features。
    // descriptor->description 是自由文本：实测 KV-Element-FX 的 description 就是
    // "KV-Element-FX"（bundle 名），拿它当 category 会得出假分类。
    std::string cat = clapCategoryFromFeatures(d->features);
    if (cat.empty()) cat = "AudioEffect";
    fillIfEmpty(meta.category, cat);

    fillIfEmpty(meta.version, (d->version && d->version[0]) ? d->version : "");

    // 厂商兜底链：descriptor -> PE 公司名 -> LegalCopyright -> 上级目录
    std::string vendor = (d->vendor && d->vendor[0]) ? d->vendor : "";
    if (vendor.empty()) {
        vendor = extractCompanyFromVersionInfo(binaryPath);
        if (vendor.empty()) vendor = extractVendorFromLegalCopyright(binaryPath);
        if (vendor.empty()) vendor = extractVendorFromPath(bundlePath);
    }
    fillIfEmpty(meta.vendor, vendor);

    // 版本兜底：descriptor -> PE 产品版本
    if (meta.version.empty() || meta.version == "1.0") {
        std::string peVer = extractProductVersionFromVersionInfo(binaryPath);
        if (!peVer.empty()) meta.version = peVer;
    }
    if (meta.version.empty()) meta.version = "1.0";
    if (meta.vendor.empty()) meta.vendor = "Unknown";
}

bool applyVstAudioEffectClass(PluginMetadata& meta,
                              Steinberg::IPluginFactory* factory,
                              Steinberg::IPluginFactory2* factory2,
                              Steinberg::IPluginFactory3* factory3,
                              Steinberg::int32 index,
                              const std::wstring& binaryPath,
                              const std::string& bundlePath,
                              bool seeded,
                              Steinberg::TUID* outTuid) {
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
        if (seeded) fillIfEmpty(dst, src);
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
    fillIfEmpty(meta.bundleName, fs::path(bundlePath).stem().string());

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

    // 与 applyClapDescriptor / fill32BitIncompatible 对称的末端兜底：
    // 工厂、PE 版本资源、目录、签名全链都拿不到厂商/版本时，必须落到
    // "Unknown"/"1.0" 占位而非空串 —— 空串会让快扫/深扫/加载三方产出
    // 与契约占位不一致的值（UI 侧另有一套 "未知" 展示，双轨易漂移）。
    if (meta.vendor.empty()) meta.vendor = "Unknown";
    if (meta.version.empty()) meta.version = "1.0";

    if (outTuid) std::memcpy(outTuid, classInfo.cid, sizeof(Steinberg::TUID));
    return true;
}

std::string PluginMetadata::toJson() const {
    std::ostringstream ss;
    ss << "{"
       << "\"path\":\"" << escapeJsonString(path) << "\","
       << "\"id\":\"" << escapeJsonString(id) << "\","
       << "\"name\":\"" << escapeJsonString(name) << "\","
       << "\"bundleName\":\"" << escapeJsonString(bundleName) << "\","
       << "\"vendor\":\"" << escapeJsonString(vendor) << "\","
       << "\"version\":\"" << escapeJsonString(version) << "\","
       << "\"category\":\"" << escapeJsonString(category) << "\","
       << "\"description\":\"" << escapeJsonString(description) << "\","
       << "\"format\":\"" << (format == PluginFormat::VST3 ? "VST3" : (format == PluginFormat::CLAP ? "CLAP" : "Unknown")) << "\","
       << "\"is64Bit\":" << (is64Bit ? "true" : "false") << ","
       << "\"latency\":" << latency << ","
       << "\"isCompatible\":" << (isCompatible ? "true" : "false") << ","
       << "\"errorMessage\":\"" << escapeJsonString(errorMessage) << "\""
       << "}";
    return ss.str();
}

std::string PluginScanner::resolveBundleBinary(const std::string& bundlePath, PluginFormat format,
                                               std::string* outArch) {
    std::error_code ec;
    if (outArch) outArch->clear();
    if (fs::is_directory(bundlePath, ec)) {
        // 探测顺序即偏好顺序：本进程架构（x86_64-win）优先，32 位（x86-win）
        // 作为"能发现但不能加载"的条目进入列表（isCompatible=false）。
        static const char* const kArchDirs[] = {"x86_64-win", "x86-win"};
        const char* const ext = (format == PluginFormat::VST3) ? ".vst3" : ".clap";
        for (const char* arch : kArchDirs) {
            fs::path subBinary = fs::path(bundlePath) / "Contents" / arch;
            if (!fs::exists(subBinary, ec)) continue;
            for (const auto& entry : fs::directory_iterator(subBinary, ec)) {
                // 大小写不敏感：内层二进制叫 Upper.VST3 时严格比较会漏掉整包，
                // 与 scan() 入口的 ::tolower 归一化保持一致。
                if (extensionEqualsCI(entry.path(), ext)) {
                    if (outArch) *outArch = arch;
                    return entry.path().string();
                }
            }
        }
        // It is a directory, but does not contain a supported plugin binary -> invalid
        return "";
    }
    return bundlePath;
}

bool PluginScanner::queryMetadata(const std::string& filePath, PluginFormat format, std::vector<PluginMetadata>& outPlugins) {
    std::string binaryPath = resolveBundleBinary(filePath, format);
    if (binaryPath.empty()) return false;
    std::wstring wpath = utf8ToWide(binaryPath);

    // D2：32 位插件不进入 LoadLibrary —— x64 进程加载 32 位 DLL 必然
    // ERROR_BAD_EXE_FORMAT(193)，旧实现把它当"打开失败"，扫描结果里直接
    // 消失。这里提前识别，产出"可发现但不可加载"条目（isCompatible=false）。
    if (!peIs64Bit(wpath)) {
        PluginMetadata meta;
        fill32BitIncompatible(meta, filePath, format, wpath);
        outPlugins.push_back(meta);
        return true;
    }

    if (format == PluginFormat::CLAP) {
        HMODULE module = LoadLibraryExW(wpath.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module) return false;

        bool success = false;
        try {
            auto entry = reinterpret_cast<const clap_plugin_entry_t*>(GetProcAddress(module, "clap_entry"));
            if (entry && entry->init && entry->init(filePath.c_str())) {
                auto factory = reinterpret_cast<const clap_plugin_factory_t*>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
                if (factory && factory->get_plugin_count) {
                    uint32_t count = factory->get_plugin_count(factory);
                    for (uint32_t i = 0; i < count; ++i) {
                        const clap_plugin_descriptor_t* d = factory->get_plugin_descriptor(factory, i);
                        if (!d) continue;
                        PluginMetadata meta;
                        meta.path = filePath;
                        meta.is64Bit = true;
                        meta.isCompatible = true;
                        applyClapDescriptor(meta, d, wpath, filePath);
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
    } else if (format == PluginFormat::VST3) {
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
                        meta.path = filePath;
                        meta.is64Bit = true;
                        meta.isCompatible = true;
                        if (applyVstAudioEffectClass(meta, factory, factory2, factory3, i, wpath, filePath)) {
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
    return false;
}

std::vector<PluginScanner::ScanCandidate> PluginScanner::enumerate(const std::vector<std::string>& searchPaths) {
    // C2：只遍历目录树，不做任何 PE 读取 / LoadLibrary。这一步在每个
    // 候选上只有 stat 级成本，可安全地在扫描启动时一次性完成。
    std::vector<ScanCandidate> out;
    std::unordered_set<std::string> seen;

    for (const auto& dirPath : searchPaths) {
        if (!fs::exists(dirPath)) continue;

        try {
            for (auto it = fs::recursive_directory_iterator(dirPath, fs::directory_options::skip_permission_denied);
                 it != fs::recursive_directory_iterator(); ++it) {
                if (it.depth() > 6) {
                    it.pop();
                    continue;
                }
                const auto& entry = *it;
                std::string ext = entry.path().extension().string();
                std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

                PluginFormat format = PluginFormat::Unknown;
                if (ext == ".vst3") format = PluginFormat::VST3;
                else if (ext == ".clap") format = PluginFormat::CLAP;

                if (format == PluginFormat::Unknown) continue;

                ScanCandidate c;
                c.format = format;
                if (entry.is_directory()) {
                    it.disable_recursion_pending();
                    c.binaryPath = resolveBundleBinary(entry.path().string(), format);
                    if (c.binaryPath.empty()) continue;   // 目录以 .vst3 结尾但不是有效 bundle
                    c.path = entry.path().string();
                    c.displayName = entry.path().stem().string();
                } else {
                    c.binaryPath = entry.path().string();



                    c.path = c.binaryPath;
                    c.displayName = entry.path().stem().string();
                }

                if (seen.insert(c.binaryPath).second) out.push_back(std::move(c));
            }
        } catch (...) {
            // Guard filesystem iteration exceptions
        }
    }
    return out;
}

namespace {

// 快扫元数据：PE 版本资源 + 路径/名称启发式（不加载 DLL）。
// 与深扫/加载路共用 bundleName 与 is64Bit 判定规则（D2）。
PluginMetadata makeQuickMeta(const std::string& pStr, const std::string& nStr, PluginFormat fmt) {
    std::wstring wp = utf8ToWide(pStr);
    std::string peV = extractCompanyFromVersionInfo(wp);
    std::string copyV = extractVendorFromLegalCopyright(wp);
    std::string peVer = extractProductVersionFromVersionInfo(wp);
    std::string dirV = extractVendorFromPath(pStr);

    std::string vendor = !peV.empty() ? peV : (!copyV.empty() ? copyV : (!dirV.empty() ? dirV : "Unknown"));

    PluginMetadata q;
    q.path = pStr;
    q.name = nStr;
    // 与深扫/加载路同一规则：bundleName = 注册路径的 stem。
    // 快扫不加载 DLL，拿不到自报名，但 bundle 名不依赖 DLL。
    q.bundleName = fs::path(pStr).stem().string();
    q.format = fmt;
    // D2：is64Bit 由 PE 头判定（不再硬编码 true）。32 位条目保留在扫描结果
    // 中但标记不可加载，加载路 loadPlugin() 会拦截并给出同一文案。
    q.is64Bit = peIs64Bit(wp);
    if (!q.is64Bit) {
        q.isCompatible = false;
        q.errorMessage = "32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本";
    }
    q.vendor = vendor;
    q.version = !peVer.empty() ? peVer : "1.0";
    q.category = "AudioEffect";
    return q;
}

// 单个候选的元数据提取（快扫/深扫共用）。CLAP 一律走轻量查询（不需要加载
// DLL 即可拿到 id/vendor）；VST3 深扫才 LoadLibrary 走 queryMetadata。
std::vector<PluginMetadata> scanCandidateMeta(const PluginScanner::ScanCandidate& c, bool deepScan) {
    std::vector<PluginMetadata> out;

    if (c.format == PluginFormat::CLAP) {
        std::vector<PluginMetadata> clapMetas;
        if (PluginScanner::queryMetadata(c.binaryPath, c.format, clapMetas) && !clapMetas.empty()) {
            return clapMetas;
        }
        // 轻量查询失败时退化为 PE 版本资源路径
        out.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
        return out;
    }

    if (deepScan) {
        std::vector<PluginMetadata> deepMeta;
        if (PluginScanner::queryMetadata(c.binaryPath, c.format, deepMeta) && !deepMeta.empty()) {
            return deepMeta;
        }
    }
    out.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
    return out;
}

}  // namespace

std::vector<PluginMetadata> PluginScanner::scan(const std::vector<std::string>& searchPaths, bool deepScan) {
    // 一次性扫描（保留原语义）：枚举 + 逐个取元数据。分块扫描走
    // PluginHostManager::scanBegin/scanStep，两边共用 enumerate 与同一套
    // 元数据提取实现，保证「一次性 == 分块」结果一致。
    std::vector<PluginMetadata> results;
    for (const auto& c : enumerate(searchPaths)) {
        for (auto& m : scanCandidateMeta(c, deepScan)) results.push_back(std::move(m));
    }
    return results;
}

//------------------------------------------------------------------------------
// PluginHostManager
//------------------------------------------------------------------------------
PluginHostManager::PluginHostManager() = default;

PluginHostManager::~PluginHostManager() {
    // 先停止控制线程（避免新任务进入）
    m_controlRunning.store(false, std::memory_order_release);
    m_controlCv.notify_all();
    if (m_controlThread.joinable()) m_controlThread.join();
    // 再同步卸载所有槽（控制线程已停，安全）
    for (size_t s = 0; s < kMaxPluginSlots; ++s) {
        unloadPluginSlot(s);
    }
}

int PluginHostManager::scanPlugins(const std::string& extraDirsJson, bool deepScan) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);

    // 一次性扫描直接走分块管线的同一条实现（begin → 排空 → end），于是：
    //   ① 结果与分块扫描逐条一致；② 同样命中元数据缓存；③ 结束同样刷新缓存。
    // 早期版本这里单独调 PluginScanner::scan，绕过了缓存，导致"一次性 46ms /
    // 分块 4ms"的观感差异——快慢并非实现不同，而是有没有命中缓存。
    scanBegin(extraDirsJson, deepScan);          // recursive_mutex，可重入
    while (scanStep(256) > 0) {
    }
    return scanEnd();
}

//------------------------------------------------------------------------------
// C2 分块扫描
//------------------------------------------------------------------------------
namespace {

// 文件指纹：大小 + 修改时间。仅用于缓存有效性判定，失败时返回 false
// （= 不可缓存、每次都重扫——安全退化）。
bool fileStamp(const std::string& path, std::pair<uint64_t, int64_t>& out) {
    std::error_code ec;
    auto sz = fs::file_size(path, ec);
    if (ec) return false;
    auto mtime = fs::last_write_time(path, ec);
    if (ec) return false;
    int64_t t = 0;
#if defined(_MSC_VER) && (!defined(_HAS_CXX20) || _HAS_CXX20 == 0)
    t = static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(mtime.time_since_epoch()).count());
#else
    t = static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(mtime.time_since_epoch()).count());
#endif
    out = {static_cast<uint64_t>(sz), t};
    return true;
}

}  // namespace

std::vector<std::string> PluginHostManager::collectSearchPathsLocked(const std::string& extraDirsJson) const {
    std::vector<std::string> searchPaths = PluginScanner::getDefaultSearchPaths();
    if (!extraDirsJson.empty()) {
        std::istringstream iss(extraDirsJson);
        std::string path;
        while (std::getline(iss, path, ';')) {
            if (!path.empty() && fs::exists(path)) searchPaths.push_back(path);
        }
    }
    return searchPaths;
}

int PluginHostManager::scanBegin(const std::string& extraDirsJson, bool deepScan) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);

    auto job = std::make_unique<ScanJob>();
    job->deep = deepScan;
    job->candidates = PluginScanner::enumerate(collectSearchPathsLocked(extraDirsJson));

    // 结果渐进写入 m_scannedPlugins：扫描过程中 get_all 即返回已扫到的部分
    // （UI 边扫边长），scanEnd 只负责收尾与刷新缓存。
    m_scannedPlugins.clear();
    m_scanJob = std::move(job);
    return static_cast<int>(m_scanJob->candidates.size());
}

int PluginHostManager::scanStep(int maxItems) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (!m_scanJob) return 0;
    if (maxItems <= 0) maxItems = 1;

    int processed = 0;
    auto& job = *m_scanJob;
    while (processed < maxItems && job.cursor < job.candidates.size()) {
        const auto& c = job.candidates[job.cursor++];
        ++processed;

        // 缓存复用：文件未变 + 缓存深度足够 → 直接复用，零 I/O（快扫）
        // 或零 LoadLibrary（深扫）。这是"再扫一次"接近瞬时的关键。
        std::pair<uint64_t, int64_t> stamp;
        if (fileStamp(c.binaryPath, stamp)) {
            auto itS = m_scanStamps.find(c.binaryPath);
            auto itC = m_scanCache.find(c.binaryPath);
            auto itD = m_scanCacheDeep.find(c.binaryPath);
            if (itS != m_scanStamps.end() && itC != m_scanCache.end() &&
                itS->second == stamp &&
                itD != m_scanCacheDeep.end() && (itD->second || !job.deep)) {
                // 复用该二进制下的**全部**条目（多插件 bundle 不会被折叠）。
                for (const auto& cached : itC->second) m_scannedPlugins.push_back(cached);
                continue;
            }
        }

        for (auto& m : scanCandidateMeta(c, job.deep)) {
            m_scannedPlugins.push_back(std::move(m));
        }
    }
    return processed;
}

int PluginHostManager::scanProcessed() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (!m_scanJob) return -1;
    return static_cast<int>(m_scanJob->cursor);
}

int PluginHostManager::scanTotal() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (!m_scanJob) return -1;
    return static_cast<int>(m_scanJob->candidates.size());
}

int PluginHostManager::scanEnd() {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (!m_scanJob) return static_cast<int>(m_scannedPlugins.size());
    const bool deep = m_scanJob->deep;
    m_scanJob.reset();
    rebuildScanCacheFromResults(deep);
    return static_cast<int>(m_scannedPlugins.size());
}

void PluginHostManager::scanAbort() {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    m_scanJob.reset();   // 已扫到的部分保留在 m_scannedPlugins 中
}

void PluginHostManager::rebuildScanCacheFromResults(bool deep) {
    // 由当前结果重建缓存与文件指纹。仅缓存"成功且有效"的条目（有 id 或
    // 至少 name 非空），避免把一次失败的中间态固化进缓存。
    m_scanCache.clear();
    m_scanStamps.clear();
    m_scanCacheDeep.clear();
    for (const auto& m : m_scannedPlugins) {
        if (m.path.empty()) continue;
        std::pair<uint64_t, int64_t> stamp;
        if (!fileStamp(m.path, stamp)) continue;
        m_scanStamps[m.path] = stamp;
        m_scanCache[m.path].push_back(m);   // 追加而非覆盖：保留多插件 bundle 的全部条目
        m_scanCacheDeep[m.path] = deep;
    }
}

size_t PluginHostManager::getScannedCount() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    return m_scannedPlugins.size();
}

std::string PluginHostManager::getScannedItemJson(size_t index) const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (index >= m_scannedPlugins.size()) return "{}";
    return m_scannedPlugins[index].toJson();
}

std::string PluginHostManager::getAllScannedJson() const {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    std::ostringstream ss;
    ss << "[";
    for (size_t i = 0; i < m_scannedPlugins.size(); ++i) {
        if (i > 0) ss << ",";
        ss << m_scannedPlugins[i].toJson();
    }
    ss << "]";
    return ss.str();
}

// 隔离区（放弃释放）：abandoned 实例统一收容于此。
// 关键约束——容器本身必须永不析构。挂死线程仍引用实例内部（this、编辑器
// 窗口、COM 对象），任何时刻的释放都危险；静态存储的容器会在进程 exit()
// 时触发析构并逐个销毁实例，同样撞上挂死线程（实测表现为退出阶段堆损坏
// 或挂死）。故堆分配 + 从不 delete = 进程生命周期内绝对安全的隔离区，
// 泄漏量级 = 挂死次数（罕见路径）。

thread_local ClapHostThreadType t_clapThreadType = ClapHostThreadType::Main;
} // namespace auradsp
