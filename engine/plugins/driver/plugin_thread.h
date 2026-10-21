#pragma once
// 插件宿主线程角色。CLAP 的 thread-check 扩展据此回答 main/audio，
// 但角色本身是通用概念，driver 不因此依赖 CLAP SDK。

namespace auradsp {

enum class PluginThreadRole {
    Main,
    Audio
};

extern thread_local PluginThreadRole t_pluginThreadRole;

} // namespace auradsp
