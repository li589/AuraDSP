// plugin_host.dart — 插件宿主能力端口（A6 跨平台基础治理）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md A6。
// 本阶段只暴露“宿主能力”，把 UI 从 `PlatformProfile.supportsPlugins`
// 的布尔假设解耦；扫描/挂载/编辑器方法在 A6-2/A6-3 接入真实宿主后追加。
enum PluginHostRuntime {
  /// 当前平台没有插件宿主运行时。
  none,

  /// Windows 独立宿主进程（现有 auradsp_plugin_host.exe）。
  win32Process,
}

class PluginHostCapabilities {
  final bool supported;
  final bool canScan;
  final bool canMount;
  final bool canEdit;
  final PluginHostRuntime runtime;

  const PluginHostCapabilities({
    required this.supported,
    required this.canScan,
    required this.canMount,
    required this.canEdit,
    required this.runtime,
  });

  static const PluginHostCapabilities none = PluginHostCapabilities(
    supported: false,
    canScan: false,
    canMount: false,
    canEdit: false,
    runtime: PluginHostRuntime.none,
  );

  static const PluginHostCapabilities win32Process = PluginHostCapabilities(
    supported: true,
    canScan: true,
    canMount: true,
    canEdit: true,
    runtime: PluginHostRuntime.win32Process,
  );
}

abstract interface class PluginHostPort {
  PluginHostCapabilities get capabilities;
}
