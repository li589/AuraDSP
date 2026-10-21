#include "plugin_shared_region.h"

namespace auradsp {

SharedRegion::~SharedRegion() {
    if (m_view) {
        UnmapViewOfFile(m_view);
        m_view = nullptr;
    }
    if (m_mapping) {
        CloseHandle(m_mapping);
        m_mapping = nullptr;
    }
}

std::shared_ptr<SharedRegion> SharedRegion::create(const std::wstring& name) {
    const DWORD size = static_cast<DWORD>(sizeof(ipc::SharedAudio));
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
                                        0, size, name.c_str());
    if (!mapping) return nullptr;

    void* view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size);
    if (!view) {
        CloseHandle(mapping);
        return nullptr;
    }

    auto region = std::shared_ptr<SharedRegion>(new SharedRegion(name, mapping, view));
    auto* header = region->header();
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

std::shared_ptr<SharedRegion> SharedRegion::open(const std::wstring& name) {
    HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, name.c_str());
    if (!mapping) return nullptr;

    const DWORD size = static_cast<DWORD>(sizeof(ipc::SharedAudio));
    void* view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size);
    if (!view) {
        CloseHandle(mapping);
        return nullptr;
    }

    auto region = std::shared_ptr<SharedRegion>(new SharedRegion(name, mapping, view));
    auto* header = region->header();
    if (header->magic != ipc::kMagic || header->version != ipc::kProtocolVersion ||
        header->maxSlots != ipc::kMaxSlots || header->transportFrames != ipc::kTransportFrames) {
        return nullptr;
    }
    return region;
}

} // namespace auradsp
