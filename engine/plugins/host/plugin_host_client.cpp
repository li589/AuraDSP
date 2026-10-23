#include "plugin_host_client.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

namespace auradsp {
namespace {

std::atomic<uint32_t> s_hostCounter{1};

bool writeAll(HANDLE pipe, const void* data, size_t size) {
    const auto* p = static_cast<const uint8_t*>(data);
    while (size > 0) {
        DWORD written = 0;
        const DWORD chunk = static_cast<DWORD>(size > 0x7fffffffu ? 0x7fffffffu : size);
        if (!WriteFile(pipe, p, chunk, &written, nullptr) || written == 0) return false;
        p += written;
        size -= written;
    }
    return true;
}

bool readAll(HANDLE pipe, void* data, size_t size) {
    auto* p = static_cast<uint8_t*>(data);
    while (size > 0) {
        DWORD got = 0;
        const DWORD chunk = static_cast<DWORD>(size > 0x7fffffffu ? 0x7fffffffu : size);
        if (!ReadFile(pipe, p, chunk, &got, nullptr) || got == 0) return false;
        p += got;
        size -= got;
    }
    return true;
}

std::wstring moduleDirectory() {
    HMODULE mod = GetModuleHandleW(L"auradsp_engine.dll");
    if (!mod) mod = GetModuleHandleW(nullptr);
    wchar_t path[MAX_PATH] = {};
    const DWORD n = GetModuleFileNameW(mod, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::wstring dir(path, n);
    const size_t slash = dir.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    return dir.substr(0, slash);
}

std::wstring hostExecutablePath() {
    const std::wstring dir = moduleDirectory();
    if (dir.empty()) return {};
    return dir + L"\\auradsp_plugin_host.exe";
}

void enableKillOnClose(HANDLE job) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info));
}

} // namespace

PluginHostClient::PluginHostClient() = default;

PluginHostClient::~PluginHostClient() {
    shutdown();
}

bool PluginHostClient::start() {
    const char* mode = std::getenv("AURA_PLUGIN_HOST_MODE");
    if (!mode || _stricmp(mode, "process") != 0) return false;
    const std::wstring exe = hostExecutablePath();
    if (exe.empty() || !std::filesystem::exists(std::filesystem::path(exe))) return false;
    m_processMode.store(true, std::memory_order_release);
    return true;
}

bool PluginHostClient::alive() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_pipeHealthy || !m_pipe || !m_process || !m_region) return false;
    return WaitForSingleObject(m_process, 0) == WAIT_TIMEOUT;
}

bool PluginHostClient::ensureHost() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return ensureHostLocked();
}

bool PluginHostClient::ensureHostLocked() {
    if (m_pipeHealthy && m_pipe && m_process && m_region &&
        WaitForSingleObject(m_process, 0) == WAIT_TIMEOUT) {
        return true;
    }
    return launchLocked();
}

std::shared_ptr<SharedRegion> PluginHostClient::region() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_region;
}

void PluginHostClient::shutdown() {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_pipe && m_pipeHealthy) {
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
        CloseHandle(m_wakeEvent);
        m_wakeEvent = nullptr;
    }
    if (m_pipe) {
        CloseHandle(m_pipe);
        m_pipe = nullptr;
    }
    if (m_process) {
        if (WaitForSingleObject(m_process, 1500) == WAIT_TIMEOUT) {
            TerminateProcess(m_process, 0);
            WaitForSingleObject(m_process, 1000);
        }
        CloseHandle(m_process);
        m_process = nullptr;
    }
    if (m_job) {
        CloseHandle(m_job);
        m_job = nullptr;
    }
    m_hostPid.store(0, std::memory_order_release);
    m_pipeHealthy = false;
}

bool PluginHostClient::launchLocked() {
    closeHostHandlesLocked();
    m_region.reset();

    const std::wstring exe = hostExecutablePath();
    if (exe.empty() || !std::filesystem::exists(std::filesystem::path(exe))) return false;

    const uint32_t serial = s_hostCounter.fetch_add(1, std::memory_order_relaxed);
    const uint32_t pid = GetCurrentProcessId();
    m_pipeName = L"\\\\.\\pipe\\AuraDSP.PluginHost." + std::to_wstring(pid) + L"." +
                 std::to_wstring(serial);
    m_shmName = L"Local\\AuraDSP.PluginHost." + std::to_wstring(pid) + L"." +
                std::to_wstring(serial);

    m_region = SharedRegion::create(m_shmName);
    if (!m_region) return false;

    m_job = CreateJobObjectW(nullptr, nullptr);
    if (m_job) enableKillOnClose(m_job);

    std::wstring cmd = L"\"" + exe + L"\" --pipe=" + m_pipeName +
                       L" --shm=" + m_shmName + L" --parent=" + std::to_wstring(pid);
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(L'\0');

    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};

    // Inherit the engine's working directory (nullptr): plugins resolve IR
    // libraries / persisted state relative to CWD, and the in-process path
    // sees the engine's CWD. Pointing the host at the DLL directory instead
    // gives the same plugin a different resource view (observed: Convology
    // XT loads a 0.6-gain IR in-process but a unity state in the host).
    if (!CreateProcessW(exe.c_str(), cmdBuf.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                        nullptr, nullptr, &si, &pi)) {
        closeHostHandlesLocked();
        m_region.reset();
        return false;
    }

    if (m_job) AssignProcessToJobObject(m_job, pi.hProcess);
    // P2 防抖（2026-10-22）：宿主进程整体 BELOW_NORMAL——插件内部分析线程
    // （Ozone 级）与宿主工作线程都不与 RT 音频线程抢 CPU。
    SetPriorityClass(pi.hProcess, BELOW_NORMAL_PRIORITY_CLASS);
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    m_process = pi.hProcess;
    m_hostPid.store(pi.dwProcessId, std::memory_order_release);

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

    /* F-6: 打开宿主音频线程的唤醒事件。宿主在 ConnectNamedPipe 之前创建
     * 该事件，Hello 往返返回时它必然已存在。打开失败不致命：宿主等待有
     * 2 ms 超时兜底，代理侧缓存到空句柄后干脆不 SetEvent。 */
    m_wakeEvent = OpenEventW(EVENT_MODIFY_STATE, FALSE,
                             (m_shmName + L".wake").c_str());

    m_generation.fetch_add(1, std::memory_order_acq_rel);
    m_pipeHealthy = true;
    return true;
}

bool PluginHostClient::connectPipeLocked() {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        HANDLE pipe = CreateFileW(m_pipeName.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                                  nullptr, OPEN_EXISTING, 0, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) {
            m_pipe = pipe;
            return true;
        }
        if (m_process && WaitForSingleObject(m_process, 0) != WAIT_TIMEOUT) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

bool PluginHostClient::requestLocked(ipc::Op op, const std::vector<uint8_t>& payload,
                                     std::string* outPayload, int32_t* outStatus) {
    if (!m_pipe || !m_region) return false;
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
    if (!readAll(m_pipe, &response, sizeof(response))) {
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
        if (!readAll(m_pipe, body.data(), body.size())) {
            m_pipeHealthy = false;
            return false;
        }
    }

    if (outStatus) *outStatus = response.status;
    if (outPayload) *outPayload = std::move(body);
    return true;
}

bool PluginHostClient::request(ipc::Op op, const std::vector<uint8_t>& payload,
                               std::string* outPayload, int32_t* outStatus) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!ensureHostLocked()) return false;
    if (!requestLocked(op, payload, outPayload, outStatus)) {
        closeHostHandlesLocked();
        return false;
    }
    return true;
}

bool PluginHostClient::simple(ipc::Op op, const std::vector<uint8_t>& payload,
                              int32_t* outStatus) {
    return request(op, payload, nullptr, outStatus);
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
    if (!simple(ipc::Op::ScanBegin, w.data(), &status)) return 0;
    return status;
}

int PluginHostClient::scanStep(int maxItems) {
    ipc::Writer w;
    w.i32(maxItems);
    int32_t status = 0;
    if (!simple(ipc::Op::ScanStep, w.data(), &status)) return 0;
    return status;
}

int PluginHostClient::scanEnd() {
    int32_t status = 0;
    if (!simple(ipc::Op::ScanEnd, {}, &status)) return 0;
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
