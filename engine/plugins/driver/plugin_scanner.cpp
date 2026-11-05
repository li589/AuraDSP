#include "plugin_host.h"

#include "plugin_bundle.h"
#include "plugin_format_driver.h"
#include "plugin_metadata_util.h"
#include "win32_util.h"

#ifndef AURADSP_HOST_INPROC
#include "plugin_host_client.h"
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <mutex>
#include <thread>
#include <sstream>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

namespace auradsp {
namespace {

/* 位桥可用性（2026-11-04）：PluginHostManager 构造时写入一次，供快扫判定
 * 32 位条目能否被加载。默认 false（保守：没有桥就说清楚缺什么）。 */
std::atomic<bool> g_archBridgeAvailable{false};

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
    const int bits = pluginBinaryBitness(wpath);
    meta.fromQuickScan = true;
    if (bits == 0) {
        meta.is64Bit = false;
        meta.isCompatible = false;
        meta.errorMessage = "非当前系统可执行的二进制格式或文件已损坏";
    } else {
        meta.is64Bit = false;
        if (PluginScanner::archBridgeAvailable()) {
            meta.isCompatible = true;
        } else {
            meta.isCompatible = false;
            meta.errorMessage = "32 位插件需要 plugin_host_x86：位桥缺失或被禁用";
        }
    }

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
    // 中；能否加载取决于位桥是否就绪（2026-11-04 起按实际能力判定）。
    const int bits = pluginBinaryBitness(wp);
    if (bits == 0) {
        q.is64Bit = false;
        q.isCompatible = false;
        q.errorMessage = "非当前系统可执行的二进制格式或文件已损坏";
    } else if (bits == 64) {
        q.is64Bit = true;
    } else {
        q.is64Bit = false;
        if (!PluginScanner::archBridgeAvailable()) {
            q.isCompatible = false;
            q.errorMessage = "32 位插件需要 plugin_host_x86：位桥缺失或被禁用";
        }
    }
    q.vendor = vendor;
    q.version = !peVer.empty() ? peVer : "1.0";
    q.category = "AudioEffect";
    q.fromQuickScan = true;   // 文件头启发式，加载路不得当作真值种子
    return q;
}

// 单个候选的元数据提取。口径（2026-11-04 起全格式统一）：
//   快扫 = 纯文件头（makeQuickMeta：文件名 / 目录 / PE 版本资源），零代码执行；
//   深扫 = 载入模块读真值（driver->queryMetadata），由 scanStep 按位数分派宿主，
//          仅在宿主不可用的回退路径才会在本进程执行（VST2 除外，见下）。
// 原 CLAP「快扫也载入模块」（supportsQuickMetadata）已退役：快扫执行第三方
// 代码与「快扫绝对安全」的前提冲突，真实名称一律由深扫/加载路给出。
std::vector<PluginMetadata> scanCandidateMeta(const PluginScanner::ScanCandidate& c, bool deepScan) {
    std::vector<PluginMetadata> out;
    if (!deepScan) {
        out.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
        return out;
    }
#if !defined(AURADSP_HOST_INPROC)
    /* VST2 安全策略（2026-11-03 实测）：引擎进程内深扫 VST2 需要 LoadLibrary
     * 未知厂商 DLL，实测 Blue Cat / FabFilter 等真实插件会在
     * VSTPluginMain/effOpen 阶段直接 AV 崩溃（整进程 0xC0000005）。因此引擎
     * 进程内一律只做 PE 快扫；深扫由 scanStep 按位数分派宿主（崩溃隔离在
     * 子进程）。宿主进程自身（AURADSP_HOST_INPROC=1）就是隔离区，允许深扫。 */
    if (c.format == PluginFormat::VST2) {
        out.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
        return out;
    }
#endif
    auto* driver = PluginDriverRegistry::instance().find(c.format);
    if (driver) {
        std::vector<PluginMetadata> metas;
        if (PluginScanner::queryMetadata(c.binaryPath, c.format, metas) && !metas.empty()) {
            return metas;
        }
    }
    out.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
    return out;
}

// 深扫单项超时（2026-10-28 用户实测：个别插件在 LoadLibrary / 实例化阶段
// 挂死，整条扫描链路卡住，UI 永远停在「正在扫描」）。
//
// 策略：元数据查询放到 detached worker 线程，主扫描线程最多等
// kScanItemTimeoutMs。超时 → 放弃该候选并回退「快速信息」条目（仍出现在
// 列表里，标注超时；用户可正常尝试挂载——挂载路径有独立的异步超时保护），
// 扫描继续推进。
//
// 已知代价：挂死的线程无法安全终止（C++ 无取消语义），会一直停在
// LoadLibrary/DllMain 里。每个超时项泄漏一条线程；同一模块的后续
// LoadLibrary 可能被全局装载锁挡住——这是进程内托管的固有上限，故
// 宿主设「放弃线程上限」（scanStep 内检查），超过即中止本轮扫描并保留
// 已扫结果。深扫的崩溃隔离默认由「按候选位数借宿主」承担（2026-11-04 起，
// 见 deepScanHostEnabled），引擎进程内深扫只是宿主不可用时的回退。
constexpr int kScanItemTimeoutMs = 2500;

// 放弃线程上限：超过即不再继续深扫（避免无限泄漏把进程拖垮）。
constexpr int kScanAbandonLimit = 4;

// D-2（2026-11-04）：深扫宿主开关。默认 host——深扫一律借「能加载它的那个
// 宿主」做隔离（X64 宿主可仅扫描用途懒启动）；AURA_PLUGIN_DEEP_SCAN=inproc
// 回到旧行为（VST3/CLAP 在引擎内深扫、VST2 只快扫），用于不想多一个常驻
// 进程的场景与整条链路的回退。注意与 AURA_PLUGIN_HOST_MODE 正交：若宿主
// 已因 process 模式在跑，深扫仍优先用它（inproc 只是不为扫描额外拉起进程）。
bool envEqualsNoCase(const char* v, const char* lit) {
    if (!v) return false;
    while (*v && *lit) {
        char a = *v, b = *lit;
        if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = static_cast<char>(b - 'A' + 'a');
        if (a != b) return false;
        ++v; ++lit;
    }
    return *v == '\0' && *lit == '\0';
}

bool deepScanHostEnabled() {
    return !envEqualsNoCase(std::getenv("AURA_PLUGIN_DEEP_SCAN"), "inproc");
}

struct GuardedMetaState {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    std::vector<PluginMetadata> out;
};

// 返回 true = 在超时内完成；false = 超时（结果不可用，线程被放弃）。
bool queryMetaWithTimeout(const PluginScanner::ScanCandidate& c, bool deep,
                          int timeoutMs, std::vector<PluginMetadata>& out) {
    auto state = std::make_shared<GuardedMetaState>();
    std::thread([state, c, deep]() {
        std::vector<PluginMetadata> r = scanCandidateMeta(c, deep);
        {
            std::lock_guard<std::mutex> lk(state->m);
            state->out = std::move(r);
            state->done = true;
        }
        state->cv.notify_all();
    }).detach();

    std::unique_lock<std::mutex> lk(state->m);
    if (!state->cv.wait_for(lk, std::chrono::milliseconds(timeoutMs),
                            [&] { return state->done; })) {
        return false;
    }
    out = std::move(state->out);
    return true;
}

// 文件指纹：大小 + 修改时间。仅用于缓存有效性判定，失败时返回 false
// （= 不可缓存、每次都重扫——安全退化）。
bool fileStamp(const std::string& path, std::pair<uint64_t, int64_t>& out) {
    std::error_code ec;
    auto sz = fs::file_size(path, ec);
    if (ec) return false;
    auto mtime = fs::last_write_time(path, ec);
    if (ec) return false;
    int64_t t = static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(mtime.time_since_epoch()).count());
    out = {static_cast<uint64_t>(sz), t};
    return true;
}

#ifndef AURADSP_HOST_INPROC
// 32 位 VST2 远程深扫结果 -> 本地元数据（2026-11-03）。桥宿主返回的是
// 定长 RemotePluginInfo；字段与 PluginMetadata 一一对应，format 数值同源。
PluginMetadata fromRemoteInfo(const ipc::RemotePluginInfo& r, const std::string& fallbackPath) {
    PluginMetadata m;
    m.path = r.path[0] ? r.path : fallbackPath;
    m.id = r.id;
    m.name = r.name;
    m.bundleName = r.bundleName;
    m.vendor = r.vendor[0] ? r.vendor : "Unknown";
    m.version = r.version[0] ? r.version : "1.0";
    m.category = r.category[0] ? r.category : "AudioEffect";
    m.description = r.description;
    m.format = static_cast<PluginFormat>(r.format);
    m.is64Bit = r.is64Bit != 0;
    m.latency = r.latency;
    m.isCompatible = r.isCompatible != 0;
    m.errorMessage = r.errorMessage;
    if (m.bundleName.empty()) m.bundleName = fs::path(m.path).stem().string();
    if (m.name.empty()) m.name = m.bundleName;
    return m;
}
#endif

} // namespace

void PluginScanner::setArchBridgeAvailable(bool available) {
    g_archBridgeAvailable.store(available, std::memory_order_release);
}

bool PluginScanner::archBridgeAvailable() {
    return g_archBridgeAvailable.load(std::memory_order_acquire);
}

std::vector<std::string> PluginScanner::getDefaultSearchPaths() {
    return defaultPluginSearchPaths();
}

std::string PluginScanner::resolveBundleBinary(const std::string& bundlePath, PluginFormat format,
                                               std::string* outArch) {
    auto* driver = PluginDriverRegistry::instance().find(format);
    if (!driver) return "";
    return driver->resolveBinary(bundlePath, outArch);
}

bool PluginScanner::queryMetadata(const std::string& filePath, PluginFormat format,
                                  std::vector<PluginMetadata>& outPlugins) {
    auto* driver = PluginDriverRegistry::instance().find(format);
    if (!driver) return false;

    std::string binaryPath = driver->resolveBinary(filePath);
    if (binaryPath.empty()) return false;
    std::wstring wpath = utf8ToWide(binaryPath);

    // D2：32 位插件不进入 LoadLibrary —— x64 进程加载 32 位 DLL 必然
    // ERROR_BAD_EXE_FORMAT(193)，旧实现把它当"打开失败"，扫描结果里直接
    // 消失。这里提前识别，产出"可发现但不可加载"条目（isCompatible=false）。
    if (pluginBinaryBitness(wpath) != 64) {
        PluginMetadata meta;
        fill32BitIncompatible(meta, filePath, format, wpath);
        outPlugins.push_back(meta);
        return true;
    }

    return driver->queryMetadata(filePath, binaryPath, outPlugins);
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
                auto* driver = PluginDriverRegistry::instance().findForPath(entry.path().string());
                if (!driver) continue;

                ScanCandidate c;
                c.format = driver->format();
                if (entry.is_directory()) {
                    it.disable_recursion_pending();
                    c.binaryPath = driver->resolveBinary(entry.path().string());
                    if (c.binaryPath.empty()) continue;   // 目录以 .vst3 结尾但不是有效 bundle
                    c.path = entry.path().string();
                    c.displayName = entry.path().stem().string();
                } else {
                    // VST2 的「是不是插件」判定在驱动 resolveBinary 里（PE 导出表）。
                    // 旧实现只对目录调用 resolveBinary，文件直接入列，于是同目录
                    // 的依赖 DLL 会被当成 VST2 候选。统一走驱动解析，空即跳过。
                    c.binaryPath = driver->resolveBinary(entry.path().string());
                    if (c.binaryPath.empty()) continue;
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

std::vector<PluginMetadata> PluginScanner::scan(const std::vector<std::string>& searchPaths, bool deepScan) {
    // 一次性扫描（保留原语义）：枚举 + 逐个取元数据。分块扫描走
    // PluginHostManager::scanBegin/scanStep，两边共用 enumerate 与同一套
    // 元数据提取实现，保证「一次性 == 分块」结果一致。
    std::vector<PluginMetadata> results;
    int abandoned = 0;
    for (const auto& c : enumerate(searchPaths)) {
        std::vector<PluginMetadata> metas;
        bool ok = true;
        if (deepScan && abandoned < kScanAbandonLimit) {
            ok = queryMetaWithTimeout(c, deepScan, kScanItemTimeoutMs, metas);
            if (!ok) ++abandoned;
        } else if (deepScan) {
            ok = false;   // 放弃线程已达上限：不再深扫，全部回退快扫
        } else {
            metas = scanCandidateMeta(c, deepScan);
        }
        if (!ok) {
            PluginMetadata q = makeQuickMeta(c.binaryPath, c.displayName, c.format);
            q.errorMessage = "深度扫描超时：插件无响应，已回退为快速信息";
            metas.push_back(std::move(q));
        }
        for (auto& m : metas) results.push_back(std::move(m));
    }
    return results;
}

//------------------------------------------------------------------------------
// PluginHostManager
//------------------------------------------------------------------------------
PluginHostManager::PluginHostManager() {
#ifndef AURADSP_HOST_INPROC
    /* D-2（2026-11-04）：X64 客户端允许「仅扫描」启动——AURA_PLUGIN_HOST_MODE
     * 未设 = 加载仍是进程内（m_remoteMode=false），但深扫可以借宿主做隔离。
     * processMode() 如实区分两种角色，加载分支只认它。 */
    m_remoteClient = std::make_shared<PluginHostClient>();
    if (m_remoteClient->start(deepScanHostEnabled())) {
        m_remoteMode = m_remoteClient->processMode();
    } else {
        m_remoteClient.reset();
        m_remoteMode = false;
    }
    // 独立探测与启动 32 位桥宿主客户端（plugin_host_x86）：
    // 即使 64 位插件走进程内模式，只要 x86 宿主在位，32 位插件也能透明经位桥运行。
    auto x86 = std::make_shared<PluginHostClient>(HostArch::X86);
    if (x86->start()) {
        m_remoteClientX86 = std::move(x86);
    }
    // 位桥可用性一次性写入（快扫的 32 位标记依赖它，见 D-5）。
    PluginScanner::setArchBridgeAvailable(m_remoteClientX86 != nullptr);
#endif
}

#ifndef AURADSP_HOST_INPROC
std::shared_ptr<PluginHostClient> PluginHostManager::remoteClientFor(
        const std::string& path) {
    // 双宿主分派：仅当 x86 桥客户端就绪且目标二进制确证为 32 位
    // 时走桥；位数未知/64 位/桥缺位一律 x64 客户端（单宿主时代
    // 的原行为）。bundle 路径先经驱动 resolveBinary 落到真实
    // 二进制再探测（与进程内分支的解析口径一致）。
    if (m_remoteClientX86) {
        std::string bin = path;
        if (auto* driver = PluginDriverRegistry::instance().findForPath(path)) {
            const std::string resolved = driver->resolveBinary(path);
            if (!resolved.empty()) bin = resolved;
        }
        if (pluginBinaryBitness(utf8ToWide(bin)) == 32) {
            return m_remoteClientX86;
        }
    }
    return m_remoteClient;
}

std::shared_ptr<PluginHostClient> PluginHostManager::remoteScanClientFor(
        const std::string& binaryPath) {
    /* D-1（2026-11-04）：深扫分派按「谁能加载这个 DLL」选宿主，与加载的
     * env 开关解耦。32 位 → 桥（在位即可）；64 位 → x64 宿主（process 模式
     * 的加载宿主，或 deepScanHostEnabled() 允许的仅扫描实例——构造时已按
     * 开关决定 m_remoteClient 是否存在，这里不重复读 env）。位数未知 →
     * nullptr：宁可回退快扫，不做一次注定失败的 LoadLibrary。 */
    const int bits = pluginBinaryBitness(utf8ToWide(binaryPath));
    if (bits == 32) {
        return m_remoteClientX86;
    }
    if (bits == 64) {
        return m_remoteClient;
    }
    return nullptr;
}
#endif

PluginHostManager::~PluginHostManager() {
    // 先停止控制线程（避免新任务进入）
    m_controlRunning.store(false, std::memory_order_release);
    m_controlCv.notify_all();
    if (m_controlThread.joinable()) m_controlThread.join();
    // 再同步卸载所有槽（控制线程已停，安全）
    for (size_t s = 0; s < kMaxPluginSlots; ++s) {
        unloadPluginSlot(s);
    }
#ifndef AURADSP_HOST_INPROC
    if (m_remoteClient) m_remoteClient->shutdown();
    if (m_remoteClientX86) m_remoteClientX86->shutdown();
#endif
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

std::vector<std::string> PluginHostManager::collectSearchPathsLocked(const std::string& extraDirsJson) const {
    /* 2026-10-28（P-042）：扫描目录单源在 UI 列表——调用方传了目录就**只**
     * 扫这些目录（含平台预置条目，UI 已负责发现与勾选），不再叠加隐式默认
     * 目录（旧行为会让用户「移除/取消勾选」在引擎侧失效）。
     * 空输入保留默认目录兜底：兼容直接调 API 的脚本/冒烟与旧版调用方。 */
    std::vector<std::string> searchPaths;
    if (!extraDirsJson.empty()) {
        std::istringstream iss(extraDirsJson);
        std::string path;
        while (std::getline(iss, path, ';')) {
            if (!path.empty() && fs::exists(path)) searchPaths.push_back(path);
        }
        return searchPaths;
    }
    return PluginScanner::getDefaultSearchPaths();
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

        std::vector<PluginMetadata> metas;
        bool ok = true;
        bool remoteHandled = false;
#ifndef AURADSP_HOST_INPROC
        /* D-1（2026-11-04）：深扫按候选位数借宿主做隔离——不再区分「只有
         * 32 位 VST2 走桥」，也不再在 process 模式下把整轮扫描甩给 x64 宿主。
         * 规则：优先 remoteScanClientFor（能加载它的那个进程）；宿主不可用时
         * VST2 绝不回引擎（安全铁律 D-4），VST3/CLAP 保留进程内深扫（旧能力，
         * 2500ms 超时 + 放弃线程上限）。 */
        if (job.deep) {
            if (auto client = remoteScanClientFor(c.binaryPath)) {
                std::vector<ipc::RemotePluginInfo> infos;
                if (client->queryMetadata(c.path, infos, kScanItemTimeoutMs)) {
                    for (const auto& info : infos) {
                        metas.push_back(fromRemoteInfo(info, c.path));
                    }
                }
                remoteHandled = true;
                if (metas.empty()) {
                    /* 深扫未返回（插件拒绝/坏 magic/超时）→ 回退快扫。快扫元数据
                     * 本身不是「不兼容」，errorMessage 保持为空——旧实现在这里
                     * 塞告警文案，会污染本可正常挂载的条目（2026-11-04）。 */
                    metas.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
                }
            }
        }
#endif
        if (!remoteHandled) {
            if (job.deep) {
#ifndef AURADSP_HOST_INPROC
                if (c.format == PluginFormat::VST2) {
                    // 安全铁律（D-4）：没有可用宿主时，VST2 绝不在引擎进程内
                    // LoadLibrary（实测真实插件在 VSTPluginMain/effOpen 直接 AV）。
                    // 退化为快扫（errorMessage 保持为空：元数据浅不等于不兼容）。
                    metas.push_back(makeQuickMeta(c.binaryPath, c.displayName, c.format));
                    remoteHandled = true;
                }
#endif
                if (!remoteHandled) {
                    if (job.abandonedThreads < kScanAbandonLimit) {
                        ok = queryMetaWithTimeout(c, true, kScanItemTimeoutMs, metas);
                        if (!ok) {
                            ++job.timedOut;
                            ++job.abandonedThreads;
                        }
                    } else {
                        // 放弃线程已达上限：停止深扫（降级快扫），并让上层把本轮
                        // 标记为中断（Dart 侧保留上次结果 + 提示）。
                        ok = false;
                    }
                }
            } else {
                metas = scanCandidateMeta(c, false);
            }
        }
        if (!ok) {
            PluginMetadata q = makeQuickMeta(c.binaryPath, c.displayName, c.format);
            q.errorMessage = "深度扫描超时：插件无响应，已回退为快速信息";
            metas.push_back(std::move(q));
        }
        for (auto& m : metas) m_scannedPlugins.push_back(std::move(m));
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

} // namespace auradsp
