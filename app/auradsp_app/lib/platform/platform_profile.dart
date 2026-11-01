// platform_profile.dart —— App 侧平台查询的**唯一**落点（M4）。
//
// 方案：docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md §10。
// 规则（门禁 test/smoke/smoke_dart_platform_quarantine.py）：
//   `Platform.is*` 只允许出现在 lib/platform/ 内；业务文件一律经本文件查询。
//
// 本文件只读环境与编译期常量，无 IO 副作用，可安全被 UI / isolate 引用。
import 'dart:io';

abstract final class PlatformProfile {
  /// 归一化平台标识：windows / android / linux / macos / other。
  static String get os {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'other';
  }

  /// Windows 原生组件（VAIO/ASIO 驱动、APO、桥）可用。
  /// 取代 state_audio_modes.dart 的 9 处 `Platform.isWindows` 守卫。
  static bool get isLinux => Platform.isLinux;

  static bool get supportsBridges => Platform.isWindows;

  /// VST3/CLAP 插件宿主管线可用（Windows 先行；其它平台后续独立立项）。
  static bool get supportsPlugins => Platform.isWindows;

  /// 本地设备泵循环（AudioOut）可用。
  /// R4（M6 审查遗留）：与实现保持一致——Windows 走 WASAPI，Linux 走
  /// PulseAudio simple API（`audio_out_linux.dart`，S3 / ADR-012 D-6 起），
  /// `createAudioOut()` 工厂按 OS 分派，两边能力位与实现一致。
  static bool get supportsLocalDevice =>
      Platform.isWindows || Platform.isLinux;

  /// 是否支持系统桌面窗口管理与真全屏切换。
  static bool get supportsWindowManagement =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 配置根目录（Windows: %APPDATA%/AuraDSP；Linux: XDG，见下；其它:
  /// ~/.config/auradsp）。
  ///
  /// Linux 按 XDG Base Directory 规范（S5b）：`$XDG_CONFIG_HOME/auradsp`，
  /// 未设时 `~/.config/auradsp`。XDG 变量为相对路径时按规范忽略。
  /// `$HOME` 缺失时回退系统临时目录——旧实现回退 `'.'` 会把配置散落到
  /// 进程工作目录（方案 §S5b 登记的问题），不再复现。
  static String get configDir {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      return appData != null
          ? '$appData${Platform.pathSeparator}AuraDSP'
          : 'AuraDSP';
    }
    final sep = Platform.pathSeparator;
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_CONFIG_HOME'];
      if (xdg != null && xdg.startsWith('/')) {
        return [xdg, 'auradsp'].join(sep);
      }
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return [Directory.systemTemp.path, 'auradsp'].join(sep);
    }
    return [home, '.config', 'auradsp'].join(sep);
  }

  /// XDG 配置主目录本身（Linux: $XDG_CONFIG_HOME，未设时 ~/.config；
  /// HOME 缺失时为系统临时目录）。autostart 等需要在 auradsp 子目录
  /// 之外落点的场景用它与 [configDir] 保持同源规则；非 Linux 返回
  /// [configDir]（其它平台无此概念，调用方只在 Linux 使用）。
  static String get xdgConfigHome {
    if (!Platform.isLinux) return configDir;
    final sep = Platform.pathSeparator;
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.startsWith('/')) return xdg;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return Directory.systemTemp.path;
    return [home, '.config'].join(sep);
  }

  /// 用户数据根目录（预设 / 会话 / 插件数据 / 脚本库等，S5b XDG 拆分）。
  ///
  /// Linux: `$XDG_DATA_HOME/auradsp`，未设时 `~/.local/share/auradsp`；
  /// 其它平台与 [configDir] 相同（Windows 历史布局不变）。拆分前 Linux
  /// 存量数据由 ConfigManager 首次访问时迁移（见 core/config.dart）。
  static String get dataDir {
    if (!Platform.isLinux) return configDir;
    final sep = Platform.pathSeparator;
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.startsWith('/')) {
        return [xdg, 'auradsp'].join(sep);
      }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return [Directory.systemTemp.path, 'auradsp'].join(sep);
    }
    return [home, '.local', 'share', 'auradsp'].join(sep);
  }

  /// 当前可执行文件所在目录（安装目录；资源探测的基线）。
  static String get executableDir => File(Platform.resolvedExecutable).parent.path;

  /// 是否运行在 `flutter test` 沙箱（测试进程自带 FLUTTER_TEST=true）。
  static bool get isTestRun => Platform.environment['FLUTTER_TEST'] == 'true';

  /// 比较用路径键：Windows 大小写不敏感，其余平台保留原样。
  static String pathKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  /// 路径输入框占位示例。
  static String pathPlaceholder({
    required bool directory,
    String? extension,
  }) {
    if (Platform.isWindows) {
      return directory
          ? r'C:\Path\To\Folder'
          : 'C:\\Path\\To\\file.${extension ?? 'ext'}';
    }
    return directory
        ? '/path/to/folder'
        : '/path/to/file.${extension ?? 'ext'}';
  }

  /// 引擎库候选（按加载顺序）。Windows 清单与 M3 前逐项一致。
  static List<String> get engineLibraryCandidates {
    if (Platform.isWindows) {
      return const [
        'auradsp_engine.dll', // exe 旁（bundle root）
        'engine\\auradsp_engine.dll', // engine/ 子目录
        'build\\windows\\x64\\runner\\Release\\auradsp_engine.dll', // 桌面 Release 构建产物
        'build\\windows\\x64\\runner\\Debug\\auradsp_engine.dll', // 桌面 Debug 构建产物
        '..\\..\\core\\desktop\\windows\\out\\Release\\auradsp_engine.dll', // 单测 CWD (app/auradsp_app)
        'core\\desktop\\windows\\out\\Release\\auradsp_engine.dll', // 仓库根目录 CWD
      ];
    }
    if (Platform.isLinux) {
      return const [
        'libauradsp_engine.so', // 裸名：dlopen 经 runner/lib 的 RPATH 命中 bundle lib/
        'lib/libauradsp_engine.so', // bundle 根为 CWD 时的 lib/ 子目录
        'engine/libauradsp_engine.so',
        'build/linux/x64/release/bundle/lib/libauradsp_engine.so',
        '../../core/desktop/linux/out/Release/libauradsp_engine.so', // 单测 CWD (app/auradsp_app)
        'core/desktop/linux/out/Release/libauradsp_engine.so', // 仓库根目录 CWD
      ];
    }
    if (Platform.isMacOS) {
      return const [
        'auradsp_engine.dylib',
        'engine/auradsp_engine.dylib',
      ];
    }
    return const [];
  }

  /// 桥产品名（不含扩展名）。
  static const Map<String, String> _bridgeBaseNames = {
    'vm': 'auravm_bridge',
    'asio': 'auraasio_bridge',
    'vaio': 'auravaio_bridge',
  };

  /// 桥 DLL 覆盖环境变量（Windows 现状；跨平台沿用同名变量）。
  static const Map<String, String> _bridgeEnvVars = {
    'vm': 'AURADSP_VB_BRIDGE_DLL',
    'asio': 'AURADSP_ASIO_BRIDGE_DLL',
    'vaio': 'AURADSP_VAIO_BRIDGE_DLL',
  };

  /// 桥库文件名（按平台扩展名）。未知 id 返回空串。
  static String bridgeLibraryName(String id) {
    final base = _bridgeBaseNames[id];
    if (base == null) return '';
    if (Platform.isWindows) return '$base.dll';
    if (Platform.isMacOS) return 'lib$base.dylib';
    return 'lib$base.so';
  }

  /// 桥库覆盖环境变量名。未知 id 返回空串。
  static String bridgeEnvVar(String id) => _bridgeEnvVars[id] ?? '';

  /// 桥库候选路径（按加载顺序）。Windows 清单与 M4 前逐项一致。
  static List<String> bridgeLibraryCandidates(String id) {
    final name = bridgeLibraryName(id);
    if (name.isEmpty) return const [];
    return [name, Platform.isWindows ? 'engine\\$name' : 'engine/$name'];
  }
}
