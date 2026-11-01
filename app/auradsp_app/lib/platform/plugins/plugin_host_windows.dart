// plugin_host_windows.dart — Windows 插件宿主能力（现有独立宿主进程）。
//
// 真实扫描/挂载/编辑器仍由引擎侧 56 符号 ABI 提供；本文件只声明能力，
// 为 A6-2/A6-3 的 PluginHostPort 方法扩展预留唯一落点。
import '../port/plugin_host.dart';

final class WindowsPluginHost implements PluginHostPort {
  const WindowsPluginHost();

  @override
  PluginHostCapabilities get capabilities =>
      PluginHostCapabilities.win32Process;
}
