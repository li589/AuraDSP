/*
 * audio_modes.dart — 音频处理模式（后端）模型
 *
 * 各平台可选 id（与 Windows 驱动四模式方案对齐；Linux/macOS 暂定）：
 * - windows: vaio（AuraVAIO 虚拟声卡）, vbcallback（Voicemeeter 回调）,
 *   sysapo（System APO）, asio（专业 ASIO）
 * - android: root, rootless（暂定）
 * - linux/macos: system, virtual, driver（暂定，后续按平台细化）
 * - 其他: auto（跟随当前引擎行为）
 *
 * 本文件纯 Dart（只依赖 dart:io），可单测；label 由 UI 层经 l10n 映射。
 * 接线现状（2026-10-15）：vbcallback/asio 活切；进程内采样率经 isolate 重启
 * 即时生效；vaio/sysapo 选择仅持久化（VAIO 驱动点亮后接线）。
 * 方向锁定：WASAPI 渲染最终只收敛于 AuraVAIO 模式，sysapo 回归纯配置面；
 * 进程内链路是过渡形态，不再上新功能。
 */
import 'dart:io' show Platform;

abstract final class AudioModes {
  static const List<String> windows = [
    'vaio',
    'vbcallback',
    'sysapo',
    'asio',
  ];
  static const List<String> android = ['root', 'rootless'];
  static const List<String> linux = ['system', 'virtual', 'driver'];
  static const List<String> macos = ['system', 'virtual', 'driver'];
  static const List<String> fallback = ['auto'];

  static const Map<String, String> defaults = {
    'windows': 'sysapo',
    'android': 'rootless',
    'linux': 'system',
    'macos': 'system',
  };

  static String currentOs() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'other';
  }

  static List<String> optionsFor(String os) {
    switch (os) {
      case 'windows':
        return windows;
      case 'android':
        return android;
      case 'linux':
        return linux;
      case 'macos':
        return macos;
      default:
        return fallback;
    }
  }

  static String defaultFor(String os) => defaults[os] ?? 'auto';

  /// 归一化存量值：未知 id 回退平台默认，保证 UI 总有合法选中项。
  static String normalize(String? id, [String? os]) {
    final o = os ?? currentOs();
    final opts = optionsFor(o);
    if (id != null && opts.contains(id)) return id;
    return defaultFor(o);
  }
}
