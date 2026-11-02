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

  /// 引擎进程内宿主（Linux 二期阶段一/二，2026-11-02）：插件在
  /// 引擎进程内加载（AURADSP_HOST_INPROC）；进程外双宿主
  /// （plugin_host_x64/x86）由后续阶段接入后切换。
  inProcess,
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

  /// Linux 进程内宿主：扫描/挂载可用；编辑器 GUI（X11 嵌入）为
  /// 后续独立阶段，canEdit 如实为 false。
  static const PluginHostCapabilities linuxInProcess =
      PluginHostCapabilities(
    supported: true,
    canScan: true,
    canMount: true,
    canEdit: false,
    runtime: PluginHostRuntime.inProcess,
  );
}

abstract interface class PluginHostPort {
  PluginHostCapabilities get capabilities;
}
