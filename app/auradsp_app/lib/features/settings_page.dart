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
import '../core/tray_service.dart';
import '../core/ui_helpers.dart';
import 'chrome.dart';
import 'widgets.dart';

part 'settings/panels/sections.dart';   // _CatBar / 模式面板（VB/APO/动态音频）
part 'settings/panels/hardware_drivers.dart'; // 管线三层 + 驱动行（ASIO/VAIO/WASAPI/VASIO）
part 'settings/panels/hardware_io.dart';      // 输入/输出层与子面板 + 测试音源
part 'settings/panels/vb_theme.dart';   // 引擎信息 / VB 总线 / 主题卡


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
          // 配色
          SectionCard(
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
          // 语言
          SectionCard(
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
          // 音频范式与模式（ADR-009：附加模式原地挂载；普通管线模式端到端流转）
          SectionCard(
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
          // 设备与精细化调节（根据当前范式与配置动态展示）
          SectionCard(
            title: l.audioDevice,
            child: _DynamicAudioPanel(model: model),
          ),
          // 声道模式（ADR-003 Phase A）
          SectionCard(
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
          // 采样率（发给设备的请求值；设备可回退原生值；桥模式跟对端走，
// 此时点选仅保存偏好，回进程内/下次建链生效——置灰反而让人以为坏了，保持可点）。
          SectionCard(
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
          // 引擎信息
          SectionCard(
            title: l.engineInfo,
            child: _EngineInfo(model: model),
          ),
          // 持久化记忆与外置配置
          SectionCard(
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
          // 系统（托盘常驻 + 开机自启；Windows）
          SectionCard(
            title: l.sysTitle,
            hint: l.sysHint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.sysTray, style: labelOf(p, size: 12)),
                    AuraSwitch(
                      value: true,
                      onChanged: null, // 常驻行为；托盘不可用时整卡隐藏
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(l.sysTrayHint, style: captionOf(p)),
                const SizedBox(height: AuraSpace.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.sysAutostart, style: labelOf(p, size: 12)),
                    AuraSwitch(
                      value: AutoStartService.instance.enabled ?? false,
                      onChanged: (v) => AutoStartService.instance.setEnabled(v),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(l.sysAutostartHint, style: captionOf(p)),
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
        // 按分类切片：外观 / 音频 / 系统 / 测试源。
        final cats = <List<Widget>>[
          [all[0], all[1]],
          [all[2], all[3], all[4], all[5]],
          [all[6], all[7], all[8]],
          [all[9]],
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
