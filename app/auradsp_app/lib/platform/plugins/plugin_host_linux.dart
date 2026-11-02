// plugin_host_linux.dart — Linux 插件宿主能力（进程内，二期阶段二）。
//
// 引擎以 AURADSP_HOST_INPROC 在进程内提供完整扫描/挂载通路
// （《Linux插件宿主实施方案-2026-11-02》阶段一已落地）；真实
// 扫描/挂载仍由引擎 56 符号 ABI 提供，本文件只声明能力。
// 进程外双宿主（plugin_host_x64/x86）接入后在此切换 runtime。
import '../port/plugin_host.dart';

final class LinuxPluginHost implements PluginHostPort {
  const LinuxPluginHost();

  @override
  PluginHostCapabilities get capabilities =>
      PluginHostCapabilities.linuxInProcess;
}
