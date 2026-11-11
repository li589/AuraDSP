// null_ports.dart — 端口空实现（非该平台 / 单元测试 / 缺省注入）。
//
// 为什么放在 core：AppModel 等核心对象需要一组「永远安全」的缺省端口，
// 而 core 不允许 import platform/adapters（门禁 F11）。空实现只依赖
// platform/port 契约，不依赖任何具体平台实现。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import '../../platform/port/autostart.dart';
import '../../platform/port/media_session.dart';
import '../../platform/port/plugin_dirs.dart';
import '../../platform/port/plugin_host.dart';
import '../../platform/port/registry.dart';
import '../../platform/port/shell_open.dart';
import '../../platform/port/window.dart';
import '../../platform/port/windows_system.dart';
import '../media_track.dart';

final class NullPluginDirs implements PluginDirsPort {
  const NullPluginDirs();

  @override
  List<String> discover({Map<String, String>? env}) => const [];
}

final class NullPluginHost implements PluginHostPort {
  const NullPluginHost();

  @override
  PluginHostCapabilities get capabilities => PluginHostCapabilities.none;
}

final class NullRegistry implements RegistryPort {
  const NullRegistry();

  @override
  bool get available => false;

  @override
  bool keyExists(String keyPath) => false;

  @override
  String? readString(String keyPath, String valueName) => null;

  @override
  List<String> readStringValues(
    String keyPath, {
    String? valueName,
    bool recursive = true,
  }) =>
      const [];

  @override
  bool writeString(String keyPath, String valueName, String value) => false;

  @override
  int? readDword(String keyPath, String valueName) => null;

  @override
  bool writeDword(String keyPath, String valueName, int value) => false;

  @override
  bool deleteValue(String keyPath, String valueName) => false;
}

final class NullAutoStart implements AutoStartPort {
  const NullAutoStart();

  @override
  bool get available => false;

  @override
  bool? get enabled => null;

  @override
  ValueListenable<bool> get enabledListenable => _alwaysFalse;

  static final ValueNotifier<bool> _alwaysFalse = ValueNotifier<bool>(false);

  @override
  bool setEnabled(bool on) => false;
}

final class NullShellOpen implements ShellOpenPort {
  const NullShellOpen();

  @override
  Future<bool> openPath(String path) async => false;

  @override
  Future<bool> openUrl(String url) async => false;
}

final class NullWindowsSystem implements WindowsSystemPort {
  const NullWindowsSystem();

  ProcessResult _fail() => ProcessResult(0, 1, '', 'unsupported platform');

  @override
  bool get available => false;

  @override
  String? findRepoFile(List<String> relativeCandidates) => null;

  @override
  String? findInstalledFile(List<String> relativeCandidates) => null;

  @override
  Future<ProcessResult> inspectAudioDevices(String exePath) async => _fail();

  @override
  Future<ProcessResult> vaioDriver(
    String scriptPath, {
    required bool install,
    required bool elevated,
    bool bundled = false,
  }) async =>
      _fail();

  @override
  Future<ApoRunResult> asioDriverScript(
    String scriptPath, {
    required bool register,
    required bool elevated,
    bool bundled = false,
  }) async =>
      const ApoRunResult(exitCode: 1);

  @override
  Future<ProcessResult> apoStatus(String exePath, double timeout) async =>
      _fail();

  @override
  Future<ApoRunResult> apoInstall(
    String exePath, {
    required String target,
    required bool composite,
    required bool elevated,
  }) async =>
      const ApoRunResult(exitCode: 1);

  @override
  Future<ApoRunResult> apoUninstall(
    String exePath, {
    required String target,
    required bool elevated,
  }) async =>
      const ApoRunResult(exitCode: 1);
}

final class NullWindowPort implements WindowPort {
  final ValueNotifier<bool> _visible = ValueNotifier<bool>(true);

  @override
  ValueListenable<bool> get visibleListenable => _visible;

  @override
  bool get isVisible => _visible.value;

  @override
  void setVisible(bool visible) => _visible.value = visible;

  @override
  bool get supportsFullScreen => false;

  @override
  Future<void> setFullScreen(bool enabled) async {}

  @override
  Future<void> show() async {
    _visible.value = true;
  }

  @override
  Future<void> init({bool startInTray = false}) async {
    if (startInTray) _visible.value = false;
  }

  @override
  void setCloseToTray(bool value) {}

  @override
  Future<void> dispose() async {}

  @override
  void applyLocale(
    String localeTag,
    String showText,
    String autostartText,
    String quitText,
  ) {}
}

final class NullMediaSessionProvider implements MediaSessionProvider {
  final StreamController<MediaTrackMetadata> _controller =
      StreamController<MediaTrackMetadata>.broadcast();

  @override
  Stream<MediaTrackMetadata> get trackStream => _controller.stream;

  @override
  void start() {}

  @override
  void stop() {}

  @override
  void dispose() {
    if (!_controller.isClosed) _controller.close();
  }
}

final class NullMediaSession implements MediaSessionPort {
  const NullMediaSession();

  @override
  bool get supported => false;

  @override
  MediaSessionProvider create() => NullMediaSessionProvider();
}
