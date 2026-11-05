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

  /// Linux 进程内宿主（无显示环境）：扫描/挂载可用；编辑器需要
  /// X 显示，无 DISPLAY 时 canEdit 如实为 false。
  static const PluginHostCapabilities linuxInProcess =
      PluginHostCapabilities(
    supported: true,
    canScan: true,
    canMount: true,
    canEdit: false,
    runtime: PluginHostRuntime.inProcess,
  );

  /// Linux 进程内宿主（有 X 显示）：编辑器 GUI 已落地（X11 顶层
  /// 容器窗口，2026-11-04 编辑器阶段），canEdit 为 true。DISPLAY
  /// 存在只说明有 X 服务器可达；个别插件编辑器打开失败时引擎
  /// 侧仍会干净降级（showEditor 返回失败、UI 提示）。
  static const PluginHostCapabilities linuxInProcessWithEditor =
      PluginHostCapabilities(
    supported: true,
    canScan: true,
    canMount: true,
    canEdit: true,
    runtime: PluginHostRuntime.inProcess,
  );
}

abstract interface class PluginHostPort {
  PluginHostCapabilities get capabilities;
}
