// adapters.dart — 平台适配器组合根（按 PlatformProfile.os 装配端口实现）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// 允许的依赖方向：
//   UI/features → adapters（拿端口）
//   core → platform/port + platform_profile（只依赖契约，不依赖本文件）
// 门禁 F11 会拦截 core/ import 本文件。
import '../core/ports/null_ports.dart';
import '../core/selection/resource_picker.dart';
import 'autostart/autostart_windows.dart';
import 'dialogs/file_selector_dialog.dart';
import 'media/media_session_windows.dart';
import 'platform_profile.dart';
import 'plugins/plugin_dirs_desktop.dart';
import 'plugins/plugin_dirs_mobile.dart';
import 'plugins/plugin_dirs_windows.dart';
import 'plugins/plugin_host_windows.dart';
import 'port/autostart.dart';
import 'port/media_session.dart';
import 'port/plugin_dirs.dart';
import 'port/plugin_host.dart';
import 'port/registry.dart';
import 'port/shell_open.dart';
import 'port/window.dart';
import 'port/windows_system.dart';
import 'registry/registry_windows.dart';
import 'shell/shell_open_desktop.dart';
import 'system/windows_system_tools.dart';
import 'tray/tray_service.dart';

final class PlatformAdapters {
  PlatformAdapters({
    required this.shell,
    required this.registry,
    required this.autoStart,
    required this.pluginDirs,
    required this.pluginHost,
    required this.mediaSession,
    required this.windowsSystem,
    required this.window,
    required this.picker,
  });

  final ShellOpenPort shell;
  final RegistryPort registry;
  final AutoStartPort autoStart;
  final PluginDirsPort pluginDirs;
  final PluginHostPort pluginHost;
  final MediaSessionPort mediaSession;
  final WindowsSystemPort windowsSystem;
  final WindowPort window;

  /// 「选择/打开」统一入口（对话框端口 + 校验 + 路径记忆）。
  final ResourcePicker picker;

  static PlatformAdapters? _instance;

  static PlatformAdapters get instance => _instance ??= _create();

  /// 单元测试注入假端口（传 null 恢复默认装配）。
  static void overrideForTest(PlatformAdapters? adapters) {
    _instance = adapters;
  }

  static PlatformAdapters _create() {
    final os = PlatformProfile.os;
    final isWindows = os == 'windows';
    final isDesktop = os == 'windows' || os == 'macos' || os == 'linux';

    final registry =
        isWindows ? const WindowsRegistry() : const NullRegistry();
    final dialog = const FileSelectorDialog();
    final autoStart = isWindows ? WindowsAutoStart() : const NullAutoStart();
    // 托盘单例同时是 WindowPort；自启端口注入，避免 tray ↔ adapters 循环。
    final window = TrayService.instance..bindAutoStart(autoStart);

    return PlatformAdapters(
      shell: isDesktop
          ? const DesktopShellOpen()
          : const NullShellOpen(),
      registry: registry,
      autoStart: autoStart,
      pluginDirs: switch (os) {
        'windows' => WindowsPluginDirs(registry),
        'macos' || 'linux' => const DesktopPluginDirs(),
        _ => const MobilePluginDirs(),
      },
      pluginHost:
          isWindows ? const WindowsPluginHost() : const NullPluginHost(),
      mediaSession:
          isWindows ? const WindowsMediaSession() : const NullMediaSession(),
      windowsSystem: isWindows
          ? const WindowsSystemTools()
          : const NullWindowsSystem(),
      window: window,
      picker: ResourcePicker(dialog: dialog),
    );
  }
}
