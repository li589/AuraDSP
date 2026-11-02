// plugin_host_client_posix.cpp —— PluginHostClient 的 POSIX 实现。
//
// 与 platform/win32/host/plugin_host_client.cpp 同类同接口同协议，
// 平台接缝按 POSIX 重表达：
//   - 控制通道：命名管道 → Unix domain socket（路径在
//     XDG_RUNTIME_DIR，回退 /tmp；名称含引擎 pid + 代际 serial）；
//   - 进程管理：CreateProcess/JobObject → fork+exec；宿主侧以
//     PR_SET_PDEATHSIG + getppid 轮询双保险防僵尸（见宿主 main）；
//     引擎侧终止走 SIGTERM → SIGKILL 并 waitpid 回收；
//   - 宿主定位：GetModuleFileName(engine.dll) → dladdr(本库符号)
//     取 libauradsp_engine.so 所在目录，同目录找 plugin_host_x64
//     （双宿主架构命名，Linux 无扩展名）；
//   - F-6 唤醒：命名事件 → 命名 POSIX 信号量（shm 名 + ".wake"），
//     宿主创建、客户端在 Hello 后打开，sem_post 唤醒（与 SetEvent
//     同为无分配无锁的内核调用，RT-safe 口径一致）；
//   - 读超时：PeekNamedPipe 轮询 → poll() + waitpid 存活检查，
//     超时杀宿主的隔离语义与 Win32 版一致。
#include "plugin_host_client.h"

#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <semaphore.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

namespace auradsp {
namespace {

std::atomic<uint32_t> s_hostCounter{1};

bool writeAll(int fd, const void* data, size_t size) {
    const auto* p = static_cast<const uint8_t*>(data);
    while (size > 0) {
        const ssize_t n = ::send(fd, p, size, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

bool readAll(int fd, void* data, size_t size) {
    auto* p = static_cast<uint8_t*>(data);
    while (size > 0) {
        const ssize_t n = ::recv(fd, p, size, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

bool hostExited(pid_t pid) {
    if (pid <= 0) return true;
    int status = 0;
    return ::waitpid(pid, &status, WNOHANG) != 0;
}

/* 带超时的读：poll 等可读，期间轮询宿主存活（语义同 Win32 版
 * readAllTimeout：宿主死了立即失败，不空等到超时）。 */
bool readAllTimeout(int fd, void* data, size_t size, pid_t proc,
                    int timeoutMs) {
    auto* p = static_cast<uint8_t*>(data);
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (size > 0) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) return false;
        const int remain = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)
                .count());
        pollfd pfd{};
        pfd.fd = fd;
        pfd.events = POLLIN;
        const int slice = remain < 50 ? remain : 50;
        const int r = ::poll(&pfd, 1, slice);
        if (r < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (r > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR))) {
            const ssize_t n = ::recv(fd, p, size, 0);
            if (n < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            if (n == 0) return false;
            p += n;
            size -= static_cast<size_t>(n);
            continue;
        }
        if (proc > 0 && hostExited(proc)) return false;
    }
    return true;
}

/* 超时/失联的宿主不可复用：杀进程并让下次 ensureHostLocked 重启。 */
void killHostOnTimeout(pid_t& proc) {
    if (proc <= 0) return;
    ::kill(proc, SIGKILL);
    int status = 0;
    ::waitpid(proc, &status, 0);
    proc = 0;
}

std::string moduleDirectory() {
    Dl_info info{};
    if (!dladdr(reinterpret_cast<void*>(&moduleDirectory), &info) ||
        !info.dli_fname) {
        return {};
    }
    std::string path = info.dli_fname;
    const size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) return {};
    return path.substr(0, slash);
}

std::string hostExecutablePath(HostArch arch) {
    const std::string dir = moduleDirectory();
    if (dir.empty()) return {};
    // 双宿主架构命名（《插件双宿主架构与跨格式扩展方案》§2.2）：
    // Linux 宿主为无扩展名 ELF，按位数分名。
    if (arch == HostArch::X86) return dir + "/plugin_host_x86";
    return dir + "/plugin_host_x64";
}

std::string socketBaseDir() {
    if (const char* xdg = std::getenv("XDG_RUNTIME_DIR");
        xdg && xdg[0] == '/') {
        // 存在性校验（审查修复 2026-11-03）：env 指向已不存在的
        // 目录时（陈旧会话变量/临时目录被清），宿主 bind 必然失败，
        // 而远程模式下扫描/加载只会静默归零、无任何回落——实测
        // 踩到过。目录不在或不可写即回退 /tmp（恒存在）。
        struct stat st {};
        if (::stat(xdg, &st) == 0 && S_ISDIR(st.st_mode) &&
            ::access(xdg, W_OK) == 0) {
            return xdg;
        }
    }
    return "/tmp";
}

} // namespace

PluginHostClient::PluginHostClient(HostArch arch) : m_arch(arch) {}

PluginHostClient::~PluginHostClient() {
    shutdown();
}

bool PluginHostClient::start() {
    const char* mode = std::getenv("AURA_PLUGIN_HOST_MODE");
    if (!mode || strcasecmp(mode, "process") != 0) return false;
    const std::string exe = hostExecutablePath(m_arch);
    // 须存在「且可执行」：产物经压缩包/工件流转可能丢失 +x，
    // 此时若仍宣称远程可用，后续每次 spawn 都会 EACCES 失败、
    // 扫描静默归零（CI 工件往返实测，2026-11-02）。不可执行
    // 即按宿主缺失处理，manager 回落进程内，与 Windows 的
    // 「exe 不在位则进程内」口径一致。
    if (exe.empty() || ::access(exe.c_str(), X_OK) != 0) return false;
    m_processMode.store(true, std::memory_order_release);
    return true;
}

bool PluginHostClient::alive() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_pipeHealthy || m_pipe < 0 || m_process <= 0 || !m_region) {
        return false;
    }
    int status = 0;
    return ::waitpid(m_process, &status, WNOHANG) == 0;
}

bool PluginHostClient::ensureHost() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return ensureHostLocked();
}

bool PluginHostClient::ensureHostLocked() {
    if (m_pipeHealthy && m_pipe >= 0 && m_process > 0 && m_region) {
        int status = 0;
        if (::waitpid(m_process, &status, WNOHANG) == 0) return true;
    }
    return launchLocked();
}

std::shared_ptr<SharedRegion> PluginHostClient::region() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_region;
}

void PluginHostClient::shutdown() {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_pipe >= 0 && m_pipeHealthy) {
        std::string ignored;
        int32_t status = 0;
        requestLocked(ipc::Op::Shutdown, {}, &ignored, &status);
    }
    closeHostHandlesLocked();
    m_region.reset();
    m_pipeHealthy = false;
}

void PluginHostClient::closeHostHandlesLocked() {
    if (m_wakeEvent) {
        sem_close(m_wakeEvent);
        m_wakeEvent = nullptr;
    }
    if (m_pipe >= 0) {
        ::close(m_pipe);
        m_pipe = -1;
    }
    if (!m_pipeName.empty()) {
        ::unlink(m_pipeName.c_str());
    }
    if (m_process > 0) {
        int status = 0;
        if (::waitpid(m_process, &status, WNOHANG) == 0) {
            ::kill(m_process, SIGTERM);
            const auto deadline = std::chrono::steady_clock::now() +
                                  std::chrono::milliseconds(1500);
            bool reaped = false;
            while (std::chrono::steady_clock::now() < deadline) {
                if (::waitpid(m_process, &status, WNOHANG) != 0) {
                    reaped = true;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            if (!reaped) {
                ::kill(m_process, SIGKILL);
                ::waitpid(m_process, &status, 0);
            }
        }
        m_process = 0;
    }
    m_hostPid.store(0, std::memory_order_release);
    m_pipeHealthy = false;
}

bool PluginHostClient::launchLocked() {
    closeHostHandlesLocked();
    m_region.reset();

    const std::string exe = hostExecutablePath(m_arch);
    // 须存在「且可执行」：产物经压缩包/工件流转可能丢失 +x，
    // 此时若仍宣称远程可用，后续每次 spawn 都会 EACCES 失败、
    // 扫描静默归零（CI 工件往返实测，2026-11-02）。不可执行
    // 即按宿主缺失处理，manager 回落进程内，与 Windows 的
    // 「exe 不在位则进程内」口径一致。
    if (exe.empty() || ::access(exe.c_str(), X_OK) != 0) return false;

    const uint32_t serial = s_hostCounter.fetch_add(1, std::memory_order_relaxed);
    const uint32_t pid = static_cast<uint32_t>(::getpid());
    m_shmName = "/AuraDSP.PluginHost." + std::to_string(pid) + "." +
                std::to_string(serial);
    m_pipeName = socketBaseDir() + "/AuraDSP.PluginHost." +
                 std::to_string(pid) + "." + std::to_string(serial) + ".sock";

    m_region = SharedRegion::create(m_shmName);
    if (!m_region) return false;

    const std::string pipeArg = "--pipe=" + m_pipeName;
    const std::string shmArg = "--shm=" + m_shmName;
    const std::string parentArg = "--parent=" + std::to_string(pid);

    const pid_t child = ::fork();
    if (child < 0) {
        closeHostHandlesLocked();
        m_region.reset();
        return false;
    }
    if (child == 0) {
        // 子进程：降低优先级（对应 Win32 BELOW_NORMAL，防插件内部
        // 分析线程与 RT 音频抢 CPU），然后 exec 宿主。宿主侧另有
        // PR_SET_PDEATHSIG 兜底（父进程死亡即自裁）。
        (void)nice(5);
        ::execl(exe.c_str(), exe.c_str(), pipeArg.c_str(), shmArg.c_str(),
                parentArg.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }

    m_process = child;
    m_hostPid.store(static_cast<uint32_t>(child), std::memory_order_release);

    if (!connectPipeLocked()) {
        closeHostHandlesLocked();
        m_region.reset();
        return false;
    }

    std::string hello;
    int32_t status = 0;
    if (!requestLocked(ipc::Op::Hello, {}, &hello, &status) || status != 1) {
        closeHostHandlesLocked();
        m_region.reset();
        return false;
    }

    /* F-6: 打开宿主音频线程的唤醒信号量。宿主在 listen 之前创建
     * 它，Hello 往返返回时必然已存在。打开失败不致命：宿主等待
     * 有 2 ms 超时兜底，代理侧缓存为空后干脆不 post。 */
    m_wakeEvent = sem_open((m_shmName + ".wake").c_str(), 0);
    if (m_wakeEvent == SEM_FAILED) m_wakeEvent = nullptr;

    m_generation.fetch_add(1, std::memory_order_acq_rel);
    m_pipeHealthy = true;
    return true;
}

bool PluginHostClient::connectPipeLocked() {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return false;
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        std::strncpy(addr.sun_path, m_pipeName.c_str(),
                     sizeof(addr.sun_path) - 1);
        if (::connect(fd, reinterpret_cast<sockaddr*>(&addr),
                      sizeof(addr)) == 0) {
            // 对端凭据校验（安全审查 2026-11-02）：路径回退 /tmp
            // 时要防同机其他用户抢先在可预测路径上 bind 假宿主、
            // 向引擎回灌伪造的 IPC 应答。uid 不符即判定路径已被
            // 占用/劫持，立即失败（不重试同一路径），上层回落
            // 进程内——与宿主侧 SO_PEERCRED 校验成对。
            ucred cred{};
            socklen_t credLen = sizeof(cred);
            if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred,
                             &credLen) != 0 ||
                cred.uid != ::getuid()) {
                ::close(fd);
                return false;
            }
            m_pipe = fd;
            return true;
        }
        ::close(fd);
        if (m_process > 0 && hostExited(m_process)) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

bool PluginHostClient::requestLocked(ipc::Op op, const std::vector<uint8_t>& payload,
                                     std::string* outPayload, int32_t* outStatus,
                                     int timeoutMs) {
    if (m_pipe < 0 || !m_region) return false;
    if (payload.size() > ipc::kMaxControlPayload) return false;

    ipc::MsgHeader header = {};
    header.magic = ipc::kMagic;
    header.version = static_cast<uint16_t>(ipc::kProtocolVersion);
    header.op = static_cast<uint16_t>(op);
    header.payloadSize = static_cast<uint32_t>(payload.size());
    header.requestId = m_requestId++;

    if (!writeAll(m_pipe, &header, sizeof(header)) ||
        (!payload.empty() && !writeAll(m_pipe, payload.data(), payload.size()))) {
        m_pipeHealthy = false;
        return false;
    }

    ipc::MsgResponse response = {};
    if (!readAllTimeout(m_pipe, &response, sizeof(response), m_process, timeoutMs)) {
        // 超时或宿主死亡：杀进程（幂等）+ 标记管道失效。下次请求自动重启。
        killHostOnTimeout(m_process);
        m_pipeHealthy = false;
        return false;
    }
    if (response.magic != ipc::kMagic ||
        response.version != static_cast<uint16_t>(ipc::kProtocolVersion) ||
        response.payloadSize > ipc::kMaxControlPayload) {
        m_pipeHealthy = false;
        return false;
    }

    std::string body;
    if (response.payloadSize > 0) {
        body.resize(response.payloadSize);
        if (!readAllTimeout(m_pipe, body.data(), body.size(), m_process,
                            timeoutMs)) {
            m_pipeHealthy = false;
            return false;
        }
    }

    if (outStatus) *outStatus = response.status;
    if (outPayload) *outPayload = std::move(body);
    return true;
}

bool PluginHostClient::request(ipc::Op op, const std::vector<uint8_t>& payload,
                               std::string* outPayload, int32_t* outStatus,
                               int timeoutMs) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!ensureHostLocked()) return false;
    if (!requestLocked(op, payload, outPayload, outStatus, timeoutMs)) {
        closeHostHandlesLocked();
        return false;
    }
    return true;
}

bool PluginHostClient::simple(ipc::Op op, const std::vector<uint8_t>& payload,
                              int32_t* outStatus, int timeoutMs) {
    return request(op, payload, nullptr, outStatus, timeoutMs);
}

bool PluginHostClient::load(uint32_t slot, const std::string& path,
                            const std::string& pluginId, double sampleRate,
                            uint32_t maxBlockSize, ipc::RemotePluginInfo& outInfo,
                            std::string& outError) {
    ipc::Writer w;
    w.u32(slot);
    w.f64(sampleRate);
    w.u32(maxBlockSize);
    w.str(path);
    w.str(pluginId);

    std::string body;
    int32_t status = 0;
    if (!request(ipc::Op::Load, w.data(), &body, &status) || status != 1) {
        outError = "plugin host load failed";
        return false;
    }
    if (body.size() != sizeof(ipc::RemotePluginInfo)) {
        outError = "plugin host returned malformed metadata";
        return false;
    }
    std::memcpy(&outInfo, body.data(), sizeof(outInfo));
    outInfo.path[sizeof(outInfo.path) - 1] = '\0';
    outInfo.name[sizeof(outInfo.name) - 1] = '\0';
    outInfo.errorMessage[sizeof(outInfo.errorMessage) - 1] = '\0';
    outError = outInfo.errorMessage;
    return true;
}

bool PluginHostClient::unload(uint32_t slot) {
    ipc::Writer w;
    w.u32(slot);
    int32_t status = 0;
    return simple(ipc::Op::Unload, w.data(), &status) && status == 1;
}

bool PluginHostClient::setBypass(uint32_t slot, bool bypass) {
    ipc::Writer w;
    w.u32(slot);
    w.u8(bypass ? 1 : 0);
    int32_t status = 0;
    return simple(ipc::Op::SetBypass, w.data(), &status) && status == 1;
}

bool PluginHostClient::getBypass(uint32_t slot, bool& bypass) {
    ipc::Writer w;
    w.u32(slot);
    int32_t status = 0;
    if (!simple(ipc::Op::GetBypass, w.data(), &status)) return false;
    bypass = status != 0;
    return true;
}

uint32_t PluginHostClient::getLatency(uint32_t slot) {
    ipc::Writer w;
    w.u32(slot);
    int32_t status = 0;
    if (!simple(ipc::Op::GetLatency, w.data(), &status) || status < 0) return 0;
    return static_cast<uint32_t>(status);
}

bool PluginHostClient::showEditor(uint32_t slot, const std::string& title) {
    ipc::Writer w;
    w.u32(slot);
    w.str(title);
    int32_t status = 0;
    return simple(ipc::Op::ShowEditor, w.data(), &status) && status == 1;
}

bool PluginHostClient::closeEditor(uint32_t slot) {
    ipc::Writer w;
    w.u32(slot);
    int32_t status = 0;
    return simple(ipc::Op::CloseEditor, w.data(), &status) && status == 1;
}

bool PluginHostClient::isEditorOpen(uint32_t slot) {
    ipc::Writer w;
    w.u32(slot);
    int32_t status = 0;
    return simple(ipc::Op::IsEditorOpen, w.data(), &status) && status == 1;
}

bool PluginHostClient::savePreset(uint32_t slot, const std::string& path) {
    ipc::Writer w;
    w.u32(slot);
    w.str(path);
    int32_t status = 0;
    return simple(ipc::Op::SavePreset, w.data(), &status) && status == 1;
}

bool PluginHostClient::loadPreset(uint32_t slot, const std::string& path) {
    ipc::Writer w;
    w.u32(slot);
    w.str(path);
    int32_t status = 0;
    return simple(ipc::Op::LoadPreset, w.data(), &status) && status == 1;
}

bool PluginHostClient::setStage(uint32_t slot, int stage) {
    ipc::Writer w;
    w.u32(slot);
    w.i32(stage);
    int32_t status = 0;
    return simple(ipc::Op::SetStage, w.data(), &status) && status == 1;
}

int PluginHostClient::getStage(uint32_t slot) {
    ipc::Writer w;
    w.u32(slot);
    int32_t status = 0;
    if (!simple(ipc::Op::GetStage, w.data(), &status)) return -1;
    return status;
}

bool PluginHostClient::updateFormat(double sampleRate, uint32_t maxBlockSize) {
    ipc::Writer w;
    w.f64(sampleRate);
    w.u32(maxBlockSize);
    int32_t status = 0;
    return simple(ipc::Op::UpdateFormat, w.data(), &status) && status == 1;
}

bool PluginHostClient::setChannelHint(uint32_t channels) {
    ipc::Writer w;
    w.u32(channels);
    int32_t status = 0;
    return simple(ipc::Op::SetChannelHint, w.data(), &status) && status == 1;
}

int PluginHostClient::scanPlugins(const std::string& extraDirsJson, bool deepScan) {
    ipc::Writer w;
    w.str(extraDirsJson);
    w.u8(deepScan ? 1 : 0);
    int32_t status = 0;
    if (!simple(ipc::Op::Scan, w.data(), &status)) return 0;
    return status;
}

int PluginHostClient::scanBegin(const std::string& extraDirsJson, bool deepScan) {
    ipc::Writer w;
    w.str(extraDirsJson);
    w.u8(deepScan ? 1 : 0);
    int32_t status = 0;
    if (!simple(ipc::Op::ScanBegin, w.data(), &status, 8000)) return 0;
    return status;
}

int PluginHostClient::scanStep(int maxItems) {
    ipc::Writer w;
    w.i32(maxItems);
    int32_t status = 0;
    if (!simple(ipc::Op::ScanStep, w.data(), &status, 8000)) return 0;
    return status;
}

int PluginHostClient::scanEnd() {
    int32_t status = 0;
    if (!simple(ipc::Op::ScanEnd, {}, &status, 8000)) return 0;
    return status;
}

int PluginHostClient::scanProcessed() {
    std::string body;
    int32_t status = 0;
    if (!request(ipc::Op::ScanProgress, {}, &body, &status) ||
        body.size() != sizeof(int32_t) * 2) {
        return -1;
    }
    int32_t processed = 0;
    std::memcpy(&processed, body.data(), sizeof(processed));
    return processed;
}

int PluginHostClient::scanTotal() {
    std::string body;
    int32_t status = 0;
    if (!request(ipc::Op::ScanProgress, {}, &body, &status) ||
        body.size() != sizeof(int32_t) * 2) {
        return -1;
    }
    int32_t total = 0;
    std::memcpy(&total, body.data() + sizeof(int32_t), sizeof(total));
    return total;
}

int PluginHostClient::getScannedCount() {
    int32_t status = 0;
    if (!simple(ipc::Op::GetScanCount, {}, &status)) return 0;
    return status;
}

std::string PluginHostClient::getScannedItemJson(uint32_t index) {
    ipc::Writer w;
    w.u32(index);
    std::string body;
    int32_t status = 0;
    if (!request(ipc::Op::GetScanItem, w.data(), &body, &status) || status != 1) return "{}";
    return body;
}

std::string PluginHostClient::getAllScannedJson() {
    std::string body;
    int32_t status = 0;
    if (!request(ipc::Op::GetAllScanned, {}, &body, &status) || status != 1) return "[]";
    return body;
}

} // namespace auradsp
