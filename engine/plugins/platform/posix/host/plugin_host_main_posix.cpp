// plugin_host_x64 —— Linux 进程外插件宿主主程序（双宿主架构）。
//
// 与 platform/win32/host/auradsp_plugin_host_main.cpp 对位：同一
// IPC 协议（plugin_ipc_protocol.h）、同一 PluginHostManager 驱动，
// 平台接缝按 POSIX 重表达：
//   - 控制通道：命名管道 → Unix domain socket（路径由客户端经
//     --pipe= 传入，位于 XDG_RUNTIME_DIR 或 /tmp）；
//   - 父进程看门狗：OpenProcess 等待 → PR_SET_PDEATHSIG（主）+
//     命令循环内 getppid/kill(parent, 0) 轮询（备），父死即退；
//   - F-6 唤醒：命名事件 → 命名 POSIX 信号量（--shm 名 + ".wake"），
//     宿主创建，音频线程 sem_timedwait 2 ms 兜底（语义同 Win32 版）；
//   - 音频线程实时调度：MMCSS/TIME_CRITICAL 无 POSIX 对应（需
//     特权 SCHED_FIFO），本阶段不设置——环饥饿由代理侧 missStreak
//     与宿主死亡判定兜底，与 Win32 的注释口径一致地记录在此。
// 二进制命名：plugin_host_x64（《插件双宿主架构与跨格式扩展
// 方案》§2.2；Linux 无扩展名）。客户端按 dladdr 定位引擎 .so
// 同目录的本程序。
#ifndef AURADSP_HOST_INPROC
#define AURADSP_HOST_INPROC 1
#endif

#include "plugin_host.h"
#include "plugin_host_command.h"
#include "plugin_ipc_protocol.h"
#include "plugin_shared_region.h"
#include "engine_internal.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <semaphore.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

extern "C" const char* auradsp_version(void) {
    return AURADSP_VERSION;
}

namespace {

struct HostOptions {
    std::string pipeName;
    std::string shmName;
    pid_t parentPid = 0;
};

void parseOptions(int argc, char** argv, HostOptions& out) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        const auto eq = arg.find('=');
        if (eq == std::string::npos) continue;
        const std::string key = arg.substr(0, eq);
        const std::string value = arg.substr(eq + 1);
        if (key == "--pipe") out.pipeName = value;
        else if (key == "--shm") out.shmName = value;
        else if (key == "--parent") out.parentPid = static_cast<pid_t>(std::strtoul(value.c_str(), nullptr, 10));
    }
}

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

/* 传输适配：命令分发已下沉到 platform/host/plugin_host_command.*（审计 R-07）。
 * POSIX 侧无 SEH，深扫查询直接使用共享层的 queryMetadataDirect——
 * 插件 AV 会带走宿主，由客户端超时 + 重启兜底（方案 D-6）。 */
bool socketWrite(void* user, const void* data, size_t size) {
    return writeAll(static_cast<int>(reinterpret_cast<intptr_t>(user)), data, size);
}

bool socketRead(void* user, void* data, size_t size) {
    return readAll(static_cast<int>(reinterpret_cast<intptr_t>(user)), data, size);
}

bool parentAlive(pid_t parentPid) {
    if (parentPid <= 0) return false;
    if (::getppid() != parentPid) return false;  // 已被过继 = 父已死
    return ::kill(parentPid, 0) == 0 || errno == EPERM;
}

} // namespace

int main(int argc, char** argv) {
    // 父进程死亡即自裁（主看门狗；fork→exec 间隙由宿主侧的
    // getppid 轮询兜底：若父已死，ppid 已变，循环立即退出）。
    ::prctl(PR_SET_PDEATHSIG, SIGKILL);

    HostOptions options;
    parseOptions(argc, argv, options);
    if (options.pipeName.empty() || options.shmName.empty() ||
        options.parentPid == 0) {
        return 1;
    }
    if (!parentAlive(options.parentPid)) return 1;

    auto region = auradsp::SharedRegion::open(options.shmName);
    if (!region || !region->valid()) return 1;
    auto* shared = region->header();
    if (shared->magic != auradsp::ipc::kMagic ||
        shared->version != auradsp::ipc::kProtocolVersion) {
        return 1;
    }
    shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Starting),
                            std::memory_order_release);
    shared->hostPid.store(static_cast<uint32_t>(::getpid()),
                          std::memory_order_release);
    shared->hostStartCount.fetch_add(1, std::memory_order_acq_rel);

    auradsp::PluginHostManager manager;

    /* F-6: 音频线程唤醒信号量（计数信号量作自动重置事件的近似：
     * 代理每次成功提交传输块 sem_post 一次；宿主忙时到达的 post
     * 累计计数，下一次等待立即返回，不丢唤醒；2 ms 超时仅为安全
     * 网。命名派生自 shm 名（每代宿主 serial 唯一）。 */
    const std::string wakeName = options.shmName + ".wake";
    sem_t* wakeSem = sem_open(wakeName.c_str(), O_CREAT, 0600, 0);
    if (wakeSem == SEM_FAILED) wakeSem = nullptr;

    const int listenFd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd < 0) return 1;
    ::unlink(options.pipeName.c_str());
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, options.pipeName.c_str(),
                 sizeof(addr.sun_path) - 1);
    if (::bind(listenFd, reinterpret_cast<sockaddr*>(&addr),
               sizeof(addr)) != 0 ||
        ::listen(listenFd, 1) != 0) {
        ::close(listenFd);
        return 1;
    }
    // 安全审查（2026-11-02）：socket 文件收紧到属主-only。路径回退
    // /tmp 时目录是全员可达的，默认 umask 下的权限不足以排除同机
    // 其他用户抢先 connect——抢先者能向宿主下达加载任意插件路径
    // 的命令（以属主身份 dlopen）。配合下方 SO_PEERCRED 校验，
    // 把控制通道收敛为同 uid 对端。
    ::chmod(options.pipeName.c_str(), 0600);
    const int connFd = ::accept(listenFd, nullptr, nullptr);
    ::close(listenFd);
    if (connFd < 0) {
        ::unlink(options.pipeName.c_str());
        return 1;
    }
    {
        // 对端凭据校验：只接受同 uid 的连接（客户端引擎进程）。
        ucred cred{};
        socklen_t credLen = sizeof(cred);
        if (::getsockopt(connFd, SOL_SOCKET, SO_PEERCRED, &cred,
                         &credLen) != 0 ||
            cred.uid != ::getuid()) {
            ::close(connFd);
            ::unlink(options.pipeName.c_str());
            return 1;
        }
    }

    shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Ready),
                            std::memory_order_release);

    std::atomic<bool> audioRunning{true};
    std::thread audioThread([&]() {
        pthread_setname_np(pthread_self(), "AuraPluginHostAudio");
        while (audioRunning.load(std::memory_order_acquire)) {
            bool worked = false;
            for (size_t slot = 0; slot < auradsp::ipc::kMaxSlots; ++slot) {
                auto& ring = shared->slots[slot];
                const uint32_t read = ring.inputRead.load(std::memory_order_acquire);
                const uint32_t write = ring.inputWrite.load(std::memory_order_acquire);
                if (read == write) continue;

                auto& in = ring.input[read % auradsp::ipc::kRingBlocks];
                uint32_t frames = (std::min)(in.frames, auradsp::ipc::kTransportFrames);
                auradsp::ipc::AudioBlock out = {};
                out.seq = in.seq;
                out.frames = frames;
                out.reserved = in.reserved;
                // 声道数与 frames 同口径钳制（安全审查 2026-11-02）：
                // reserved 由对端写入共享内存，越界值会让下方交错
                // 循环写爆栈上的 interleaved 缓冲；写端是我方代理，
                // 此处按协议上限防御性收敛（Win32 宿主同形态，另行
                // 记录待 dev 侧跟进）。
                const uint32_t channels = (std::min)(
                    auradsp::ipc::unpackTransportChannels(in.reserved),
                    auradsp::ipc::kChannels);
                const uint32_t mask =
                    auradsp::ipc::unpackTransportMask(in.reserved);
                float interleaved[auradsp::ipc::kChannels *
                                  auradsp::ipc::kTransportFrames] = {};
                for (uint32_t ch = 0; ch < channels; ++ch) {
                    for (uint32_t i = 0; i < frames; ++i) {
                        interleaved[i * channels + ch] = in.samples[ch][i];
                    }
                }
                if (frames > 0) {
                    manager.processSlotInterleaved(slot, interleaved, frames,
                                                   channels, mask);
                }
                for (uint32_t ch = 0; ch < channels; ++ch) {
                    for (uint32_t i = 0; i < frames; ++i) {
                        out.samples[ch][i] = interleaved[i * channels + ch];
                    }
                }

                const uint32_t outWrite = ring.outputWrite.load(std::memory_order_relaxed);
                const uint32_t outRead = ring.outputRead.load(std::memory_order_acquire);
                if (outWrite - outRead < auradsp::ipc::kRingBlocks) {
                    ring.output[outWrite % auradsp::ipc::kRingBlocks] = out;
                    ring.outputWrite.store(outWrite + 1, std::memory_order_release);
                    ring.chunksOut.fetch_add(1, std::memory_order_relaxed);
                } else {
                    ring.outputOverflows.fetch_add(1, std::memory_order_relaxed);
                }
                ring.inputRead.store(read + 1, std::memory_order_release);
                worked = true;
            }
            if (!worked) {
                /* F-6: 事件驱动唤醒（见 wakeSem 说明）；信号量创建
                 * 失败时退化为 1 ms 轮询（同 Win32 版回退路径）。 */
                if (wakeSem) {
                    timespec ts{};
                    clock_gettime(CLOCK_REALTIME, &ts);
                    ts.tv_nsec += 2 * 1000 * 1000;
                    if (ts.tv_nsec >= 1000000000L) {
                        ts.tv_sec += 1;
                        ts.tv_nsec -= 1000000000L;
                    }
                    sem_timedwait(wakeSem, &ts);
                } else {
                    ::usleep(1000);
                }
            }
        }
    });

    auradsp::ipc::HostTransport transport{
        reinterpret_cast<void*>(static_cast<intptr_t>(connFd)),
        &socketRead, &socketWrite};
    bool running = true;
    while (running) {
        if (!parentAlive(options.parentPid)) break;
        pollfd pfd{};
        pfd.fd = connFd;
        pfd.events = POLLIN;
        const int r = ::poll(&pfd, 1, 100);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (r > 0) {
            if (pfd.revents & POLLIN) {
                if (!auradsp::ipc::handleHostCommand(
                        transport, manager, &auradsp::ipc::queryMetadataDirect,
                        running)) {
                    running = false;
                }
            } else if (pfd.revents & (POLLHUP | POLLERR)) {
                running = false;
            }
        }
        for (size_t slot = 0; slot < auradsp::ipc::kMaxSlots; ++slot) {
            shared->slots[slot].editorOpen.store(
                manager.isEditorOpenSlot(slot) ? 1u : 0u, std::memory_order_release);
        }
    }

    shared->hostState.store(static_cast<uint32_t>(auradsp::ipc::HostState::Stopping),
                            std::memory_order_release);
    audioRunning.store(false, std::memory_order_release);
    if (audioThread.joinable()) audioThread.join();
    /* F-6: 客户端/代理可能仍持有借用副本——sem_unlink 只摘名，
     * 对象在全部 sem_close 后才销毁，期间对旧信号量的 post 无害
     * （无等待者），与 Win32 版注释口径一致。 */
    if (wakeSem) {
        sem_close(wakeSem);
        sem_unlink(wakeName.c_str());
    }
    ::close(connFd);
    ::unlink(options.pipeName.c_str());
    region.reset();
    return 0;
}
