// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 07 ArbMag (任意响应均衡器 / AutoEq GraphicEQ) ---- */

class _ArbmagCard extends StatefulWidget {
  final AppModel model;
  const _ArbmagCard({required this.model});

  @override
  State<_ArbmagCard> createState() => _ArbmagCardState();
}

class _ArbmagCardState extends State<_ArbmagCard> {
  final TextEditingController _codeCtrl = TextEditingController();
  bool _codeSynced = false;

  @override
  void initState() {
    super.initState();
    _codeCtrl.text = widget.model.arbmagString;
  }

  @override
  void didUpdateWidget(covariant _ArbmagCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_codeSynced || oldWidget.model.arbmagString != widget.model.arbmagString) {
      _codeCtrl.text = widget.model.arbmagString;
      _codeSynced = true;
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  static const String _kPresetFlat = 'GraphicEQ: 20 0.0; 1000 0.0; 20000 0.0';
  static const String _kPresetHarman =
      'GraphicEQ: 20 5.4; 32 5.0; 64 4.0; 125 2.5; 250 1.0; 500 0.0; 1000 0.0; 2000 1.5; 3000 3.0; 4000 1.0; 6000 -1.5; 8000 -2.0; 10000 0.0; 16000 -3.0; 20000 -6.0';
  static const String _kPresetDiffuse =
      'GraphicEQ: 20 0.0; 100 0.0; 1000 0.0; 2000 3.5; 3000 8.0; 4000 4.0; 6000 1.5; 8000 3.0; 10000 1.0; 16000 -2.0; 20000 -5.0';

  String _cleanGraphicEqText(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.toLowerCase().startsWith('graphiceq:')) {
      return 'GraphicEQ: $trimmed';
    }
    return trimmed;
  }

  /// B6 UI 预检：GraphicEQ 至少 2 个有效频点（频率>0 且<=96000、增益 [-64,64]、有限数）。
  /// 返回错误信息；null = 可通过（防坏串进引擎，与引擎 nodes 护栏双层防护）。
  static String? precheckGraphicEq(AppLocalizations t, String text) {
    final clean = text.replaceAll(RegExp(r'^[Gg]raphic[Ee][Qq]:\s*'), '');
    final pairs = clean.split(';');
    var ok = 0;
    for (final p in pairs) {
      final parts = p.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final f = double.tryParse(parts[0]);
      final g = double.tryParse(parts[1]);
      if (f == null || g == null || !f.isFinite || !g.isFinite) continue;
      if (f <= 0 || f > 96000) continue;
      if (g < -64 || g > 64) continue;
      ok++;
    }
    return ok >= 2 ? null : t.arbmagMinPoints;
  }

  /// 校验通过才下发引擎；返回是否成功。
  bool _applyGraphicEq(BuildContext context, String text) {
    final l = l10nOf(context);
    final cleaned = _cleanGraphicEqText(text);
    if (cleaned.isEmpty) {
      widget.model.clearArbmag();
      _codeCtrl.clear();
      return true;
    }
    final err = precheckGraphicEq(l, cleaned);
    if (err != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.arbmagGraphicEqInvalid(err))),
        );
      }
      return false;
    }
    widget.model.setArbmagString(cleaned);
    _codeCtrl.text = cleaned;
    return true;
  }

  Future<void> _importFile(BuildContext context) async {
    final l = l10nOf(context);
    final path = await AuraPathPickerDialog.show(
      context,
      title: l.stArbmag,
      prompt: l.arbmagPrompt,
      allowedExtensions: const ['txt', 'csv'],
      memorySlot: PathMemory.slotArbmag,
      confirmLabel: l.arbmagImport,
    );
    if (path != null) {
      try {
        final text = await File(path).readAsString();
        final cleaned = _cleanGraphicEqText(text);
        if (!context.mounted) return;
        _applyGraphicEq(context, cleaned);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.arbmagReadFailed(e.toString()))),
          );
        }
      }
    }
  }

  Future<void> _pasteClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    final cleaned = _cleanGraphicEqText(text);
    if (!context.mounted) return;
    _applyGraphicEq(context, cleaned);
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = widget.model;

    return SectionCard(
      index: kEffectCardIndex['arbmag'],
      title: l.stArbmag,
      titleTooltip: l.arbmagSubtitle,
      collapsed: !m.arbmagOn,
      latencyMs: m.componentLatency('arbmag').ms,
      latencyEnabled: m.isSectionEnabled('arbmag'),
      latencyMeasured: m.componentLatency('arbmag').measured,
      latencyEstimated: m.componentLatency('arbmag').estimated,
      latencyProbing: m.isProbingLatency('arbmag'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('arbmag')
          ? () => m.refreshComponentLatency('arbmag')
          : null,
      latencyTick: m.getComponentLatencyTick('arbmag'),
      trailing: AuraSwitch(
        value: m.arbmagOn,
        onChanged: m.setArbmagEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 微缩频响曲线预览
          _ArbmagCurvePreview(
            rawString: m.arbmagString,
            palette: p,
            emptyHint: l.arbmagEmptyHint,
          ),
          const SizedBox(height: AuraSpace.sm),

          // 2. 经典目标预设芯片栏
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AuraChoiceChip(
                label: l.arbmagPresetFlat,
                selected: m.arbmagString == _kPresetFlat || m.arbmagString.isEmpty,
                onTap: () {
                  m.setArbmagString(_kPresetFlat);
                  _codeCtrl.text = _kPresetFlat;
                },
              ),
              AuraChoiceChip(
                label: l.arbmagPresetHarman,
                selected: m.arbmagString == _kPresetHarman,
                onTap: () {
                  m.setArbmagString(_kPresetHarman);
                  _codeCtrl.text = _kPresetHarman;
                },
              ),
              AuraChoiceChip(
                label: l.arbmagPresetDiffuse,
                selected: m.arbmagString == _kPresetDiffuse,
                onTap: () {
                  m.setArbmagString(_kPresetDiffuse);
                  _codeCtrl.text = _kPresetDiffuse;
                },
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),

          // 3. 高级折叠面板（源码编辑、导入/粘贴工具、AGC、输出增益门）
          _ArbmagAdvanced(
            model: m,
            codeCtrl: _codeCtrl,
            onApplyCode: (code) {
              _applyGraphicEq(context, code);
            },
            onImportFile: () => _importFile(context),
            onPasteClipboard: () => _pasteClipboard(context),
            onClear: () {
              m.clearArbmag();
              _codeCtrl.clear();
            },
          ),
        ],
      ),
    );
  }
}

class _ArbmagCurvePreview extends StatelessWidget {
  final String rawString;
  final AuraPalette palette;
  final String emptyHint;

  const _ArbmagCurvePreview({
    required this.rawString,
    required this.palette,
    required this.emptyHint,
  });

  static List<({double freq, double gain})> parseNodes(String raw) {
    if (raw.isEmpty) return const [];
    final clean = raw.replaceAll(RegExp(r'^[Gg]raphic[Ee][Qq]:\s*'), '');
    final pairs = clean.split(';');
    final list = <({double freq, double gain})>[];
    for (final p in pairs) {
      final parts = p.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final f = double.tryParse(parts[0]);
        final g = double.tryParse(parts[1]);
        if (f != null && g != null) {
          list.add((freq: f, gain: g));
        }
      }
    }
    list.sort((a, b) => a.freq.compareTo(b.freq));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final nodes = parseNodes(rawString);

    return Container(
      height: 120,
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.panelRaised.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          CustomPaint(
            size: Size.infinite,
            painter: _ArbmagCurvePainter(
              nodes: nodes,
              palette: palette,
            ),
          ),
          if (nodes.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  emptyHint,
                  textAlign: TextAlign.center,
                  style: captionOf(palette).copyWith(fontSize: 11),
                ),
              ),
            )
          else
            Positioned(
              right: 8,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.panel.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(color: palette.hairline.withValues(alpha: 0.5)),
                ),
                child: Text(
                  l10nOf(context).arbmagPoints(nodes.length),
                  style: monoOf(palette, size: 9.5, color: palette.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArbmagCurvePainter extends CustomPainter {
  final List<({double freq, double gain})> nodes;
  final AuraPalette palette;

  const _ArbmagCurvePainter({
    required this.nodes,
    required this.palette,
  });

  static const double _minF = 20.0;
  static const double _maxF = 20000.0;
  static const double _maxDb = 20.0;
  static const double _minDb = -20.0;

  static double _fToX(double f, double width) {
    final clampedF = f.clamp(_minF, _maxF);
    final logMin = math.log(_minF);
    final logMax = math.log(_maxF);
    return ((math.log(clampedF) - logMin) / (logMax - logMin)) * width;
  }

  static double _dbToY(double db, double height) {
    final clampedDb = db.clamp(_minDb, _maxDb);
    final norm = (clampedDb - _minDb) / (_maxDb - _minDb);
    return (1.0 - norm) * height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. 网格背景线 (对数频标 100, 1k, 10k)
    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.4)
      ..strokeWidth = 0.8;
    for (final f in [100.0, 1000.0, 10000.0]) {
      final x = _fToX(f, w);
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }

    // 分贝基线: 0dB
    final zeroY = _dbToY(0.0, h);
    final zeroPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, zeroY), Offset(w, zeroY), zeroPaint);

    // +10dB, -10dB 浅色细线
    for (final db in [10.0, -10.0]) {
      final y = _dbToY(db, h);
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
    }

    if (nodes.isEmpty) return;

    // 2. 绘制频响曲线路径
    final path = Path();
    final fillPath = Path();

    final firstX = _fToX(nodes.first.freq, w);
    final firstY = _dbToY(nodes.first.gain, h);

    path.moveTo(0, firstY);
    path.lineTo(firstX, firstY);

    fillPath.moveTo(0, zeroY);
    fillPath.lineTo(0, firstY);
    fillPath.lineTo(firstX, firstY);

    for (var i = 1; i < nodes.length; i++) {
      final prevX = _fToX(nodes[i - 1].freq, w);
      final prevY = _dbToY(nodes[i - 1].gain, h);
      final curX = _fToX(nodes[i].freq, w);
      final curY = _dbToY(nodes[i].gain, h);

      final cX = (prevX + curX) / 2.0;
      path.cubicTo(cX, prevY, cX, curY, curX, curY);
      fillPath.cubicTo(cX, prevY, cX, curY, curX, curY);
    }

    final lastX = _fToX(nodes.last.freq, w);
    final lastY = _dbToY(nodes.last.gain, h);
    if (lastX < w) {
      path.lineTo(w, lastY);
      fillPath.lineTo(w, lastY);
    }

    fillPath.lineTo(w, zeroY);
    fillPath.close();

    // 渐变填充
    final fillGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        palette.accent.withValues(alpha: 0.28),
        palette.accent.withValues(alpha: 0.04),
      ],
    );
    final fillPaint = Paint()
      ..shader = fillGradient.createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 曲线轮廓
    final strokePaint = Paint()
      ..color = palette.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);

    // 绘制离散节点圆点（当节点数小于 40 时绘制微型亮点）
    if (nodes.length <= 40) {
      final dotPaint = Paint()
        ..color = palette.accent
        ..style = PaintingStyle.fill;
      for (final n in nodes) {
        final x = _fToX(n.freq, w);
        final y = _dbToY(n.gain, h);
        canvas.drawCircle(Offset(x, y), 2.2, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ArbmagCurvePainter oldDelegate) =>
      oldDelegate.nodes != nodes || oldDelegate.palette != palette;
}

class _ArbmagAdvanced extends StatelessWidget {
  final AppModel model;
  final TextEditingController codeCtrl;
  final ValueChanged<String> onApplyCode;
  final VoidCallback onImportFile;
  final VoidCallback onPasteClipboard;
  final VoidCallback onClear;

  const _ArbmagAdvanced({
    required this.model,
    required this.codeCtrl,
    required this.onApplyCode,
    required this.onImportFile,
    required this.onPasteClipboard,
    required this.onClear,
  });

  bool get _hasValidCode {
    final text = codeCtrl.text.trim();
    if (text.isEmpty) return false;
    final lower = text.toLowerCase();
    final content = lower.startsWith('graphiceq:') ? text.substring(10).trim() : text;
    // 粗略校验至少包含一个分号或频点数对
    return content.contains(';') || content.split(RegExp(r'\s+')).length >= 2;
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;

    final agcStr = 'AGC: ${m.arbmagAutoGain ? "ON" : "OFF"}';
    final trimStr =
        '${(m.arbmagOutputGain >= 0 ? "+" : "")}${m.arbmagOutputGain.toStringAsFixed(1)} dB';
    final nodesStr = l.arbmagNodes(m.arbmagNodeCount);

    return AdvancedSection(
      summary: '$agcStr · $trimStr · $nodesStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. GraphicEQ 代码编辑器
          Text(l.arbmagEditor, style: labelOf(p, color: p.text)),
          const SizedBox(height: AuraSpace.xxs),
          Container(
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.xs),
              border: Border.all(color: p.hairline.withValues(alpha: 0.6)),
            ),
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: codeCtrl,
              maxLines: 4,
              minLines: 2,
              style: monoOf(p, size: 11, color: p.text),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: 'GraphicEQ: 20 0.0; 1000 0.0; 20000 0.0',
                hintStyle: monoOf(p, size: 11, color: p.textDim),
              ),
            ),
          ),
          const SizedBox(height: AuraSpace.sm),

          // 2. 工具栏：[应用代码] [导入文件] [从剪贴板粘贴] [清空]
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: codeCtrl,
            builder: (context, value, _) {
              final canApply = _hasValidCode;
              return Row(
                children: [
                  // 主动作保留 accent 实底（应用侧对话框主按钮惯例），
                  // 但几何尺寸与其余 OutlinedButton.icon 兄弟统一：
                  // 同 padding(10,8)、同字号 12 常规字重、不设 minimumSize
                  // 覆盖（统一默认 36 高）、配 14px 图标。
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: canApply ? p.accent : p.panelRaised,
                      foregroundColor: canApply ? p.accentContrast : p.textDim,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: const Icon(Icons.check_rounded, size: 14),
                    label: Text(l.arbmagApply),
                    onPressed: canApply ? () => onApplyCode(codeCtrl.text) : null,
                  ),
                  const SizedBox(width: AuraSpace.sm),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.hairline),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: const Icon(Icons.file_upload_outlined, size: 14),
                    label: Text(l.arbmagImport),
                    onPressed: onImportFile,
                  ),
                  const SizedBox(width: AuraSpace.sm),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.hairline),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: const Icon(Icons.content_paste_rounded, size: 14),
                    label: Text(l.arbmagPaste),
                    onPressed: onPasteClipboard,
                  ),
                  const Spacer(),
                  if (m.arbmagString.isNotEmpty || codeCtrl.text.isNotEmpty)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: p.textDim,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      icon: const Icon(Icons.clear_all_rounded, size: 14),
                      label: Text(l.arbmagClear),
                      onPressed: onClear,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: AuraSpace.md),

          // 3. 输出级外框（自动增益补偿与输出增益门）
          OutputGainFrame(
            child: Column(
              children: [
                _AutoGainRow(
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                  value: m.arbmagAutoGain,
                  enabled: m.arbmagOn,
                  onChanged: m.setArbmagAutoGain,
                ),
                const SizedBox(height: AuraSpace.xs),
                ValueSlider(
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                  value: m.arbmagOutputGain,
                  defaultValue: ParamDefaults.arbmagOutputGain,
                  onResetToDefault: () =>
                      m.setArbmagOutputGain(ParamDefaults.arbmagOutputGain),
                  min: -12.0,
                  max: 6.0,
                  unit: 'dB',
                  enabled: m.arbmagOn,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setArbmagOutputGain,
                  onChangedEnd: m.setArbmagOutputGain,
                ),
              ],
            ),
          ),
          const SizedBox(height: AuraSpace.sm),
          ChannelRoutingSelector(
            model: m,
            paramKey: 'arbmag.channels',
          ),
        ],
      ),
    );
  }
}
