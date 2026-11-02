#pragma once

#include "plugin_ipc_protocol.h"

#if defined(_WIN32)
#include <windows.h>
#endif

#include <memory>
#include <string>

namespace auradsp {

class SharedRegion {
public:
    ~SharedRegion();

    SharedRegion(const SharedRegion&) = delete;
    SharedRegion& operator=(const SharedRegion&) = delete;

    // 名称类型按平台：Windows 为宽串（命名内核对象），POSIX 为
    // shm_open 名称（窄串，以 / 开头）。实现分处 win32/host 与
    // posix/host 两个 plugin_shared_region*.cpp，类接口一致。
#if defined(_WIN32)
    using Name = std::wstring;
#else
    using Name = std::string;
#endif
    static std::shared_ptr<SharedRegion> create(const Name& name);
    static std::shared_ptr<SharedRegion> open(const Name& name);

    ipc::SharedAudio* header() const {
        return static_cast<ipc::SharedAudio*>(m_view);
    }
    bool valid() const { return m_view != nullptr; }
    const Name& name() const { return m_name; }

private:
#if defined(_WIN32)
    SharedRegion(Name name, HANDLE mapping, void* view)
        : m_name(std::move(name)), m_mapping(mapping), m_view(view) {}
    HANDLE m_mapping = nullptr;
#else
    SharedRegion(Name name, int fd, void* view)
        : m_name(std::move(name)), m_fd(fd), m_view(view) {}
    int m_fd = -1;
#endif

    Name m_name;
    void* m_view = nullptr;
};

} // namespace auradsp
