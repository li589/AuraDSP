#pragma once

#include "plugin_ipc_protocol.h"

#include <windows.h>

#include <memory>
#include <string>

namespace auradsp {

class SharedRegion {
public:
    ~SharedRegion();

    SharedRegion(const SharedRegion&) = delete;
    SharedRegion& operator=(const SharedRegion&) = delete;

    static std::shared_ptr<SharedRegion> create(const std::wstring& name);
    static std::shared_ptr<SharedRegion> open(const std::wstring& name);

    ipc::SharedAudio* header() const {
        return static_cast<ipc::SharedAudio*>(m_view);
    }
    bool valid() const { return m_view != nullptr; }
    const std::wstring& name() const { return m_name; }

private:
    SharedRegion(std::wstring name, HANDLE mapping, void* view)
        : m_name(std::move(name)), m_mapping(mapping), m_view(view) {}

    std::wstring m_name;
    HANDLE m_mapping = nullptr;
    void* m_view = nullptr;
};

} // namespace auradsp
