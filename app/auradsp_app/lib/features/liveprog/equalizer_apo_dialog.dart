/*
 * equalizer_apo_dialog.dart — EqualizerAPO 预设转换为 EEL2 交互对话框
 *
 * Clean-Room 原则实现：
 * - 支持外部 .txt 文件加载或直接文本粘贴
 * - 实时解析滤波器指令与 Preamp 增益
 * - 支持声道互换 (L <-> R) 与极性反转 (180°) 配置
 * - 即时双栏预览：原始配置 vs 生成的 EEL2 脚本
 * - 一键填入编辑器
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/error_sink.dart';
import '../../core/liveprog/equalizer_apo_parser.dart';
import '../../core/liveprog/rbj_biquad_generator.dart';
import '../../core/path_memory.dart';
import '../../core/theme.dart';
import '../widgets.dart';

class EqualizerApoDialog extends StatefulWidget {
  final String? initialText;

  const EqualizerApoDialog({super.key, this.initialText});

  static Future<String?> show(BuildContext context, {String? initialText}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => EqualizerApoDialog(initialText: initialText),
    );
  }

  @override
  State<EqualizerApoDialog> createState() => _EqualizerApoDialogState();
}

class _EqualizerApoDialogState extends State<EqualizerApoDialog> {
  late final TextEditingController _inputCtrl;
  Timer? _debounceTimer;
  bool _swapChannels = false;
  bool _invertPolarity = false;

  ApoConfiguration _parsedConfig = const ApoConfiguration();
  String _generatedCode = '';

  @override
  void initState() {
    super.initState();
    _inputCtrl = TextEditingController(text: widget.initialText ?? _defaultExample);
    _inputCtrl.addListener(_onInputChanged);
    _recompute();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    super.dispose();
  }

  static const _defaultExample = '''Preamp: -4.5 dB
Filter 1: ON PK Fc 32 Hz Gain 3.0 dB Q 1.41
Filter 2: ON PK Fc 64 Hz Gain 2.0 dB Q 1.41
Filter 3: ON PK Fc 1000 Hz Gain -2.5 dB Q 2.00
Filter 4: ON HSC Fc 8000 Hz Gain 2.0 dB Q 0.71
''';

  void _onInputChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _recompute();
    });
  }

  void _recompute() {
    final text = _inputCtrl.text;
    final config = EqualizerApoParser.parse(text);
    final generated = RbjBiquadGenerator.generate(
      config: config,
      channelSwap: _swapChannels,
      invertPolarity: _invertPolarity,
    );

    setState(() {
      _parsedConfig = config;
      _generatedCode = generated;
    });
  }

  Future<void> _pickFile() async {
    final l = l10nOf(context);
    final path = await AuraPathPickerDialog.show(
      context,
      title: l.lpApoOpenFile,
      allowedExtensions: ['txt'],
      memorySlot: PathMemory.slotLastScriptDir,
    );
    if (path != null && mounted) {
      try {
        final content = await File(path).readAsString();
        _inputCtrl.text = content;
        _recompute();
      } catch (e, st) {
        // 拾取文件读取失败：保持原输入，用户可重试（自愿操作，失败不打扰）。
        swallow(e, st);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.md),
        side: BorderSide(color: p.hairline),
      ),
      titlePadding: const EdgeInsets.fromLTRB(AuraSpace.md, AuraSpace.md, AuraSpace.md, AuraSpace.xs),
      contentPadding: const EdgeInsets.symmetric(horizontal: AuraSpace.md),
      actionsPadding: const EdgeInsets.fromLTRB(AuraSpace.md, AuraSpace.xs, AuraSpace.md, AuraSpace.md),
      title: Row(
        children: [
          Icon(Icons.auto_fix_high_rounded, size: 20, color: p.accent),
          const SizedBox(width: AuraSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.lpApoDialogTitle, style: sectionOf(p)),
                Text(l.lpApoDialogDesc, style: captionOf(p)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: l.dlgClose,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: Builder(
        builder: (dialogCtx) {
          final size = MediaQuery.sizeOf(dialogCtx);
          final dialogWidth = (size.width - 64).clamp(320.0, 880.0);
          final dialogHeight = (size.height - 120).clamp(360.0, 520.0);
          return SizedBox(
            width: dialogWidth,
            height: dialogHeight,
            child: Column(
              children: [
                // 状态条：左右拉伸占满一行，与下方编辑器等宽，并集成打开 .txt 文件按钮
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(vertical: AuraSpace.xs),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.panelRaised,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              Icon(Icons.tune_rounded, size: 14, color: p.accent),
                              const SizedBox(width: 6),
                              Text(
                                l.lpApoFiltersDetected(_parsedConfig.activeFilters.length),
                                style: monoOf(p, size: 11, color: p.text),
                              ),
                              const SizedBox(width: AuraSpace.md),
                              Icon(Icons.volume_up_rounded, size: 14, color: const Color(0xFF79C0FF)),
                              const SizedBox(width: 6),
                              Text(
                                l.lpApoPreampDetected(_parsedConfig.globalPreamp.toStringAsFixed(1)),
                                style: monoOf(p, size: 11, color: p.text),
                              ),
                              const SizedBox(width: AuraSpace.lg),
                              // 声道互换开关
                              InkWell(
                                onTap: () {
                                  setState(() => _swapChannels = !_swapChannels);
                                  _recompute();
                                },
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _swapChannels ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                        size: 15,
                                        color: _swapChannels ? p.accent : p.textDim,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(l.lpApoSwapChannels, style: captionOf(p)),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: AuraSpace.sm),
                              // 极性反转开关
                              InkWell(
                                onTap: () {
                                  setState(() => _invertPolarity = !_invertPolarity);
                                  _recompute();
                                },
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _invertPolarity ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                        size: 15,
                                        color: _invertPolarity ? p.accent : p.textDim,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(l.lpApoInvertPolarity, style: captionOf(p)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.sm),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.file_open_rounded, size: 14),
                        label: Text(l.lpApoOpenFile),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.accent,
                          side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        onPressed: _pickFile,
                      ),
                    ],
                  ),
                ),

                // Two columns: Left (Raw input) and Right (EEL2 Preview)
                Expanded(
                  child: Row(
                    children: [
                      // Left panel: Input text
                      Expanded(
                        flex: 4,
                        child: Container(
                          decoration: BoxDecoration(
                            color: p.panelRaised,
                            borderRadius: BorderRadius.circular(AuraRadius.sm),
                            border: Border.all(color: p.hairline),
                          ),
                          child: TextField(
                            controller: _inputCtrl,
                            maxLines: null,
                            expands: true,
                            style: monoOf(p, size: 11.5, color: p.text),
                            decoration: InputDecoration(
                              hintText: l.lpApoPasteHint,
                              hintStyle: captionOf(p).copyWith(color: p.textDim.withValues(alpha: 0.5)),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.all(AuraSpace.sm),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.sm),
                      // Right panel: Preview code
                      Expanded(
                        flex: 5,
                        child: Container(
                          padding: const EdgeInsets.all(AuraSpace.sm),
                          decoration: BoxDecoration(
                            color: p.panelRaised,
                            borderRadius: BorderRadius.circular(AuraRadius.sm),
                            border: Border.all(color: p.hairline),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.code_rounded, size: 13, color: p.textDim),
                                  const SizedBox(width: 4),
                                  Text(l.lpApoPreview, style: captionOf(p)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    _generatedCode,
                                    style: monoOf(p, size: 11, color: p.text),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 底部状态与异常报错行（左下角显示异常报错）
                const SizedBox(height: AuraSpace.xs),
                Row(
                  children: [
                    if (_parsedConfig.hasIssues) ...[
                      Icon(Icons.warning_amber_rounded, size: 14, color: p.warning),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${l.lpApoParseError(_parsedConfig.issues.first.line, _parsedConfig.issues.first.message)}'
                          '${_parsedConfig.issues.length > 1 ? " (+${_parsedConfig.issues.length - 1})" : ""}',
                          style: captionOf(p).copyWith(color: p.warning),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ] else if (_parsedConfig.activeFilters.isEmpty) ...[
                      Icon(Icons.info_outline_rounded, size: 14, color: p.textDim),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          l.lpApoNoFiltersPreampOnly,
                          style: captionOf(p).copyWith(color: p.textDim),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ] else ...[
                      const Spacer(),
                    ],
                  ],
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.dlgCancel, style: labelOf(p)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: p.accent,
            foregroundColor: p.accentContrast,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: AuraSpace.md, vertical: AuraSpace.xs),
          ),
          onPressed: _generatedCode.trim().isEmpty ? null : () => Navigator.of(context).pop(_generatedCode),
          child: Text(l.lpApoApply),
        ),
      ],
    );
  }
}
