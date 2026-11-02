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
import '../platform/platform_profile.dart';

abstract final class AudioModes {
  // ADR-009 两大交互范式
  static const String categoryAttachment = 'attachment';
  static const String categoryPipeline = 'pipeline';

  // 附加模式子项
  static const String attachSysApo = 'sysapo';
  static const String attachVoicemeeterApi = 'voicemeeter_api';

  // 管线模式输入端
  static const String inputWasapi = 'wasapi';
  static const String inputVaio = 'vaio';
  static const String inputAsioDriver = 'asio_driver';

  // 管线模式输出端
  static const String outputWasapi = 'wasapi';
  static const String outputVaio = 'vaio';
  static const String outputAsioClient = 'asio_client';

  static const List<String> categories = [
    categoryAttachment,
    categoryPipeline,
  ];

  static const List<String> attachmentOptions = [
    attachSysApo,
    attachVoicemeeterApi,
  ];

  static const List<String> pipelineInputOptions = [
    inputWasapi,
    inputVaio,
    inputAsioDriver,
  ];

  static const List<String> pipelineOutputOptions = [
    outputWasapi,
    outputVaio,
    outputAsioClient,
  ];

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

  static String currentOs() => PlatformProfile.os;

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
    if (id == 'voicemeeter_api') return 'vbcallback';
    return defaultFor(o);
  }

  /// 根据存量 audioMode 推断范式类别（ADR-009）
  static String categoryForMode(String mode) {
    switch (mode) {
      case 'sysapo':
      case 'vbcallback':
      case 'voicemeeter_api':
        return categoryAttachment;
      case 'vaio':
      case 'asio':
      default:
        return categoryPipeline;
    }
  }

  /// 将范式与细分项合成底层的 audioMode
  ///
  /// Windows 走 ADR-009 两范式合成（默认）。Linux（ADR-012 D-5）没有
  /// 范式分层、UI 直选三模式：传入 [os] = 'linux' 时，候选值
  /// （[attachmentMode] 优先、否则 [pipelineOut]）本身就是模式 id，
  /// 在三 id 内即产出、否则回落 Linux 默认——保证三个 Linux id
  /// 都能被合成路径产出（S5a 修复点：旧实现只产 Windows 四 id）。
  static String composeMode({
    required String category,
    String? attachmentMode,
    String? pipelineOut,
    String? os,
  }) {
    if (os == 'linux' || os == 'macos') {
      final candidate = attachmentMode ?? pipelineOut;
      final opts = optionsFor(os!);
      if (candidate != null && opts.contains(candidate)) return candidate;
      return defaultFor(os);
    }
    if (category == categoryAttachment) {
      if (attachmentMode == attachVoicemeeterApi || attachmentMode == 'vbcallback') {
        return 'vbcallback';
      }
      return 'sysapo';
    }
    if (pipelineOut == outputAsioClient || pipelineOut == 'asio') {
      return 'asio';
    }
    return 'vaio';
  }
}

