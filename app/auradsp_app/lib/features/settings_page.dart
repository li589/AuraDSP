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
import 'package:auradsp_app/l10n/gen/app_localizations.dart';

import '../core/audio_modes.dart';
import '../core/config.dart';
import '../core/design.dart';
import '../core/session_memory.dart';
import '../core/state.dart';
import '../core/theme.dart';
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
          // 03 音频模式（各平台后端选择；引擎接线待后续版本）
          SectionCard(
            index: '03',
            title: l.audioMode,
            hint: l.audioModeHint,
            child: AuraSegmented<String>(
              segments: [
                for (final id in AudioModes.optionsFor(AudioModes.currentOs()))
                  AuraSegment(id, _modeLabel(l, id)),
              ],
              selected: model.audioMode,
              onChanged: (v) => model.setAudioMode(v),
            ),
          ),
          // 04 设备（当前设备展示；枚举列表后续在此扩展）
          SectionCard(
            index: '04',
            title: l.audioDevice,
            child: _DeviceInfo(model: model),
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

/* ---- 音频模式 id → 展示名（与 AudioModes.optionsFor 对齐） ---- */

String _modeLabel(AppLocalizations l, String id) {
  switch (id) {
    case 'vaio':
      return l.modeVaio;
    case 'vbcallback':
      return l.modeVb;
    case 'sysapo':
      return l.modeSysApo;
    case 'asio':
      return l.modeAsio;
    case 'root':
      return l.modeRoot;
    case 'rootless':
      return l.modeRootless;
    case 'system':
      return l.modeSystem;
    case 'virtual':
      return l.modeVirtual;
    case 'driver':
      return l.modeDriver;
    default:
      return l.modeAuto;
  }
}

/* ---- 当前设备（展示；枚举列表后续在此扩展） ---- */

class _DeviceInfo extends StatelessWidget {
  final AppModel model;
  const _DeviceInfo({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final info = model.info;
    // VB 桥激活时展示桥状态（sr/frames 来自 vbstatus 心跳）。
    if (model.vbActive) {
      final sr = model.vbInfo['sr'];
      final note = model.vbInfo['note'];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(l.audioMode, _modeLabel(l, 'vbcallback')),
          if (sr is num) _InfoRow(l.sampleRate, '${sr.toInt()} Hz'),
          // 重建事件（改主输出设备等）直接可见：用户不再靠"声音变了"猜。
          if (note is String && note.isNotEmpty) _InfoRow('VB', note),
          _VbBuses(model: model),
        ],
      );
    }
    // 选了 VB 模式但桥没起来：把原因摆出来（缺 DLL/槽被占/未安装），别静默。
    if (model.audioMode == 'vbcallback') {
      final note = model.vbInfo['note'];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(l.audioMode, _modeLabel(l, 'vbcallback')),
          if (note is String && note.isNotEmpty)
            _InfoRow('VB', note),
        ],
      );
    }
    // ASIO 模式：驱动选择器 + 缓冲档 + 输出对（Spec Phase 3）；桥活时加状态行。
    if (model.audioMode == 'asio') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(l.audioMode, _modeLabel(l, 'asio')),
          _AsioPanel(model: model),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.engineForm, 'Desktop · in-process DLL'),
        if (info != null) ...[
          _InfoRow(
              l.sampleRate, '${info.deviceRate} Hz / ${info.deviceCh} ch'),
          _InfoRow(l.buffer, '${info.bufferFrames} frames'),
          // 设备拒收请求速率（回退）：和 ASIO 的 srMismatch 同款诚实展示。
          if (info.deviceRate != model.config.sampleRate)
            _InfoRow(
                l.sampleRate,
                l.wasapiSrFallback('${info.deviceRate}',
                    '${model.config.sampleRate}')),
        ],
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
              final f = await openFile(acceptedTypeGroups: [type]);
              if (f != null) model.setSource('file', path: f.path);
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
              final f = await openFile(acceptedTypeGroups: [type]);
              if (f != null) model.setSource('file', path: f.path);
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

/* ---- ASIO 面板：驱动选择器 + 缓冲档 + 输出对（与 04 桥契约对齐） ---- */

class _AsioPanel extends StatelessWidget {
  final AppModel model;
  const _AsioPanel({required this.model});

  // 缓冲档（帧）：0 = 驱动 preferredSize（FL Studio 实测 512 / VM 2048）。
  static const _bufSizes = [0, 64, 128, 256, 512, 1024, 2048];
  // 输出对起始声道：0→ch1/2，1→ch3/4……上限 4 对（v1 驱动面 ≥8 出声道常见）。
  static const _outPairs = [0, 1, 2, 3];

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final drivers = model.asioDrivers;
    final names = [for (final d in drivers) d['name'] ?? ''];
    final sel = names.contains(model.config.asioDriver)
        ? model.config.asioDriver
        : (names.isNotEmpty ? names.first : '');
    final note = model.asioDriversNote;
    final info = model.asioInfo;
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 驱动下拉（清单空但 note 有原因：展示 note + 刷新入口，别静默）。
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioDriver,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: names.isEmpty
                  ? Text(sel.isEmpty ? '—' : model.config.asioDriver,
                      style: monoOf(p, size: 12))
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: sel,
                        isDense: true,
                        dropdownColor: p.panelRaised,
                        style: labelOf(p),
                        icon: Icon(Icons.arrow_drop_down_rounded,
                            color: p.accent),
                        items: [
                          for (final n in names)
                            DropdownMenuItem<String>(
                              value: n,
                              child: Text(n,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: n == sel ? p.accent : p.text)),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) model.setAsioDriver(v);
                        },
                      ),
                    ),
            ),
            // 刷新（重装驱动后手动重枚举；主 isolate 侧 asio_detect）。
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                onTap: () => model.refreshAsioDrivers()),
          ]),
          if (note.isNotEmpty) _InfoRow('ASIO', note),
          // 缓冲档：0=自动（驱动 preferredSize），其余为显式档位。
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioBufSize,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _bufSizes.contains(model.config.asioBufSize)
                      ? model.config.asioBufSize
                      : 0,
                  isDense: true,
                  dropdownColor: p.panelRaised,
                  style: labelOf(p),
                  icon:
                      Icon(Icons.arrow_drop_down_rounded, color: p.accent),
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
            ),
          ]),
          // 输出对：L=R+1 配对；0→ch1/2。
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioOutPair,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _outPairs.contains(model.config.asioOutPair)
                      ? model.config.asioOutPair
                      : 0,
                  isDense: true,
                  dropdownColor: p.panelRaised,
                  style: labelOf(p),
                  icon:
                      Icon(Icons.arrow_drop_down_rounded, color: p.accent),
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
            ),
          ]),
          // 运行态（来自 asiostatus 心跳；与 VB 分支同款只挑可读字段）。
          if (model.asioActive) ...[
            _InfoRow(l.asioSwitches, '${info['switches'] ?? 0}'),
            if (info['sr'] is num)
              _InfoRow(l.sampleRate,
                  '${(info['sr'] as num).toInt()} Hz / ${info['nbs'] ?? '?'} frames'),
            // Phase 4：掉线计数（两次 status 间回调增量低于期望 80% 记一次）。
            if ((info['dropouts'] as int? ?? 0) > 0)
              _InfoRow(l.asioDropouts, '${info['dropouts']}'),
            // Phase 4：驱动延迟变更提示（下一次会话生效）。
            if ((info['latenciesChanged'] as int? ?? 0) == 1)
              _InfoRow('ASIO', l.asioLatChanged),
            // Phase 4：采样率不符策略提示（ASIO 跟随驱动；设置页采样率仅
            // 对 WASAPI/进程内引擎生效）。
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
