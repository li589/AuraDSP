#pragma once

/*
 * plugin_host_command.h — 平台无关的插件宿主控制命令层（审计 R-07）。
 *
 * Win32（命名管道）与 POSIX（Unix domain socket）宿主主程序此前各自维护一份
 * 完全相同的「读请求 → 校验协议 → Op 分发 → 写响应」实现，新增 IPC 命令
 * 必须双改，漏改即平台能力不等。本层收口这一段：
 *   - 传输原语以 HostTransport 回调注入（ReadFile/WriteFile 或 recv/send）；
 *   - 深扫元数据查询以 MetadataQueryFn 注入（Win32 走 SEH 兜底版本）。
 * 父进程看门狗、音频唤醒、实时调度等平台原语仍留在各自主程序。
 */

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "plugin_host.h"
#include "plugin_ipc_protocol.h"

namespace auradsp {
namespace ipc {

struct HostTransport {
    void* user = nullptr;
    bool (*read)(void* user, void* data, size_t size) = nullptr;
    bool (*write)(void* user, const void* data, size_t size) = nullptr;
};

/* 深扫元数据查询钩子：Win32 传入带 SEH 兜底的版本（插件 AV 只废掉本候选），
 * POSIX 传入 queryMetadataDirect（无进程内隔离，崩溃由客户端超时重启兜底）。 */
using MetadataQueryFn = bool (*)(const std::string& path,
                                 std::vector<RemotePluginInfo>& out);

/* 格式无关的元数据查询：交给驱动自己产出，不建实例、不占槽。 */
bool queryMetadataDirect(const std::string& path,
                         std::vector<RemotePluginInfo>& out);

/* 元数据 → 跨进程条目（两条平台路径的唯一定义处）。 */
void fillRemoteInfo(const PluginMetadata& meta, const PluginBusInfo& bus,
                    RemotePluginInfo& info);

/* 处理一条命令（读请求 → 分发 → 写响应）。
 * 返回 false 表示传输失败或协议致命错误，调用方应结束命令循环。 */
bool handleHostCommand(const HostTransport& transport,
                       PluginHostManager& manager,
                       MetadataQueryFn queryMetadata,
                       bool& running);

} // namespace ipc
} // namespace auradsp
