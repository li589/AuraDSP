// plugin_host_linux.dart — Linux 插件宿主能力（进程内，二期阶段二）。
//
// 引擎提供完整扫描/挂载通路（进程内 + 进程外双宿主由引擎侧按
// 环境分派）；真实扫描/挂载仍由引擎 56 符号 ABI 提供，本文件只
// 声明能力。编辑器（2026-11-04 编辑器阶段落地，X11 容器窗口）
// 需要 X 显示：DISPLAY 非空时 canEdit=true；无显示（纯 Wayland
// 无 XWayland、SSH 无转发等）时如实 false。
import 'dart:io';

import '../port/plugin_host.dart';

final class LinuxPluginHost implements PluginHostPort {
  const LinuxPluginHost();

  @override
  PluginHostCapabilities get capabilities {
    final display = Platform.environment['DISPLAY'];
    final hasDisplay = display != null && display.isNotEmpty;
    return hasDisplay
        ? PluginHostCapabilities.linuxInProcessWithEditor
        : PluginHostCapabilities.linuxInProcess;
  }
}
