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
 *
 * 【2026-11-10 业主裁定变更】管线模式全接线推翻了上款对管线
 * 输入侧的适用：管线输入 WASAPI 的回录捕获链（进程内本地链）
 * 正式接线为受支持链路（见 composeChain）；「不再上新功能」
 * 只余对 sysapo/附加范式的约束。管线合成规则以 composeChain
 * 为唯一真相：输入第一次参与合成，切换输入即驱动链路起停。
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

  /// 管线链路合成（全接线，2026-11-10 业主裁定）：输入第一次
  /// 参与合成——链路由（输入, 输出）共同决定，切换任一端都
  /// 必须重估链路（state 的 applyPipelineChain 是唯一下发方）。
  ///
  /// 规则（桥自带双端，输入选择从属于桥）：
  /// - 输出 ASIO 客户端 或 输入 ASIO 驱动 -> asio 桥链；
  /// - 输入 VAIO -> vaio 桥链（环的消费方只有 VAIO 桥）；
  /// - 输入 WASAPI + 输出 WASAPI -> capture 本地捕获链
  ///   （回录/直采 -> 本地引擎 -> 指定输出端点）；
  /// - 输入 WASAPI + 输出 VAIO -> vaio 桥链（桥不接受外源
  ///   注入；播放器须改投 VAIO 端点，面板指引已有此口径）；
  /// - 其余/未知 -> vaio 桥链（历史默认）。
  static PipelineChain composeChain({
    required String input,
    required String output,
  }) {
    if (output == outputAsioClient || input == inputAsioDriver) {
      return PipelineChain.asio;
    }
    if (input == inputVaio) return PipelineChain.vaio;
    if (input == inputWasapi && output == outputWasapi) {
      return PipelineChain.capture;
    }
    return PipelineChain.vaio;
  }

  /// 模式切换时对 pipelineOutput 的覆写（非损口径，2026-11-09
  /// 真机报告 §2.1）：引擎模式与输出端是多对一映射（wasapi/vaio
  /// 输出同合成 vaio 模式），覆写只纠正与模式硬冲突的选择——
  /// asio 模式必须 ASIO 输出；vaio 模式下残留的 ASIO 选择降为
  /// VAIO；其余情况不得改动用户已选的兼容输出（历史上把
  /// wasapi 覆写成 vaio，输出分段控件被拖回中间项、需二次
  /// 点击才落位）。纯函数：setAudioMode 的 OS 归一化使
  /// AppModel 级 Windows 管线用例无法在 Linux CI 运行，本
  /// helper 即落位口径的可测接缝。
  static String pipelineOutputForMode(String mode, String current) {
    if (mode == 'asio') return outputAsioClient;
    if (mode == 'vaio') {
      return current == outputAsioClient ? outputVaio : current;
    }
    return outputWasapi;
  }

  /// 模式能力查表（Q0-7 定版）：sysapo 的 fileEffects/mcScript
  /// 为 false 是已上线口径（文件型效果自动关闭、MC 脚本不入
  /// 参数块）的能力化重述，非新限制。未知 id 回退本地链缺省。
  static ModeCaps capsFor(String mode) {
    switch (mode) {
      case 'sysapo':
        return const ModeCaps(
          pluginProcessing: PluginProcessing.apo,
          pluginEditors: PluginEditors.shadowInstance,
          pluginLiveMeters: false,
          routeSelector: false,
          fileEffects: false,
          mcScript: false,
          chainVizLive: true,
        );
      case 'vbcallback':
      case 'voicemeeter_api':
        return const ModeCaps(
          pluginProcessing: PluginProcessing.local,
          pluginEditors: PluginEditors.liveInstance,
          pluginLiveMeters: true,
          routeSelector: true,
          fileEffects: true,
          mcScript: true,
          chainVizLive: true,
        );
      default:
        return ModeCaps.localDefault;
    }
  }
}

/// 插件处理位置（ModeCaps.pluginProcessing）。
enum PluginProcessing { local, apo, none }

/// 插件编辑器形态（ModeCaps.pluginEditors）：liveInstance =
/// 编辑器开在发声实例上；shadowInstance = 编辑器开在 App 侧
/// 影子实例上（发声在 APO 内），状态经收获/发布同步。
enum PluginEditors { liveInstance, shadowInstance, none }

/// 模式能力模型（Part I Q0-7 定版，2026-11-10）：功能层只问
/// 能力、不再写模式字符串判断。随模式变化的能力才进本表；
/// 故障旁路的呈现与恢复语义与模式无关、不进本表（计划书
/// I.4——那是槽状态 fault 字段在插件栈一处的决定）。
class ModeCaps {
  final PluginProcessing pluginProcessing;
  final PluginEditors pluginEditors;

  /// 插件槽实时表头（inRms/outRms）是否有实时来源。
  final bool pluginLiveMeters;

  /// VB 路线选择类 UI（插件页路线下拉、频谱仪总线行）。
  final bool routeSelector;

  /// 依赖外部文件的效果（卷积 IR / DDC）是否可用。
  final bool fileEffects;

  /// 多声道 EEL 脚本级是否可用。
  final bool mcScript;

  /// 处理链可视化是否有实时来源。
  final bool chainVizLive;

  const ModeCaps({
    required this.pluginProcessing,
    required this.pluginEditors,
    required this.pluginLiveMeters,
    required this.routeSelector,
    required this.fileEffects,
    required this.mcScript,
    required this.chainVizLive,
  });

  /// 本地链缺省能力（未知/新模式的回退：与历史行为一致）。
  static const ModeCaps localDefault = ModeCaps(
    pluginProcessing: PluginProcessing.local,
    pluginEditors: PluginEditors.liveInstance,
    pluginLiveMeters: true,
    routeSelector: false,
    fileEffects: true,
    mcScript: true,
    chainVizLive: true,
  );
}

/// 管线链路种类（composeChain 的产出）：vaio/asio 为桥链，
/// capture 为本地捕获链（进程内引擎 + WASAPI 捕获源 +
/// 指定端点输出）。capture 不是 audioMode id——模式簿记仍由
/// composeMode 产出（vaio），链路是管线类别内的子状态，由
/// isolate 的 capturestatus 事件回填。
enum PipelineChain { vaio, asio, capture }

/// Linux 三模式卡的提示决策（打磨二期，纯逻辑可单测）。
///
/// 把 isolate 回推的状态（失败 note + 旗标）收敛为一个提示 id，
/// UI 层只做 id 到 l10n 文案的映射。优先级（高到低）：
///   1. isolate 的具体失败 note（`note:<token>`）——原因最具体，
///      优先于一切派生提示；snd-aloop-not-loaded 归入
///      driver-missing（已有专门文案）；未知 token 不拦截，
///      落到派生逻辑，防协议演进时提示空白；
///   2. driver 模式且模块未加载 -> driver-missing；
///   3. virtual 模式且系统默认输出就是虚拟 sink -> feedback-warning
///      （采集的正是它的 monitor，处理结果又写回它 = 反馈环）；
///   4. virtual/driver 且采集未建立 -> capture-inactive（排在
///      virtual-ready 之前：sink 在位但采集没起来时报「就绪」
///      是误导，打磨二期顺序修正）；
///   5. 非 virtual 模式且默认输出是虚拟 sink -> output-to-virtual
///      （处理结果会被送进虚拟设备、本机听不见）；
///   6. virtual 且 sink 在位 -> virtual-ready（接入指引）；
///   7. 其余 -> ''（无提示）。
String linuxModeHintId({
  required String mode,
  required String note,
  required bool driverLoaded,
  required bool captureActive,
  required bool virtualSinkPresent,
  required bool defaultIsVirtual,
}) {
  const knownNotes = {
    'virtual-sink-unavailable',
    'loopback-source-unavailable',
    'alsa-capture-unavailable',
    'pulse-unavailable',
    'capture-lost',
  };
  if (knownNotes.contains(note)) return 'note:$note';
  if (note == 'snd-aloop-not-loaded') return 'driver-missing';
  if (mode == 'driver' && !driverLoaded) return 'driver-missing';
  if (mode == 'virtual' && defaultIsVirtual) return 'feedback-warning';
  if ((mode == 'virtual' || mode == 'driver') && !captureActive) {
    return 'capture-inactive';
  }
  if (mode != 'virtual' && defaultIsVirtual) return 'output-to-virtual';
  if (mode == 'virtual' && virtualSinkPresent) return 'virtual-ready';
  return '';
}
