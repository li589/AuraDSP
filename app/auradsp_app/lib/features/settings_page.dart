/*
 * settings_page.dart — 设置页：配色 / 语言 / 音频模式 / 设备 / 声道 /
 * 采样率 / 引擎信息 / 持久化记忆 / 测试音频源
 *
 * 一卡一节，序号贯通（测试卡无序号：纯测试工具，不计入设置序号）；
 * 说明文字统一挂在卡片标题下（hint），不再散落在控件之间。
 * 下设四类分区（外观/音频/系统/测试），底部选卡切换，序号跨类贯通不变。
 * 注：延迟档（ADR-002）已由 ADR-006 撤销，此处不再有「延迟模式」选项；
 *     延迟改为纯测量展示，见底栏徽标与效果页组件级徽标。
 * 音频模式与设备分卡：模式管后端选择，设备管当前设备展示与后续枚举。
 */
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/audio_modes.dart';
import '../core/config.dart';
import '../core/design.dart';
import '../core/path_memory.dart';
import '../core/session_memory.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import 'chrome.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  final AppModel model;
  const SettingsPage({super.key, required this.model});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // 当前分类：0 外观 / 1 音频 / 2 系统 / 3 测试（后续加类只改此处与 _CatBar）。
  int _cat = 1;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final l = l10nOf(context);
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        final all = <Widget>[
          // 01 配色
          SectionCard(
            index: '01',
            title: l.theme,
            child: Row(
              children: [
                Expanded(
                  child: _ThemeCard(
                    name: l.themeAuraDark,
                    selected: model.themeId == AuraThemeId.auraDark,
                    swatch: const [
                      Color(0xFF0E0F13),
                      Color(0xFF171A21),
                      Color(0xFFD4FF3F),
                    ],
                    onTap: () => model.setTheme(AuraThemeId.auraDark),
                  ),
                ),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: _ThemeCard(
                    name: l.themeAuraLight,
                    selected: model.themeId == AuraThemeId.auraLight,
                    swatch: const [
                      Color(0xFFF4F1EA),
                      Color(0xFFFFFFFF),
                      Color(0xFFE63B2E),
                    ],
                    onTap: () => model.setTheme(AuraThemeId.auraLight),
                  ),
                ),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: _ThemeCard(
                    name: l.themeAurora,
                    selected: model.themeId == AuraThemeId.aurora,
                    swatch: const [
                      Color(0xFF070B14),
                      Color(0xFF0D1522),
                      Color(0xFF64F0DC),
                    ],
                    onTap: () => model.setTheme(AuraThemeId.aurora),
                  ),
                ),
              ],
            ),
          ),
          // 02 语言
          SectionCard(
            index: '02',
            title: l.language,
            child: AuraSegmented<String>(
              segments: const [
                AuraSegment('zh', '简体中文'),
                AuraSegment('en', 'English'),
                AuraSegment('ja', '日本語'),
              ],
              selected: model.locale.languageCode,
              onChanged: (v) => model.setLocale(Locale(v)),
            ),
          ),
          // 03 音频范式与模式（ADR-009：附加模式原地挂载；普通管线模式端到端流转）
          SectionCard(
            index: '03',
            title: l.audioParadigm,
            hint: l.audioParadigmHint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一级：两大范式选择
                AuraSegmented<String>(
                  segments: [
                    AuraSegment(AudioModes.categoryAttachment, l.paradigmAttachment),
                    AuraSegment(AudioModes.categoryPipeline, l.paradigmPipeline),
                  ],
                  selected: model.modeCategory,
                  onChanged: (v) => model.setModeCategory(v),
                ),
                const SizedBox(height: AuraSpace.sm),
                // 第二级：细分形态
                if (model.modeCategory == AudioModes.categoryAttachment) ...[
                  Text(l.audioMode, style: labelOf(p, size: 12, color: p.textDim)),
                  const SizedBox(height: AuraSpace.xs),
                  AuraSegmented<String>(
                    segments: [
                      AuraSegment(AudioModes.attachSysApo, l.modeSysApo),
                      AuraSegment(AudioModes.attachVoicemeeterApi, l.modeVoicemeeterApi),
                    ],
                    selected: model.attachmentMode,
                    onChanged: (v) => model.setAttachmentMode(v),
                  ),
                ] else ...[
                  // 管线模式：输入端 + 输出端（上下文字对齐，带 InfoBadge 与 hover 气泡）
                  Tooltip(
                    message: l.pipelineInHint,
                    waitDuration: const Duration(milliseconds: 300),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l.pipelineIn, style: labelOf(p, size: 12, color: p.textDim)),
                        const SizedBox(width: AuraSpace.xs),
                        InfoBadge(message: l.pipelineInHint),
                      ],
                    ),
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  AuraSegmented<String>(
                    segments: [
                      AuraSegment(AudioModes.inputWasapi, l.inputWasapi,
                          tooltip: l.tooltipInputWasapi),
                      AuraSegment(AudioModes.inputVaio, l.inputVaio,
                          tooltip: l.tooltipInputVaio),
                      AuraSegment(AudioModes.inputAsioDriver, l.inputAsioDriver,
                          tooltip: l.tooltipInputAsioDriver),
                    ],
                    selected: model.pipelineInput,
                    onChanged: (v) => model.setPipelineInput(v),
                  ),
                  const SizedBox(height: AuraSpace.sm),
                  Tooltip(
                    message: l.pipelineOutHint,
                    waitDuration: const Duration(milliseconds: 300),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l.pipelineOut, style: labelOf(p, size: 12, color: p.textDim)),
                        const SizedBox(width: AuraSpace.xs),
                        InfoBadge(message: l.pipelineOutHint),
                      ],
                    ),
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  AuraSegmented<String>(
                    segments: [
                      AuraSegment(AudioModes.outputWasapi, l.outputWasapi,
                          tooltip: l.tooltipOutputWasapi),
                      AuraSegment(AudioModes.outputVaio, l.outputVaio,
                          tooltip: l.tooltipOutputVaio),
                      AuraSegment(AudioModes.outputAsioClient, l.outputAsioClient,
                          tooltip: l.tooltipOutputAsioClient),
                    ],
                    selected: model.pipelineOutput,
                    onChanged: (v) => model.setPipelineOutput(v),
                  ),
                ],
              ],
            ),
          ),
          // 04 设备与精细化调节（根据当前范式与配置动态展示）
          SectionCard(
            index: '04',
            title: l.audioDevice,
            child: _DynamicAudioPanel(model: model),
          ),
          // 05 声道模式（ADR-003 Phase A）
          SectionCard(
            index: '05',
            title: l.channelMode,
            hint: l.channelPhaseA,
            child: AuraSegmented<int>(
              segments: [
                AuraSegment(0, l.channelsStereo),
                AuraSegment(1, l.channels51),
                AuraSegment(2, l.channels71),
              ],
              selected: model.channelsMode,
              onChanged: (v) => model.setInt('channels.mode', v),
            ),
          ),
          // 06 采样率（发给设备的请求值；设备可回退原生值；桥模式跟对端走，
// 此时点选仅保存偏好，回进程内/下次建链生效——置灰反而让人以为坏了，保持可点）。
          SectionCard(
            index: '06',
            title: l.sampleRate,
            hint: (model.audioMode == 'vbcallback' ||
                    model.audioMode == 'asio')
                ? l.sampleRateFollowBridge
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AuraSegmented<int>(
                  segments: const [
                    AuraSegment(44100, '44100'),
                    AuraSegment(48000, '48000'),
                    AuraSegment(96000, '96000'),
                  ],
                  selected: model.config.sampleRate,
                  onChanged: (v) => model.setSampleRate(v),
                ),
              ],
            ),
          ),
          // 07 引擎信息
          SectionCard(
            index: '07',
            title: l.engineInfo,
            child: _EngineInfo(model: model),
          ),
          // 08 持久化记忆与外置配置
          SectionCard(
            index: '08',
            title: l.memTitle,
            hint: l.memHint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.memAutoRestore, style: labelOf(p)),
                    AuraSwitch(
                      value: model.config.autoRestoreSession,
                      onChanged: model.setAutoRestoreSession,
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Text(l.memDir(ConfigManager.baseDir),
                    style: monoOf(p, size: 10, color: p.textDim)),
                const SizedBox(height: AuraSpace.sm),
                Row(
                  children: [
                    AuraChip(
                      l.memClear,
                      icon: Icons.delete_outline_rounded,
                      onTap: () {
                        SessionMemory.clear();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(l.memCleared),
                          duration: Duration(milliseconds: 1400),
                        ));
                      },
                    ),
                    const SizedBox(width: AuraSpace.sm),
                    AuraChip(
                      l.memReset,
                      icon: Icons.restore_rounded,
                      onTap: () {
                        model.resetConfig();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(l.memResetDone),
                          duration: Duration(milliseconds: 1400),
                        ));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 测试音频源（无序号；测量用信号，停止后回到正式源）
          SectionCard(
            title: l.testSrcTitle,
            hint: l.testSrcHint,
            child: _TestSourceChips(model: model),
          ),
        ];
        // 按序号切片：[01,02] 外观 / [03,04,05,06] 音频 / [07,08] 系统 / [测试]。
        final cats = <List<Widget>>[
          [all[0], all[1]],
          [all[2], all[3], all[4], all[5]],
          [all[6], all[7]],
          [all[8]],
        ];
        final shown = [...cats[_cat.clamp(0, 3)], const SizedBox(height: 84)];
        return Stack(
          children: [
            PageScaffold(
              eyebrow: l.pageSettingsEyebrow,
              title: l.pageSettingsTitle,
              children: shown,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _CatBar(
                selected: _cat,
                labels: [l.catAppearance, l.catAudio, l.catSystem, l.catTest],
                onChanged: (v) => setState(() => _cat = v),
              ),
            ),
          ],
        );
      },
    );
  }
}

/* ---- 底部分类选卡（固定悬浮；点选切换设置分组） ---- */

class _CatBar extends StatelessWidget {
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  const _CatBar({
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  static const _icons = [
    Icons.color_lens_outlined,
    Icons.graphic_eq_rounded,
    Icons.memory_outlined,
    Icons.science_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + AuraSpace.xs,
          top: AuraSpace.xs),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: AuraSpace.xs + 2),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: i == selected ? p.accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_icons[i],
                          size: 19,
                          color: i == selected ? p.accent : p.textDim),
                      const SizedBox(height: 2),
                      Text(
                        labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: i == selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: i == selected ? p.text : p.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}



/* ---- 04 动态设备与精细化调节面板（ADR-009） ---- */

class _DynamicAudioPanel extends StatelessWidget {
  final AppModel model;
  const _DynamicAudioPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    // 1. 附加模式
    if (model.modeCategory == AudioModes.categoryAttachment) {
      if (model.attachmentMode == AudioModes.attachVoicemeeterApi) {
        return _VoicemeeterPanel(model: model);
      } else {
        return _SystemApoPanel(model: model);
      }
    }

    // 2. 管线模式：三层设备显示卡（驱动层、输入层、输出层）
    return _PipelineThreeLayerCard(model: model);
  }
}

class _VoicemeeterPanel extends StatelessWidget {
  final AppModel model;
  const _VoicemeeterPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final sr = model.vbInfo['sr'];
    final note = model.vbInfo['note'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.audioParadigm, '${l.paradigmAttachment} · ${l.modeVoicemeeterApi}'),
        _InfoRow('连接状态', model.vbActive ? '已连接 (活跃回调)' : (note is String && note.isNotEmpty ? note : '未连接 (等待 Voicemeeter 启动)')),
        if (sr is num) _InfoRow(l.sampleRate, '${sr.toInt()} Hz'),
        if (model.vbActive) _VbBuses(model: model),
      ],
    );
  }
}

/// 格式化离线/已断开设备的展示名称，避免给用户展示裸 GUID 或 Map.toString() 乱码
String _formatOfflineDeviceName(String idOrName, [List<AudioDeviceItem>? known]) {
  var s = idOrName.trim();
  if (s.isEmpty) return '未连接设备';
  // 防御 Map.toString() 残留（如 `{name: 扬声器, id: ...}`）
  if (s.startsWith('{') && s.contains('name:')) {
    final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(s);
    if (m != null) s = m.group(1)!.trim();
  }
  // 若在已知设备列表中有匹配项，直接采用其 friendlyName
  if (known != null) {
    for (final d in known) {
      if (d.id == s || d.name == s) {
        return d.friendlyName;
      }
    }
  }
  // 若是裸 GUID，截取简短端点代号
  if (s.startsWith('{0.0.') && s.length > 30) {
    final shortId = s.length >= 8 ? s.substring(s.length - 8, s.length - 1) : '端点';
    return '音频端点 ($shortId)';
  }
  return s;
}

/// 根据设备名称和类型推荐图标
IconData _getAudioDeviceIcon(String name, {required bool isRender}) {
  final lower = name.toLowerCase();
  if (!isRender) return Icons.mic_none_outlined;
  if (lower.contains('headphone') ||
      lower.contains('headset') ||
      lower.contains('耳机') ||
      lower.contains('耳麦')) {
    return Icons.headphones_outlined;
  }
  if (lower.contains('speaker') ||
      lower.contains('扬声器') ||
      lower.contains('喇叭')) {
    return Icons.speaker_outlined;
  }
  return Icons.volume_up_outlined;
}

class _SystemApoPanel extends StatelessWidget {
  final AppModel model;
  const _SystemApoPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final endpoints = model.vaioPhysicalEndpoints;
    final selEndpoint = model.apoTargetEndpoint;
    final matched = endpoints.cast<AudioDeviceItem?>().firstWhere(
        (e) => e?.name == selEndpoint || e?.id == selEndpoint,
        orElse: () => null);
    final selectedValue = matched != null
        ? matched.name
        : (selEndpoint.isEmpty ? '' : selEndpoint);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.audioParadigm, '${l.paradigmAttachment} · System APO'),
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.apoTargetEndpoint,
                  style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: AuraDropdown<String>(
                value: selectedValue,
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Row(
                      children: [
                        Icon(Icons.auto_mode_rounded,
                            size: 14,
                            color: selEndpoint.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '默认音频端点 (Default Render)',
                            style: TextStyle(
                              fontSize: 12,
                              color: selEndpoint.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selEndpoint.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: selEndpoint,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_formatOfflineDeviceName(selEndpoint, endpoints)} [离线/未连接]',
                              style: TextStyle(
                                fontSize: 12,
                                color: p.warning,
                                fontStyle: FontStyle.italic,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final ep in endpoints)
                    DropdownMenuItem<String>(
                      value: ep.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(ep.name, isRender: true),
                            size: 14,
                            color: (ep.name == selEndpoint || ep.id == selEndpoint)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ep.friendlyName,
                              style: TextStyle(
                                fontSize: 12,
                                color: (ep.name == selEndpoint || ep.id == selEndpoint)
                                    ? p.accent
                                    : p.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: endpoints.isEmpty ? '无可用音频端点' : null,
                onChanged: (v) {
                  if (v != null) model.setApoTargetEndpoint(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                onTap: () => model.refreshVaioDetect()),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.apoStatus, style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    model.apoAttached ? l.apoAttached : l.apoNotAttached,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: model.apoAttached ? p.accent : p.textDim,
                    ),
                  ),
                  if (model.apoHeartbeatAlive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.graphic_eq_rounded, size: 12, color: Colors.green),
                          const SizedBox(width: 4),
                          Text(
                            '活跃处理中 (${model.apoHeartbeatSr}Hz · ${model.apoHeartbeatFrames} 帧)',
                            style: const TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    )
                  else if (model.apoAttached)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.hourglass_top_rounded, size: 12, color: Colors.orange),
                          const SizedBox(width: 4),
                          const Text(
                            '已挂接 (等待播放流触发)',
                            style: TextStyle(fontSize: 10, color: Colors.orange),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (model.lastApoError != null) ...[
          const SizedBox(height: AuraSpace.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: p.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.error.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: p.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    model.lastApoError!,
                    style: TextStyle(fontSize: 12, color: p.error),
                  ),
                ),
                GestureDetector(
                  onTap: () => model.clearApoError(),
                  child: Icon(Icons.close, size: 14, color: p.error),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AuraSpace.sm),
        Wrap(
          spacing: AuraSpace.sm,
          runSpacing: AuraSpace.xs,
          children: [
            AuraChip(
              model.isApoOperating ? '处理中...' : l.apoActionAttach,
              icon: Icons.link,
              selected: model.apoAttached,
              onTap: model.isApoOperating
                  ? null
                  : () async {
                      final ok = await model.attachSystemApo();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? '已向目标设备注册 System APO 钩子并完成服务同步'
                              : (model.lastApoError ?? 'APO 附加未完成')),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
                    },
            ),
            AuraChip(
              model.isApoOperating ? '处理中...' : l.apoActionDetach,
              icon: Icons.link_off,
              danger: true,
              onTap: model.isApoOperating
                  ? null
                  : () async {
                      final ok = await model.detachSystemApo();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? '已安全卸载 APO 钩子并精确还原原始系统/厂商驱动'
                              : (model.lastApoError ?? 'APO 卸载未完成')),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
                    },
            ),
            AuraChip(
              '复合插槽',
              icon: model.apoCompositeMode ? Icons.layers_rounded : Icons.layers_outlined,
              selected: model.apoCompositeMode,
              onTap: () => model.setApoCompositeMode(!model.apoCompositeMode),
            ),
            AuraChip(
              '刷新状态',
              icon: Icons.refresh_rounded,
              onTap: () => model.checkApoStatus(),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, size: 13, color: p.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '注册表安全保护：所有变更均经 HKLM\\SOFTWARE\\AuraDSP\\Child APOs 及磁盘双层快照原子保护，卸载时 100% 还原原始驱动配置。',
                style: TextStyle(fontSize: 11, color: p.textDim, height: 1.3),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/* ---- 04 管线模式三层设备卡（ADR-009：驱动层 / 输入层 / 输出层） ---- */

class _PipelineThreeLayerCard extends StatelessWidget {
  final AppModel model;
  const _PipelineThreeLayerCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第一层：驱动的信息和按钮
        _DriverLayer(model: model),

        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),

        // 第二层：输入的信息和开关
        _InputLayer(model: model),

        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),

        // 第三层：输出的信息和开关
        _OutputLayer(model: model),
      ],
    );
  }
}

/* ---- 第一层：驱动的信息和控制 ---- */

class _DriverLayer extends StatelessWidget {
  final AppModel model;
  const _DriverLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    final widgets = <Widget>[];

    // 如果输出是 ASIO Client：显示专业 ASIO 驱动选择、缓冲档、输出声道对、刷新入口
    if (model.pipelineOutput == AudioModes.outputAsioClient) {
      widgets.add(_AsioClientDriverRow(model: model));
    }

    // 如果输入是虚拟 ASIO 驱动：显示 AuraDSP Virtual ASIO 驱动注册状态与 DAW 状态卡片
    if (model.pipelineInput == AudioModes.inputAsioDriver) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: AuraSpace.sm));
      }
      widgets.add(_VirtualAsioDriverCard(model: model));
    }

    // 如果输入或输出使用了 AuraVAIO：显示 AuraVAIO KMDF 虚拟声卡驱动状态
    if (model.pipelineInput == AudioModes.inputVaio ||
        model.pipelineOutput == AudioModes.outputVaio) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: AuraSpace.sm));
      }
      widgets.add(_VaioDriverRow(model: model));
    }

    // 如果输入和输出均为 WASAPI 标准模式：显示 Windows WASAPI 引擎状态与刷新
    if (model.pipelineInput == AudioModes.inputWasapi &&
        model.pipelineOutput == AudioModes.outputWasapi) {
      widgets.add(_WasapiDriverRow(model: model));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.developer_board_rounded, size: 15, color: p.accent),
            const SizedBox(width: AuraSpace.xs),
            Text(l.driverLayerTitle,
                style: sectionOf(p, color: p.text)),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        ...widgets,
      ],
    );
  }
}

class _AsioClientDriverRow extends StatelessWidget {
  final AppModel model;
  const _AsioClientDriverRow({required this.model});

  static const _bufSizes = [0, 64, 128, 256, 512, 1024, 2048];
  static const _outPairs = [0, 1, 2, 3];

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final drivers = model.asioDrivers;
    final names = [for (final d in drivers) d['name'] ?? ''];
    final curDriver = model.config.asioDriver;
    final sel = curDriver.isNotEmpty
        ? curDriver
        : (names.isNotEmpty ? names.first : '');
    final note = model.asioDriversNote;
    final info = model.asioInfo;

    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioDriver,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: names.isEmpty && curDriver.isEmpty
                  ? Text('—', style: monoOf(p, size: 12))
                  : AuraDropdown<String>(
                      value: sel,
                      items: [
                        if (curDriver.isNotEmpty && !names.contains(curDriver))
                          DropdownMenuItem<String>(
                            value: curDriver,
                            child: Text('$curDriver [未检测到/离线]',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: p.warning,
                                    fontStyle: FontStyle.italic),
                                overflow: TextOverflow.ellipsis),
                          ),
                        for (final n in names)
                          DropdownMenuItem<String>(
                            value: n,
                            child: Text(n,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: n == sel ? p.accent : p.text),
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      hint: '—',
                      onChanged: (v) {
                        if (v != null) model.setAsioDriver(v);
                      },
                    ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                onTap: () => model.refreshAsioDrivers()),
          ]),
          if (note.isNotEmpty) _InfoRow('ASIO', note),
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioBufSize,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: AuraDropdown<int>(
                value: _bufSizes.contains(model.config.asioBufSize)
                    ? model.config.asioBufSize
                    : 0,
                items: [
                  for (final b in _bufSizes)
                    DropdownMenuItem<int>(
                      value: b,
                      child: Text(
                          b == 0 ? l.asioBufAuto : '$b frames',
                          style: TextStyle(
                              fontSize: 12,
                              color: b == model.config.asioBufSize
                                  ? p.accent
                                  : p.text)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) model.setAsioBufSize(v);
                },
              ),
            ),
          ]),
          const SizedBox(height: AuraSpace.xs),
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioOutPair,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: AuraDropdown<int>(
                value: _outPairs.contains(model.config.asioOutPair)
                    ? model.config.asioOutPair
                    : 0,
                items: [
                  for (final n in _outPairs)
                    DropdownMenuItem<int>(
                      value: n,
                      child: Text('ch ${n * 2 + 1}/${n * 2 + 2}',
                          style: TextStyle(
                              fontSize: 12,
                              color: n == model.config.asioOutPair
                                  ? p.accent
                                  : p.text)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) model.setAsioOutPair(v);
                },
              ),
            ),
          ]),
          if (model.asioActive) ...[
            _InfoRow(l.asioSwitches, '${info['switches'] ?? 0}'),
            if (info['sr'] is num)
              _InfoRow(l.sampleRate,
                  '${(info['sr'] as num).toInt()} Hz / ${info['nbs'] ?? '?'} frames'),
            if ((info['dropouts'] as int? ?? 0) > 0)
              _InfoRow(l.asioDropouts, '${info['dropouts']}'),
            if ((info['latenciesChanged'] as int? ?? 0) == 1)
              _InfoRow('ASIO', l.asioLatChanged),
            if (info['sr'] is num &&
                (info['sr'] as num).toInt() != model.config.sampleRate)
              _InfoRow(
                  l.sampleRate,
                  l.asioSrMismatch('${(info['sr'] as num).toInt()}',
                      '${model.config.sampleRate}')),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onDismiss;
  const _ErrorBanner({required this.message, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      margin: const EdgeInsets.only(top: AuraSpace.xs + 2),
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.sm + 2, vertical: AuraSpace.xs + 2),
      decoration: BoxDecoration(
        color: p.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: p.error),
          const SizedBox(width: AuraSpace.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11.5, color: p.error),
            ),
          ),
          if (onDismiss != null)
            GestureDetector(
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 14, color: p.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _VaioDriverRow extends StatelessWidget {
  final AppModel model;
  const _VaioDriverRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final det = model.vaioDetectInfo;
    final found = det['found'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    found
                        ? 'AuraVAIO KMDF 驱动已就绪 (Sysvad 虚拟声卡)'
                        : '未检测到 AuraVAIO 虚拟声卡驱动',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: found ? p.success : p.warning,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'KMDF 内核模式虚拟音频驱动，提供全双工虚拟音频线缆通道',
                    style: monoOf(p, size: 10, color: p.textDim),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: AuraSpace.sm,
              children: [
                if (!found)
                  AuraChip(
                    'UAC提权安装驱动',
                    icon: Icons.admin_panel_settings,
                    selected: true,
                    onTap: () async {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('正在唤起 Windows UAC 授权弹窗，请在系统提示中点击“是”允许安装驱动...'),
                        duration: Duration(milliseconds: 2000),
                      ));
                      final ok = await model.installVaioDriver(elevated: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? 'AuraVAIO 驱动已成功安装并通过系统验收！'
                              : (model.lastVaioError ?? '驱动安装未完成')),
                          duration: const Duration(milliseconds: 2500),
                        ));
                      }
                    },
                  )
                else
                  AuraChip(
                    '卸载驱动',
                    icon: Icons.delete_outline,
                    danger: true,
                    onTap: () async {
                      final ok = await model.uninstallVaioDriver(elevated: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok ? 'AuraVAIO 驱动已成功卸载' : '卸载未完成'),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
                    },
                  ),
                AuraChip(
                  '重新检测',
                  icon: Icons.refresh_rounded,
                  onTap: () => model.refreshVaioDetect(),
                ),
              ],
            ),
          ],
        ),
        if (model.lastVaioError != null)
          _ErrorBanner(
            message: model.lastVaioError!,
            onDismiss: () => model.clearVaioError(),
          ),
      ],
    );
  }
}

class _WasapiDriverRow extends StatelessWidget {
  final AppModel model;
  const _WasapiDriverRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final info = model.info;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Windows CoreAudio WASAPI Engine',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    info != null
                        ? 'ABI v${info.abi} · ${info.version} · ${info.deviceRate}Hz'
                        : '系统底层 WASAPI 共享/独占音频引擎，无额外驱动依赖',
                    style: monoOf(p, size: 10, color: p.textDim),
                  ),
                ],
              ),
            ),
            AuraChip(
              '刷新设备',
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshAudioDevices(),
            ),
          ],
        ),
        if (model.lastAudioError != null)
          _ErrorBanner(
            message: model.lastAudioError!,
            onDismiss: () => model.clearAudioError(),
          ),
      ],
    );
  }
}

class _VirtualAsioDriverCard extends StatelessWidget {
  final AppModel model;
  const _VirtualAsioDriverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l.asioDriverCardTitle,
                style: sectionOf(p, color: p.text)),
            AuraChip(
              l.asioStatusCheck,
              icon: Icons.refresh_rounded,
              onTap: () => model.checkAsioDriverStatus(),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        _InfoRow(
          l.asioDriverStatus,
          model.asioDriverInstalled
              ? l.asioDriverRegistered
              : l.asioDriverNotRegistered,
        ),
        _InfoRow(
          l.asioDawStatus,
          model.asioActive ? l.asioDawConnected : l.asioDawIdle,
        ),
        const SizedBox(height: AuraSpace.sm),
        Wrap(
          spacing: AuraSpace.sm,
          children: [
            if (!model.asioDriverInstalled)
              AuraChip(
                'UAC提权注册驱动',
                icon: Icons.admin_panel_settings,
                selected: true,
                onTap: () async {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('正在唤起 Windows UAC 授权弹窗注册虚拟 ASIO 驱动...'),
                    duration: Duration(milliseconds: 1500),
                  ));
                  final ok = await model.registerAsioDriver(elevated: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok
                          ? '虚拟 ASIO 驱动注册成功！DAW 中现已可选'
                          : (model.lastAsioError ?? '注册失败，请使用管理员权限重试')),
                      duration: const Duration(milliseconds: 2500),
                    ));
                  }
                },
              )
            else
              AuraChip(
                l.asioDriverActionUnregister,
                icon: Icons.remove_circle_outline,
                danger: true,
                onTap: () async {
                  final ok = await model.unregisterAsioDriver(elevated: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? '虚拟 ASIO 驱动已从系统注销' : (model.lastAsioError ?? '注销失败，请使用管理员权限重试')),
                      duration: const Duration(milliseconds: 2000),
                    ));
                  }
                },
              ),
          ],
        ),
        if (model.lastAsioError != null)
          _ErrorBanner(
            message: model.lastAsioError!,
            onDismiss: () => model.clearAsioError(),
          ),
      ],
    );
  }
}


/* ---- 第二层：输入的信息和开关 ---- */

class _InputLayer extends StatelessWidget {
  final AppModel model;
  const _InputLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final enabled = model.pipelineInputEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.input_rounded, size: 15, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Text(l.inputLayerTitle,
                    style: sectionOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.tooltipInputWasapi),
              ],
            ),
            AuraSwitch(
              value: enabled,
              onChanged: (v) => model.setPipelineInputEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        if (!enabled)
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              border: Border.all(color: p.hairline),
            ),
            child: Row(
              children: [
                Icon(Icons.mic_off_outlined, size: 15, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Text(
                    l.inputDisabledNotice,
                    style: captionOf(p, color: p.textDim),
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (model.pipelineInput == AudioModes.inputWasapi)
            _WasapiInputSubpanel(model: model)
          else if (model.pipelineInput == AudioModes.inputVaio)
            _VaioInputSubpanel(model: model)
          else
            _VirtualAsioInputSubpanel(model: model),
        ],
      ],
    );
  }
}

class _WasapiInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _WasapiInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final inputs = model.filteredWasapiInputs;
    final curDev = model.pipelineInputDevice;
    final matched = inputs.cast<AudioDeviceItem?>().firstWhere(
        (d) => d?.id == curDev || d?.name == curDev,
        orElse: () => null);
    final selectedValue = matched != null
        ? (matched.id.isNotEmpty ? matched.id : matched.name)
        : (curDev.isEmpty ? '' : curDev);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.inputDeviceLabel,
                  style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: AuraDropdown<String>(
                value: selectedValue,
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Row(
                      children: [
                        Icon(Icons.auto_mode_rounded,
                            size: 14,
                            color: curDev.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.defaultInputDevice,
                            style: TextStyle(
                              fontSize: 12,
                              color: curDev.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: curDev.isEmpty
                                ? p.accent.withValues(alpha: 0.15)
                                : p.hairline.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            l.tagLoopback,
                            style: TextStyle(
                              fontSize: 9,
                              color: curDev.isEmpty ? p.accent : p.textDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (curDev.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: curDev,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_formatOfflineDeviceName(curDev, inputs)} [离线/未连接]',
                              style: TextStyle(
                                fontSize: 12,
                                color: p.warning,
                                fontStyle: FontStyle.italic,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final item in inputs)
                    DropdownMenuItem<String>(
                      value: item.id.isNotEmpty ? item.id : item.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(item.name,
                                isRender: item.isRender),
                            size: 14,
                            color: (item.id == curDev || item.name == curDev)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.friendlyName,
                              style: TextStyle(
                                fontSize: 12,
                                color: (item.id == curDev || item.name == curDev)
                                    ? p.accent
                                    : p.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: (item.id == curDev || item.name == curDev)
                                  ? p.accent.withValues(alpha: 0.15)
                                  : p.hairline.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              item.isRender
                                  ? l.tagLoopback
                                  : l.tagRecording,
                              style: TextStyle(
                                fontSize: 9,
                                color: (item.id == curDev || item.name == curDev)
                                    ? p.accent
                                    : p.textDim,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: inputs.isEmpty ? '无可用输入设备' : null,
                onChanged: (v) {
                  if (v != null) model.setPipelineInputDevice(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(
              '刷新设备',
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshAudioDevices(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          curDev.isEmpty
              ? '默认内录/环回模式：实时采集系统主回放端点音频'
              : '针对指定硬件/虚拟端口进行低延迟 WASAPI 独占/共享采集',
          style: monoOf(p, size: 10, color: p.textDim),
        ),
      ],
    );
  }
}

class _VaioInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VaioInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final active = model.vaioActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow('输入端点', 'AuraVAIO 虚拟输入端点 (Stereo / 7.1 ch)'),
        _InfoRow('通道状态', active ? '活跃传输中 (全双工 DMA 环形缓冲)' : '就绪 (等待系统/应用推流)'),
        const SizedBox(height: 2),
        Text(
          '请在 Windows 声音设置或播放器中将默认输出选择为 "AuraVAIO"，声音将通过此虚拟输入端点送入 AuraDSP 核心管线处理。',
          style: monoOf(p, size: 10, color: p.textDim),
        ),
      ],
    );
  }
}

class _VirtualAsioInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VirtualAsioInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final active = model.asioActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow('输入端点', 'AuraDSP Virtual ASIO Client Stream'),
        _InfoRow('输入通道', active ? 'DAW 实时注入 (活跃)' : '等待 DAW 连接 (宿主未开启)'),
        const SizedBox(height: 2),
        Text(
          '在 DAW (FL Studio / Cubase / Reaper / Ableton) 的 Audio Device 中选择 "AuraDSP Virtual ASIO" 即可将工程音频路由至此。',
          style: monoOf(p, size: 10, color: p.textDim),
        ),
      ],
    );
  }
}

/* ---- 第三层：输出的信息和开关 ---- */

class _OutputLayer extends StatelessWidget {
  final AppModel model;
  const _OutputLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final enabled = model.pipelineOutputEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.output_rounded, size: 15, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Text(l.outputLayerTitle,
                    style: sectionOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.tooltipOutputWasapi),
              ],
            ),
            AuraSwitch(
              value: enabled,
              onChanged: (v) => model.setPipelineOutputEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        if (!enabled)
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              border: Border.all(color: p.hairline),
            ),
            child: Row(
              children: [
                Icon(Icons.volume_off_outlined, size: 15, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Text(
                    l.outputDisabledNotice,
                    style: captionOf(p, color: p.textDim),
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (model.pipelineOutput == AudioModes.outputWasapi)
            _WasapiOutputSubpanel(model: model)
          else if (model.pipelineOutput == AudioModes.outputVaio)
            _VaioOutputSubpanel(model: model)
          else
            _AsioClientOutputSubpanel(model: model),
        ],
      ],
    );
  }
}

class _WasapiOutputSubpanel extends StatelessWidget {
  final AppModel model;
  const _WasapiOutputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final outputs = model.filteredWasapiOutputs;
    final curDev = model.pipelineOutputDevice;
    final matched = outputs.cast<AudioDeviceItem?>().firstWhere(
        (d) => d?.id == curDev || d?.name == curDev,
        orElse: () => null);
    final selectedValue = matched != null
        ? (matched.id.isNotEmpty ? matched.id : matched.name)
        : (curDev.isEmpty ? '' : curDev);
    final info = model.info;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.outputWasapi, 'WASAPI 物理渲染 (扬声器/耳机)'),
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.outputDeviceLabel,
                  style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: AuraDropdown<String>(
                value: selectedValue,
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Row(
                      children: [
                        Icon(Icons.auto_mode_rounded,
                            size: 14,
                            color: curDev.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.defaultOutputDevice,
                            style: TextStyle(
                              fontSize: 12,
                              color: curDev.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (curDev.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: curDev,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_formatOfflineDeviceName(curDev, outputs)} [离线/未连接]',
                              style: TextStyle(
                                fontSize: 12,
                                color: p.warning,
                                fontStyle: FontStyle.italic,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final item in outputs)
                    DropdownMenuItem<String>(
                      value: item.id.isNotEmpty ? item.id : item.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(item.name, isRender: true),
                            size: 14,
                            color: (item.id == curDev || item.name == curDev)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.friendlyName,
                              style: TextStyle(
                                fontSize: 12,
                                color: (item.id == curDev || item.name == curDev)
                                    ? p.accent
                                    : p.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: outputs.isEmpty ? '无可用输出设备' : null,
                onChanged: (v) {
                  if (v != null) model.setPipelineOutputDevice(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(
              '刷新设备',
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshAudioDevices(),
            ),
          ],
        ),
        if (info != null) ...[
          _InfoRow(
              l.sampleRate, '${info.deviceRate} Hz / ${info.deviceCh} ch'),
          _InfoRow(l.buffer, '${info.bufferFrames} frames'),
          if (info.deviceRate != model.config.sampleRate)
            _InfoRow(
                l.sampleRate,
                l.wasapiSrFallback('${info.deviceRate}',
                    '${model.config.sampleRate}')),
        ],
        if (model.wasapiError.isNotEmpty) ...[
          _InfoRow('WASAPI', model.wasapiError),
          Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: AuraChip(
              l.retryNow,
              icon: Icons.refresh,
              onTap: () => model.retryWasapi(),
            ),
          ),
        ],
      ],
    );
  }
}

class _VaioOutputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VaioOutputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final info = model.vaioInfo;
    final endpoints = model.vaioPhysicalEndpoints;
    final curEndpoint = model.config.vaioOutputEndpoint;
    final matched = endpoints.cast<AudioDeviceItem?>().firstWhere(
        (e) => e?.name == curEndpoint || e?.id == curEndpoint,
        orElse: () => null);
    final selectedValue = matched != null
        ? matched.name
        : (curEndpoint.isEmpty ? '' : curEndpoint);

    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AuraSpace.sm),
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              border: Border.all(color: p.warning.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: p.warning),
                    const SizedBox(width: AuraSpace.xs),
                    Expanded(
                      child: Text(l.virtualSinkNotice,
                          style: captionOf(p, color: p.warning)),
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.monitorMirroring, style: labelOf(p, size: 12)),
                    AuraSwitch(
                      value: model.monitorMirroring,
                      onChanged: (v) => model.setMonitorMirroring(v),
                    ),
                  ],
                ),
                Text(l.monitorMirroringHint,
                    style: monoOf(p, size: 10, color: p.textDim)),
              ],
            ),
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(children: [
            SizedBox(
                width: 104,
                child: Text('物理输出',
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: AuraDropdown<String>(
                value: selectedValue,
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Row(
                      children: [
                        Icon(Icons.auto_mode_rounded,
                            size: 14,
                            color: curEndpoint.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('自动选择（非VAIO扬声器）',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: curEndpoint.isEmpty
                                      ? p.accent
                                      : p.text),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                  if (curEndpoint.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: curEndpoint,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                '${_formatOfflineDeviceName(curEndpoint, endpoints)} [离线/未连接]',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: p.warning,
                                    fontStyle: FontStyle.italic),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  for (final ep in endpoints)
                    DropdownMenuItem<String>(
                      value: ep.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(ep.name, isRender: true),
                            size: 14,
                            color: (ep.name == curEndpoint || ep.id == curEndpoint)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(ep.friendlyName,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: (ep.name == curEndpoint || ep.id == curEndpoint)
                                        ? p.accent
                                        : p.text),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: endpoints.isEmpty ? '无可用物理输出设备' : null,
                onChanged: (v) {
                  if (v != null) model.setVaioOutputEndpoint(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                onTap: () => model.refreshVaioDetect()),
          ]),
          if (info['note'] is String && (info['note'] as String).isNotEmpty)
            _InfoRow('AuraVAIO', '${info['note']}'),
          if (model.vaioActive) ...[
            if (info['sr'] is num)
              _InfoRow(l.sampleRate, '${(info['sr'] as num).toInt()} Hz / 2 ch'),
            if (info['frames'] is num)
              _InfoRow('已处理帧', '${(info['frames'] as num).toInt()} frames'),
            if (info['outputEndpoint'] is String &&
                (info['outputEndpoint'] as String).isNotEmpty)
              _InfoRow('输出端点', '${info['outputEndpoint']}'),
          ],
        ],
      ),
    );
  }
}

class _AsioClientOutputSubpanel extends StatelessWidget {
  final AppModel model;
  const _AsioClientOutputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final active = model.asioActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow('输出端点', 'AuraDSP ASIO Client 硬件输出'),
        _InfoRow('声道映射',
            '通道 ${model.config.asioOutPair * 2 + 1} / ${model.config.asioOutPair * 2 + 2}'),
        _InfoRow('输出状态', active ? '正在直通硬件监听 (超低延迟)' : '就绪 (等待驱动会话)'),
      ],
    );
  }
}

class _TestSourceChips extends StatelessWidget {
  final AppModel model;
  const _TestSourceChips({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Wrap(
        spacing: AuraSpace.sm,
        runSpacing: AuraSpace.sm,
        children: [
          AuraChip(
            l.srcTone,
            icon: Icons.graphic_eq,
            selected: model.playing && model.sourceKind == 'tone',
            onTap: () => model.setSource('tone'),
          ),
          AuraChip(
            l.srcPink,
            icon: Icons.blur_on,
            selected: model.playing && model.sourceKind == 'pink',
            onTap: () => model.setSource('pink'),
          ),
          AuraChip(
            l.srcFile,
            icon: Icons.folder_open_outlined,
            selected: model.playing &&
                model.sourceKind == 'file' &&
                model.sourceExt != 'mp3',
            onTap: () async {
              const type = XTypeGroup(label: 'WAV', extensions: ['wav']);
              final f = await openFile(
                acceptedTypeGroups: [type],
                initialDirectory: PathMemory.dirFor(PathMemory.slotTestAudio) ??
                    PathMemory.fallbackDir(PathMemory.slotTestAudio),
              );
              if (f != null) {
                PathMemory.recordPick(PathMemory.slotTestAudio, f.path);
                model.setSource('file', path: f.path);
              }
            },
          ),
          AuraChip(
            l.srcMp3,
            icon: Icons.music_note_outlined,
            selected: model.playing &&
                model.sourceKind == 'file' &&
                model.sourceExt == 'mp3',
            onTap: () async {
              const type = XTypeGroup(label: 'MP3', extensions: ['mp3']);
              final f = await openFile(
                acceptedTypeGroups: [type],
                initialDirectory: PathMemory.dirFor(PathMemory.slotTestAudio) ??
                    PathMemory.fallbackDir(PathMemory.slotTestAudio),
              );
              if (f != null) {
                PathMemory.recordPick(PathMemory.slotTestAudio, f.path);
                model.setSource('file', path: f.path);
              }
            },
          ),
          if (model.playing)
            AuraChip(
              l.srcStop,
              icon: Icons.stop_rounded,
              danger: true,
              selected: true,
              onTap: () => model.setSource('stop'),
            ),
        ],
      ),
    );
  }
}

class _EngineInfo extends StatelessWidget {
  final AppModel model;
  const _EngineInfo({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final info = model.info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info != null) ...[
          _InfoRow('ABI', 'v${info.abi} · ${info.version}'),
        ],
        _InfoRow('Latency', '${model.latencyMs.toStringAsFixed(1)} ms'),
        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),
        Text(l.about, style: sectionOf(p)),
        const SizedBox(height: AuraSpace.sm),
        Text(l.aboutBody, style: captionOf(p)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String k, v;
  const _InfoRow(this.k, this.v);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AuraSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(k, style: labelOf(p, size: 12, color: p.textDim)),
          ),
          Expanded(child: Text(v, style: monoOf(p, size: 12))),
        ],
      ),
    );
  }
}

/* ---- VB 总线：版型→总线名 + 每总线电平 + 处理开关 ----
 * SDK BUFFER_OUT 布局：每条总线 8 通道 = 泵的 1 组（g0 起）。
 * Potato: A1-A5/B1-B3；Banana: A1-A3/B1-B2；Standard: A1-A2/B1。
 * 开关 = vb_set_bus_mask 对应 bit；关=该总线直通（电平表照常计量）。
 * 电平来自 vbstatus 心跳的 peakGrp（约 1/s，桥内半衰期约 1s）。 */

List<String> _vbBusNames(int edition) {
  switch (edition) {
    case 1:
      return const ['A1/A2', 'B1'];
    case 2:
      return const ['A1', 'A2', 'A3', 'B1', 'B2'];
    default:
      return const ['A1', 'A2', 'A3', 'A4', 'A5', 'B1', 'B2', 'B3'];
  }
}

class _VbBuses extends StatelessWidget {
  final AppModel model;
  const _VbBuses({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final info = model.vbInfo;
    final edition = (info['edition'] as num?)?.toInt() ?? 0;
    final groups = (info['groups'] as num?)?.toInt() ?? 0;
    final names = _vbBusNames(edition);
    final peaks = (info['peakGrp'] as List?)
            ?.map((e) => (e as num?)?.toDouble() ?? 0.0)
            .toList() ??
        const <double>[];
    final live = (info['grpLive'] as num?)?.toInt() ?? 0;
    final n = groups.clamp(0, names.length);
    if (n <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AuraSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.vbBuses, style: labelOf(p, size: 12, color: p.textDim)),
          const SizedBox(height: AuraSpace.xs),
          for (var g = 0; g < n; g++)
            _VbBusRow(
              name: names[g],
              peak: g < peaks.length ? peaks[g] : 0.0,
              live: (live & (1 << g)) != 0,
              on: (model.vbBusMask & (1 << g)) != 0,
              onToggle: (v) => model.setVbBus(g, v),
            ),
        ],
      ),
    );
  }
}

/* ---- VB 总线行：名 + LED 灯段表 + 紧凑开关 ----
 * 灯段 12 格，dB 刻度（-54..0，每格 4.5dB；0dB 以上并入顶格）：
 * 低 9 格 success、上 2 格 warning、顶格 error——颜色全取自 palette，
 * 换主题自动跟；熄灭格用 hairline 做"暗槽"，复古调音台味。
 * 心跳约 1/s，灯段天然低刷新；行内另做 100ms 淡入淡出防闪烁即可。 */

class _VbBusRow extends StatelessWidget {
  final String name;
  final double peak;
  final bool live;
  final bool on;
  final ValueChanged<bool> onToggle;
  const _VbBusRow(
      {required this.name,
      required this.peak,
      required this.live,
      required this.on,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(name,
                style: monoOf(p, size: 12,
                    color: live ? p.text : p.textDim)),
          ),
          Expanded(child: _LedMeter(peak: live ? peak : 0.0, on: on)),
          const SizedBox(width: AuraSpace.sm),
          _MiniToggle(on: on, onToggle: onToggle),
        ],
      ),
    );
    // VB 没给这条总线 buffer（未路由/未分配）：整行置灰，开关照常可用
    // （VB 一旦送数，处理立刻生效）。
    if (!live) return Opacity(opacity: 0.45, child: row);
    return row;
  }
}

class _LedMeter extends StatelessWidget {
  final double peak;
  final bool on;
  const _LedMeter({required this.peak, required this.on});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    // 线性峰值→dB；底噪以下钳 -60。
    final db = peak <= 0
        ? -60.0
        : (20 * (math.log(peak) / math.ln10)).clamp(-60.0, 3.0);
    // -54dB 起亮，每格 4.5dB，12 格到 0dB。
    final lit = ((db + 54) / 4.5).floor().clamp(0, 12);
    return SizedBox(
      height: 8,
      child: Row(
        children: [
          for (var i = 0; i < 12; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 11 ? 0 : 3),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1.5),
                    color: i < lit
                        ? (i < 9
                            ? p.success
                            : i < 11
                                ? p.warning
                                : p.error)
                        : p.hairline,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/* 紧凑开关 30×18：胶囊底 + 滑块点，120ms 位移动画；关=直通。 */

class _MiniToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onToggle;
  const _MiniToggle({required this.on, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return GestureDetector(
      onTap: () => onToggle(!on),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        width: 30,
        height: 18,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: on ? p.accent : p.panelRaised,
          border: Border.all(
              color: on ? p.accent : p.hairline, width: 1),
        ),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? p.accentContrast : p.textDim,
          ),
        ),
      ),
    );
  }
}



class _ThemeCard extends StatefulWidget {
  final String name;
  final bool selected;
  final List<Color> swatch;
  final VoidCallback onTap;
  const _ThemeCard({
    required this.name,
    required this.selected,
    required this.swatch,
    required this.onTap,
  });

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final border = widget.selected
        ? p.accent
        : (_hover ? p.textDim.withValues(alpha: 0.5) : p.hairline);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AuraDur.base,
          curve: AuraCurve.standard,
          padding: const EdgeInsets.all(AuraSpace.sm),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accent.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: border, width: widget.selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AuraRadius.xs),
                child: SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      for (final c in widget.swatch)
                        Expanded(child: Container(color: c)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AuraSpace.sm),
              AnimatedDefaultTextStyle(
                duration: AuraDur.fast,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w400,
                  color: widget.selected ? p.text : p.textDim,
                ),
                child: Text(widget.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
