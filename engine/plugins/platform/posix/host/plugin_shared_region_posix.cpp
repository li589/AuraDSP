// plugin_shared_region_posix.cpp —— SharedRegion 的 POSIX 实现。
//
// 与 platform/win32/host/plugin_shared_region.cpp 对位：共享内存由
// shm_open + ftruncate + mmap 提供（名称以 / 开头、无其他斜杠）；
// 头部初始化与校验口径与 Win32 版逐项一致（magic/version/maxSlots/
// transportFrames + 环形计数清零）。名称生命周期：create 保留名称
// 供宿主 rendezvous open；析构时 shm_unlink（重复摘名无害），与
// Win32 命名对象「最后一个句柄关闭即消失」的近似对齐。
#include "plugin_shared_region.h"

#include <fcntl.h>
#include <cerrno>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>

namespace auradsp {

SharedRegion::~SharedRegion() {
    if (m_view) {
        munmap(m_view, sizeof(ipc::SharedAudio));
        m_view = nullptr;
    }
    if (m_fd >= 0) {
        close(m_fd);
        m_fd = -1;
    }
    // 名称 rendezvous 已完成/作废：摘名（不存在时无害）。映射本体
    // 在任一侧仍映射时存续，与 Win32 句柄语义近似。
    if (!m_name.empty()) shm_unlink(m_name.c_str());
}

std::shared_ptr<SharedRegion> SharedRegion::create(const Name& name) {
    const size_t size = sizeof(ipc::SharedAudio);
    int fd = shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 && errno == EEXIST) {
        // 同名残留（上一代引擎/宿主异常退出未摘名）：摘除重试一次。
        shm_unlink(name.c_str());
        fd = shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    }
    if (fd < 0) return nullptr;
    if (ftruncate(fd, static_cast<off_t>(size)) != 0) {
        close(fd);
        shm_unlink(name.c_str());
        return nullptr;
    }
    void* view = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                      fd, 0);
    if (view == MAP_FAILED) {
        close(fd);
        shm_unlink(name.c_str());
        return nullptr;
    }

    auto region = std::shared_ptr<SharedRegion>(
        new SharedRegion(name, fd, view));
    auto* header = region->header();
    std::memset(header, 0, size);
    header->magic = ipc::kMagic;
    header->version = ipc::kProtocolVersion;
    header->maxSlots = ipc::kMaxSlots;
    header->transportFrames = ipc::kTransportFrames;
    for (uint32_t i = 0; i < ipc::kMaxSlots; ++i) {
        header->slots[i].inputWrite.store(0, std::memory_order_relaxed);
        header->slots[i].inputRead.store(0, std::memory_order_relaxed);
        header->slots[i].outputWrite.store(0, std::memory_order_relaxed);
        header->slots[i].outputRead.store(0, std::memory_order_relaxed);
        header->slots[i].inputOverflows.store(0, std::memory_order_relaxed);
        header->slots[i].outputOverflows.store(0, std::memory_order_relaxed);
        header->slots[i].chunksIn.store(0, std::memory_order_relaxed);
        header->slots[i].chunksOut.store(0, std::memory_order_relaxed);
    }
    return region;
}

std::shared_ptr<SharedRegion> SharedRegion::open(const Name& name) {
    const size_t size = sizeof(ipc::SharedAudio);
    const int fd = shm_open(name.c_str(), O_RDWR, 0600);  // 名称由 create 侧保留
    if (fd < 0) return nullptr;
    // 尺寸校验（安全审查 2026-11-02）：同名对象若比协议结构小
    // （残留/异构对象），直接按全尺寸 mmap 后访问会 SIGBUS。
    // 先 fstat 确认对象至少一整个 SharedAudio 再映射。
    {
        struct stat st {};
        if (::fstat(fd, &st) != 0 ||
            st.st_size < static_cast<off_t>(size)) {
            close(fd);
            return nullptr;
        }
    }
    void* view = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                      fd, 0);
    if (view == MAP_FAILED) {
        close(fd);
        return nullptr;
    }
    auto region = std::shared_ptr<SharedRegion>(
        new SharedRegion(name, fd, view));
    auto* header = region->header();
    if (header->magic != ipc::kMagic ||
        header->version != ipc::kProtocolVersion ||
        header->maxSlots != ipc::kMaxSlots ||
        header->transportFrames != ipc::kTransportFrames) {
        return nullptr;
    }
    return region;
}

} // namespace auradsp
