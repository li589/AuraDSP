/*
 * liveprog_page.dart — EEL2 脚本 IDE 视角重塑（第二轮 V2 版升级）
 *
 * 核心架构重构：
 * 1. 扁平一体化 IDE 视界：移除 01/02/03 卡片编号与串行组织，以 EEL2 专业代码编辑为主体。
 * 2. 顶栏 7 大核心操作区：
 *    - 应用：未应用/已应用 状态切换，代码修改后未编译时强制置灰禁用（互锁保护）；
 *    - 编译：纯编译与引擎加载，隔离异常；
 *    - 文件下拉：新建空白脚本、从模板新建、导入 APO 预设、导入 EEL 脚本、另存为（独立保存，不记录记忆）；
 *    - 脚本库：打开独立的脚本库与外部目录管理弹窗（异步检测目录有效性、系统资源管理器浏览）；
 *    - 编辑下拉：查找与替换、代码大纲、格式化代码、跳回开头（光标与视图瞬间置顶）；
 *    - 手册：EEL2 规范参考手册；
 *    - 控制台：切换控制台诊断面板展示。
 * 3. 滑块面板内嵌：自适应参数滑块紧随控制台下方，折叠与响应式统一呈现。
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/design.dart';
import '../core/engine_error_map.dart';
import '../core/error_sink.dart';
import '../core/path_memory.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'chrome.dart';
import 'liveprog/code_outline_panel.dart';
import 'liveprog/console/liveprog_console_panel.dart';
import 'liveprog/eel_editor_support.dart';
import 'liveprog/eel_manual_panel.dart';
import 'liveprog/equalizer_apo_dialog.dart';
import 'liveprog/find_replace_bar.dart';
import 'liveprog/library/liveprog_library_dialog.dart';
import 'liveprog/line_number_gutter.dart';
import 'liveprog/liveprog_library.dart';
import 'liveprog/new_script_wizard_dialog.dart';
import 'liveprog/sliders/liveprog_sliders_panel.dart';
import 'liveprog/toolbar/liveprog_ide_toolbar.dart';
import 'widgets.dart';

// 向下兼容导出
export 'liveprog/liveprog_library.dart';

class LiveprogPage extends StatefulWidget {
  final AppModel model;
  const LiveprogPage({super.key, required this.model});

  @override
  State<LiveprogPage> createState() => _LiveprogPageState();
}

/// 状态胶囊共用体：主文案 + 可选的引擎原文第二行（与主文案不同才展示）。
Widget _capsuleBody(AuraPalette p, Color c, IconData icon, String text,
    {String? err}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      border: Border.all(color: c.withValues(alpha: 0.45)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: captionOf(p, color: c),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (err != null && err.isNotEmpty && !text.contains(err))
          Flexible(
            child: Text(
              err,
              style: monoOf(p, size: 11, color: p.textDim),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
      ],
    ),
  );
}

class _LiveprogPageState extends State<LiveprogPage> {
  final _editorFocus = FocusNode();
  final ScrollController _editorScrollCtrl = ScrollController();
  int _cursorLine = 1, _cursorCol = 1;
  List<EelLintIssue> _issues = const [];

  late final EelSyntaxTextEditingController _code;

  Map<int, EelSliderMeta> _activeSliders = {};

  // 编译与应用互锁状态
  bool _compiling = false;
  int _lastApplyMs = 0;
  Timer? _compileFallback;
  String _lastCompiledCode = '';
  bool _isCodeDirty = true; // 初始未编译前，置为 dirty，要求先点编译

  // IDE 交互状态
  bool _showFindReplace = false;
  bool _showOutline = false;
  bool _showConsole = false;
  bool _expandedEditor = false;

  // 编辑器缩放控制与行号同步
  static const double _kDefaultFontSize = 12.5;
  static const double _kMinFontSize = 9.0;
  static const double _kMaxFontSize = 26.0;
  double _editorFontSize = _kDefaultFontSize;

  // 逻辑行排版几何缓存（文本/宽度/字号变化才重算，滚动与光标移动零成本）
  EditorLineMetrics? _lineMetrics;
  String? _lineMetricsText;
  double? _lineMetricsTextWidth;
  double? _lineMetricsScaledFont;

  /// 取得与编辑器同参量的逐逻辑行几何；命中缓存时直接复用
  EditorLineMetrics _resolveLineMetrics({
    required String text,
    required TextStyle style,
    required StrutStyle strutStyle,
    required double textWidth,
    required TextScaler textScaler,
    required double fallbackLineAdvance,
  }) {
    final scaledFont = textScaler.scale(style.fontSize ?? 0);
    final cached = _lineMetrics;
    if (cached != null &&
        _lineMetricsText == text &&
        _lineMetricsTextWidth == textWidth &&
        _lineMetricsScaledFont == scaledFont) {
      return cached;
    }
    final metrics = EditorLineMetrics.compute(
      text: text,
      style: style,
      strutStyle: strutStyle,
      textWidth: textWidth,
      textScaler: textScaler,
      fallbackLineAdvance: fallbackLineAdvance,
    );
    _lineMetrics = metrics;
    _lineMetricsText = text;
    _lineMetricsTextWidth = textWidth;
    _lineMetricsScaledFont = scaledFont;
    return metrics;
  }

  double _calculateLineHeight(TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.preferredLineHeight;
  }

  void _onEditorPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
      final currentOffset =
          _editorScrollCtrl.hasClients ? _editorScrollCtrl.offset : 0.0;
      if (event.scrollDelta.dy < 0) {
        _zoomEditor(0.5);
      } else if (event.scrollDelta.dy > 0) {
        _zoomEditor(-0.5);
      }
      if (_editorScrollCtrl.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_editorScrollCtrl.hasClients) {
            _editorScrollCtrl.jumpTo(
              currentOffset.clamp(0.0, _editorScrollCtrl.position.maxScrollExtent),
            );
          }
        });
      }
    }
  }

  void _zoomEditor(double delta) {
    final newSize = (_editorFontSize + delta).clamp(_kMinFontSize, _kMaxFontSize);
    if ((newSize - _editorFontSize).abs() > 0.001) {
      setState(() {
        _editorFontSize = double.parse(newSize.toStringAsFixed(1));
      });
    }
  }

  void _resetEditorFontSize() {
    if ((_editorFontSize - _kDefaultFontSize).abs() > 0.001) {
      setState(() {
        _editorFontSize = _kDefaultFontSize;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final initialCode = (widget.model.lpDraftCode != null &&
            widget.model.lpDraftCode!.isNotEmpty)
        ? widget.model.lpDraftCode!
        : ((widget.model.lpCode != null && widget.model.lpCode!.isNotEmpty)
            ? widget.model.lpCode!
            : LiveprogLibrary.template);
    _code = EelSyntaxTextEditingController(text: initialCode);
    widget.model.addListener(_onModelTick);
    _code.addListener(_onEditorTick);
    _activeSliders = EelSliderParser.parse(_code.text);
    _lastCompiledCode = widget.model.lpCode ?? '';
    _isCodeDirty = initialCode != _lastCompiledCode;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runLint();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelTick);
    _code.removeListener(_onEditorTick);
    _compileFallback?.cancel();
    _code.dispose();
    _editorScrollCtrl.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  /// 引擎回了编译结果（成功或失败）→ 松开状态并刷新错误飘红
  void _onModelTick() {
    if (_compiling &&
        (widget.model.lpStatus == 1 || widget.model.lpError != null)) {
      _compileFallback?.cancel();
      if (mounted) {
        setState(() {
          _compiling = false;
          _updateErrorLines();
        });
      }
    } else if (mounted) {
      _updateErrorLines();
    }
  }

  /// 光标移动与选择变化时的极速响应
  void _onEditorTick() {
    final text = _code.text;
    final sel = _code.selection;
    var line = 1;
    var col = 1;
    if (sel.isValid) {
      final before = text.substring(0, sel.baseOffset.clamp(0, text.length));
      final nl = before.lastIndexOf('\n');
      line = nl < 0 ? 1 : before.split('\n').length;
      col = before.length - (nl < 0 ? 0 : nl);
    }
    final dirty = text != _lastCompiledCode;
    if (_cursorLine != line || _cursorCol != col || _isCodeDirty != dirty) {
      if (mounted) {
        setState(() {
          _cursorLine = line;
          _cursorCol = col;
          _isCodeDirty = dirty;
        });
      }
    }
  }

  /// 即时 lint + 自适应滑块解析 + 脏检查
  void _onCodeChanged(String text) {
    widget.model.lpDraftCode = text;
    widget.model.scheduleAutoSave();
    _runLint();
    setState(() {
      _activeSliders = EelSliderParser.parse(text);
      _isCodeDirty = text != _lastCompiledCode;
    });
    _onEditorTick();
  }

  void _runLint() {
    final issues = EelLinter.lint(l10nOf(context), _code.text);
    setState(() {
      _issues = issues;
      _updateErrorLines();
    });
  }

  /// 收集当前代码的错误行（词法检查 + 引擎编译报错行），驱动行号栏和代码行醒目标红
  void _updateErrorLines() {
    final lines = <int>{};
    final st = widget.model.lpStatus;
    final err = widget.model.lpError;
    final hasCompiledCleanly = st == 1 && err == null && !_isCodeDirty;

    // 若当前代码在引擎中已编译成功且未被修改，则不产生报错飘红
    if (!hasCompiledCleanly) {
      for (final issue in _issues) {
        if (issue.line > 0 && issue.blocking) {
          lines.add(issue.line);
        }
      }
    }
    if (st < 0 || (st == 0 && err != null)) {
      if (err != null) {
        // l10n-ignore
        final match =
            RegExp(r'(?:line|Line|\u7b2c)\s*(\d+)', caseSensitive: false)
                .firstMatch(err);
        if (match != null) {
          final ln = int.tryParse(match.group(1) ?? '');
          if (ln != null && ln > 0) lines.add(ln);
        }
      }
      if (lines.isEmpty) {
        final text = _code.text;
        final target = st == -1 ? '@init' : (st == -3 ? '@sample' : null);
        if (target != null) {
          final idx = text.indexOf(target);
          if (idx >= 0) {
            lines.add(text.substring(0, idx).split('\n').length);
          }
        }
      }
    }
    _code.errorLines = lines;
  }

  void _gotoLine(int line) {
    final text = _code.text;
    var offset = 0;
    for (var i = 1; i < line; i++) {
      final nl = text.indexOf('\n', offset);
      if (nl < 0) {
        offset = text.length;
        break;
      }
      offset = nl + 1;
    }
    _code.selection = TextSelection.collapsed(offset: offset);
    _editorFocus.requestFocus();
  }

  void _formatCode() {
    final sel = _code.selection;
    final formatted = EelFormatter.format(_code.text);
    _code.value = TextEditingValue(
      text: formatted,
      selection: sel.isValid
          ? sel.copyWith(
              baseOffset: sel.baseOffset.clamp(0, formatted.length),
              extentOffset: sel.extentOffset.clamp(0, formatted.length))
          : const TextSelection.collapsed(offset: 0),
    );
    _onCodeChanged(formatted);
  }

  /// 光标移动到开头并平滑滚动到最顶部
  void _scrollToTop() {
    _code.selection = const TextSelection.collapsed(offset: 0);
    _editorFocus.requestFocus();
    if (_editorScrollCtrl.hasClients) {
      _editorScrollCtrl.animateTo(
        0.0,
        duration: AuraDur.fast,
        curve: AuraCurve.standard,
      );
    }
  }

  /// 插入 Soft Tab（2 空格）或退格缩进，解决 Flutter 默认原生 Tab 渲染为 1 空格的问题
  void _insertTab({required bool indentLess}) {
    final text = _code.text;
    final sel = _code.selection;
    if (!sel.isValid || sel.isCollapsed) {
      if (!indentLess) {
        final pos = sel.baseOffset.clamp(0, text.length);
        final newText = '${text.substring(0, pos)}  ${text.substring(pos)}';
        _code.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: pos + 2),
        );
      } else {
        final lineStart = text.lastIndexOf('\n', sel.baseOffset - 1) + 1;
        if (text.startsWith('  ', lineStart)) {
          final newText = text.substring(0, lineStart) +
              text.substring(lineStart + 2);
          _code.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(
                offset: (sel.baseOffset - 2).clamp(0, newText.length)),
          );
        } else if (text.startsWith(' ', lineStart)) {
          final newText = text.substring(0, lineStart) +
              text.substring(lineStart + 1);
          _code.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(
                offset: (sel.baseOffset - 1).clamp(0, newText.length)),
          );
        } else if (text.startsWith('\t', lineStart)) {
          final newText = text.substring(0, lineStart) +
              text.substring(lineStart + 1);
          _code.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(
                offset: (sel.baseOffset - 1).clamp(0, newText.length)),
          );
        }
      }
      _onCodeChanged(_code.text);
      return;
    }
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final lineStart = text.lastIndexOf('\n', start <= 0 ? 0 : start - 1) + 1;
    final affected = text.substring(lineStart, end);
    final lines = affected.split('\n');
    final rebuilt = lines.map((l) {
      if (indentLess) {
        if (l.startsWith('  ')) return l.substring(2);
        if (l.startsWith(' ')) return l.substring(1);
        if (l.startsWith('\t')) return l.substring(1);
        return l;
      }
      return '  $l';
    }).join('\n');
    final newText = text.substring(0, lineStart) +
        rebuilt +
        text.substring(end);
    _code.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: lineStart,
        extentOffset: lineStart + rebuilt.length,
      ),
    );
    _onCodeChanged(newText);
  }

  /// 纯编译代码并载入虚拟机（应用状态下禁止编译；异常文本隔离）
  void _compile() {
    if (widget.model.lpEnabled) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(
          l10nOf(context).lpTooltipUnapplyToCompile,
          style: TextStyle(color: paletteOf(context).text, fontSize: 13),
        ),
        duration: const Duration(seconds: 2),
      ));
      return;
    }

    final text = _code.text;
    if (text.trim().isEmpty) return;

    // 引擎必拒结构问题本地拦截
    final blocking = _issues.where((e) => e.blocking).toList();
    if (blocking.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(
            '${l10nOf(context).lpBlockedByLint}：${blocking.first.message}',
            style:
                TextStyle(color: paletteOf(context).text, fontSize: 13)),
        duration: const Duration(seconds: 3),
      ));
      if (blocking.first.line > 0) _gotoLine(blocking.first.line);
      return;
    }

    if (_compiling) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastApplyMs < 500) return;
    _lastApplyMs = now;

    setState(() {
      _compiling = true;
      _lastCompiledCode = text;
      _isCodeDirty = false;
    });

    try {
      widget.model.setLiveprogCode(text);
    } catch (e, st) {
      swallow(e, st);
    }

    _compileFallback?.cancel();
    _compileFallback = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _compiling = false);
    });
  }

  /// 切换应用状态（未编译无法应用；已应用允许点击关闭）
  void _toggleApply() {
    if (widget.model.lpEnabled) {
      widget.model.setLiveprogEnabled(false);
      return;
    }
    final hasCompiled = widget.model.lpStatus == 1 && widget.model.lpError == null;
    if (_isCodeDirty || _compiling || !hasCompiled) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(
          l10nOf(context).lpTooltipCompileFirst,
          style: TextStyle(color: paletteOf(context).text, fontSize: 13),
        ),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    widget.model.setLiveprogEnabled(true);
  }

  Future<bool> _confirmDiscardUnsavedIfNeeded() async {
    final current = _code.text.trim();
    if (current.isEmpty || current == LiveprogLibrary.template.trim()) {
      return true;
    }
    var confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        final l = l10nOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.md),
            side: BorderSide(color: p.hairline),
          ),
          title: Text(l.lpConfirmDiscardTitle, style: sectionOf(p)),
          content: Text(l.lpConfirmDiscardBody, style: labelOf(p)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.dlgCancel, style: labelOf(p)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                confirmed = true;
                Navigator.of(ctx).pop();
              },
              child: Text(l.lpConfirmDiscardAction),
            ),
          ],
        );
      },
    );
    return confirmed;
  }

  // --- 文件下拉操作 ---

  Future<void> _handleFileAction(LiveprogFileAction action) async {
    switch (action) {
      case LiveprogFileAction.newBlank:
        await _newBlankScript();
        break;
      case LiveprogFileAction.newFromTemplate:
        await _openWizard();
        break;
      case LiveprogFileAction.importApo:
        await _openApoConverter();
        break;
      case LiveprogFileAction.importEel:
        await _importEelScript();
        break;
      case LiveprogFileAction.saveAs:
        await _saveAs();
        break;
    }
  }

  Future<void> _newBlankScript() async {
    if (!await _confirmDiscardUnsavedIfNeeded()) return;
    const blank = '''@init
dbg = 0;

@sample
''';
    _code.text = blank;
    _onCodeChanged(blank);
  }

  Future<void> _openWizard() async {
    if (!await _confirmDiscardUnsavedIfNeeded()) return;
    if (!mounted) return;
    final templateCode = await NewScriptWizardDialog.show(context);
    if (templateCode != null && mounted) {
      _code.text = templateCode;
      _onCodeChanged(templateCode);
    }
  }

  Future<void> _openApoConverter() async {
    if (!await _confirmDiscardUnsavedIfNeeded()) return;
    if (!mounted) return;
    final generated = await EqualizerApoDialog.show(context);
    if (generated != null && mounted) {
      _code.text = generated;
      _onCodeChanged(generated);
    }
  }

  Future<void> _importEelScript() async {
    if (!await _confirmDiscardUnsavedIfNeeded()) return;
    if (!mounted) return;
    final l = l10nOf(context);
    final path = await AuraPathPickerDialog.show(
      context,
      title: l.lpFileImportEel,
      mode: AuraPathPickerMode.file,
      allowedExtensions: const ['eel', 'txt'],
      memorySlot: PathMemory.slotLiveprogImportEel,
    );
    if (path != null && path.trim().isNotEmpty) {
      final file = File(path.trim());
      if (file.existsSync()) {
        try {
          final content = await file.readAsString(encoding: utf8);
          if (mounted) {
            _code.text = content;
            _onCodeChanged(content);
          }
        } catch (e, st) {
          // 用户主动导入失败必须有反馈（旧实现只写日志，用户会误以为成功）
          swallow(e, st);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(l10nOf(context).lpFileImportFailed),
              duration: const Duration(seconds: 3),
            ));
          }
        }
      }
    }
  }

  Future<void> _saveAs() async {
    final l = l10nOf(context);
    final selectedPath = await AuraPathPickerDialog.show(
      context,
      title: l.lpFileSaveAs,
      prompt: l.lpFileSaveAsPrompt,
      mode: AuraPathPickerMode.file,
      allowedExtensions: const ['eel', 'txt'],
      memorySlot: null, // 不记录到任何记忆和脚本库
    );
    if (selectedPath == null || selectedPath.trim().isEmpty) return;
    final file = File(selectedPath.trim());
    if (file.existsSync()) {
      if (!mounted) return;
      final name = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : selectedPath;
      final confirm = await LiveprogLibraryDialog.confirmOverwrite(
        context,
        name,
      );
      if (!confirm) return;
    }
    try {
      await file.writeAsString(_code.text, encoding: utf8);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l.lpSave),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e, st) {
      swallow(e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l.lpSaveFailed),
          duration: const Duration(seconds: 3),
        ));
      }
    }
  }

  // --- 脚本库弹窗 ---

  void _openLibrary() {
    LiveprogLibraryDialog.show(
      context,
      model: widget.model,
      currentCode: _code.text,
      isCodeDirty: _isCodeDirty,
      onSelectScript: (text, name) {
        _code.text = text;
        _onCodeChanged(text);
      },
    );
  }

  // --- 编辑下拉操作 ---

  void _handleEditAction(LiveprogEditAction action) {
    switch (action) {
      case LiveprogEditAction.findReplace:
        setState(() => _showFindReplace = !_showFindReplace);
        break;
      case LiveprogEditAction.toggleOutline:
        setState(() => _showOutline = !_showOutline);
        break;
      case LiveprogEditAction.format:
        _formatCode();
        break;
      case LiveprogEditAction.scrollToTop:
        _scrollToTop();
        break;
    }
  }

  void _openManual() {
    EelManualDialog.show(
      context,
      onInsertSnippet: _insertSnippet,
    );
  }

  void _insertSnippet(String snippet) {
    final text = _code.text;
    final sel = _code.selection;
    if (!sel.isValid) {
      final newText = text.isEmpty ? snippet : '$text\n\n$snippet';
      _code.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
      _onCodeChanged(newText);
      return;
    }
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final newText = text.replaceRange(start, end, snippet);
    _code.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + snippet.length),
    );
    _onCodeChanged(newText);
    _editorFocus.requestFocus();
  }

  Widget _buildCompileCapsule(
      BuildContext context, AuraPalette p, AppLocalizations l, AppModel m) {
    if (_compiling) {
      final lineCount = _code.text.split('\n').length;
      return _capsuleBody(
        p,
        p.accent,
        Icons.sync_rounded,
        '${l.lpCompilingScript} (Ln $lineCount)',
      );
    }

    final st = m.lpStatus;
    final err = m.lpError;
    final failed = st < 0 || (st == 0 && err != null);
    final ok = st == 1;
    final running = ok && m.lpEnabled;
    final slow = running && m.lpCompileMs >= 2000;

    String? tookStr;
    if (m.lpCompileMs >= 0) {
      tookStr = m.lpCompileMs >= 1000
          ? '${(m.lpCompileMs / 1000).toStringAsFixed(1)}s'
          : '${m.lpCompileMs}ms';
    }

    if (failed) {
      final mapped = switch (st) {
        0 => l.lpErrInitMissing,
        -1 => l.lpErrInitSyntax,
        -2 => l.lpErrSampleMissing,
        -3 => l.lpErrSampleSyntax,
        _ => null,
      };
      final t =
          '${l.lpStatusError}：${mapped ?? (err == null ? '' : localizeEngineError(err, l))}';
      return _capsuleBody(p, p.error, Icons.error_outline_rounded, t, err: err);
    }

    if (ok) {
      if (_isCodeDirty) {
        final tookPart = tookStr != null ? ' · ${l.lpCompileTook(tookStr)}' : '';
        final runningOld = m.lpEnabled ? ' (${l.lpRunningOldCode})' : '';
        return _capsuleBody(
          p,
          p.warning,
          Icons.edit_note_rounded,
          '${l.lpUncompiled}$runningOld$tookPart · Ctrl+Enter',
        );
      }
      if (running) {
        var t = l.lpStatusOk;
        if (tookStr != null) t = '$t · ${l.lpCompileTook(tookStr)}';
        if (slow) t = '$t · ${l.lpCompileSlow}';
        return _capsuleBody(
          p,
          slow ? p.warning : p.success,
          Icons.check_circle_outline_rounded,
          t,
        );
      } else {
        var t = l.lpCompileSuccess;
        if (tookStr != null) t = '$t ($tookStr)';
        t = '$t · ${l.lpCompiledIdle}';
        return _capsuleBody(
          p,
          p.accent,
          Icons.check_circle_outline_rounded,
          t,
        );
      }
    }

    if (_isCodeDirty) {
      return _capsuleBody(
        p,
        p.textDim,
        Icons.help_outline_rounded,
        '${l.lpStatusIdle} · Ctrl+Enter',
      );
    }
    return _capsuleBody(
      p,
      p.textDim,
      Icons.radio_button_unchecked_rounded,
      l.lpStatusIdle,
    );
  }

  Widget _buildMismatchBanner(
      AuraPalette p, AppLocalizations l, AppModel m) {
    if (!m.lpPresetCodeMismatch) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: p.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: p.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l.lpCodeMismatch,
              style: captionOf(p, color: p.warning),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(AuraPalette p, AppLocalizations l, AppModel m) {
    final st = m.lpStatus;
    final err = m.lpError;
    final failed = st < 0 || (st == 0 && err != null);

    final Widget statusBadge;
    if (_issues.isNotEmpty) {
      statusBadge = InkWell(
        onTap: () {
          setState(() => _showConsole = true);
          if (_issues.first.line > 0) _gotoLine(_issues.first.line);
        },
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded, size: 13, color: p.warning),
              const SizedBox(width: 4),
              Text(
                l.lpIssues(_issues.length),
                style: monoOf(p, size: 11, color: p.warning),
              ),
            ],
          ),
        ),
      );
    } else if (failed) {
      statusBadge = InkWell(
        onTap: () => setState(() => _showConsole = true),
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 13, color: p.error),
              const SizedBox(width: 4),
              Text(
                l.lpStatusError,
                style: monoOf(p, size: 11, color: p.error),
              ),
            ],
          ),
        ),
      );
    } else if (_isCodeDirty) {
      final runningOld = m.lpEnabled ? ' (${l.lpRunningOldCode})' : '';
      statusBadge = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note_rounded, size: 14, color: p.accent),
          const SizedBox(width: 4),
          Text(
            '${l.lpUncompiled}$runningOld',
            style: monoOf(p, size: 11, color: p.accent),
          ),
        ],
      );
    } else {
      statusBadge = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 13, color: p.success),
          const SizedBox(width: 4),
          Text(
            l.lpReady,
            style: monoOf(p, size: 11, color: p.success),
          ),
        ],
      );
    }

    return Row(
      children: [
        Text(
          'Ln $_cursorLine, Col $_cursorCol',
          style: monoOf(p, size: 11, color: p.textDim),
        ),
        const SizedBox(width: AuraSpace.md),
        Text(
          l.lpChars(_code.text.length),
          style: monoOf(p, size: 11, color: p.textDim),
        ),
        const Spacer(),
        statusBadge,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = AppLocalizations.of(context)!;
    final m = widget.model;

    final codeStyle = monoOf(p, size: _editorFontSize, color: p.text)
        .copyWith(height: 1.5);
    final codeStrut = StrutStyle(
      fontFamily: codeStyle.fontFamily,
      fontSize: codeStyle.fontSize,
      height: codeStyle.height,
      forceStrutHeight: true,
    );
    final calculatedLineHeight = _calculateLineHeight(codeStyle);
    final gutterFontSize = (_editorFontSize - 1.0).clamp(9.0, 22.0);
    final lineCount = _code.text.split('\n').length;
    final gutterWidth = LineNumberGutter.widthFor(
      lineCount: lineCount,
      fontSize: gutterFontSize,
    );
    final textScaler = MediaQuery.textScalerOf(context);

    return PageScaffold(
      eyebrow: l.lpEyebrowDsp,
      title: l.lpTitleEditor,
      children: [
        // ---- IDE 核心工作区卡片（顶栏 + 编译提示条 + 编辑器 + 状态行 + 控制台紧密组合）----
        Container(
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(AuraRadius.md),
            border: Border.all(color: p.hairline),
          ),
          padding: const EdgeInsets.all(AuraSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 顶栏工具行
              ListenableBuilder(
                listenable: m,
                builder: (_, _) => LiveprogIdeToolbar(
                  isApplied: m.lpEnabled,
                  isCompiling: _compiling,
                  isCodeDirty: _isCodeDirty,
                  hasCompiledSuccessfully:
                      m.lpStatus == 1 && m.lpError == null && !_isCodeDirty,
                  isConsoleOpen: _showConsole,
                  isOutlineOpen: _showOutline,
                  isFindReplaceOpen: _showFindReplace,
                  isEditorExpanded: _expandedEditor,
                  onToggleApply: _toggleApply,
                  onCompile: _compile,
                  onFileAction: _handleFileAction,
                  onOpenLibrary: _openLibrary,
                  onEditAction: _handleEditAction,
                  onOpenManual: _openManual,
                  onToggleConsole: () =>
                      setState(() => _showConsole = !_showConsole),
                  onToggleEditorExpand: () =>
                      setState(() => _expandedEditor = !_expandedEditor),
                ),
              ),
              const SizedBox(height: 6),

              // 2. 编译信息提示条 (根据状态智能响应且高度针对)
              ListenableBuilder(
                listenable: m,
                builder: (_, _) => _buildCompileCapsule(context, p, l, m),
              ),

              // 3. 指纹漂移警告 (若有)
              ListenableBuilder(
                listenable: m,
                builder: (_, _) {
                  if (!m.lpPresetCodeMismatch) return const SizedBox.shrink();
                  return Column(
                    children: [
                      const SizedBox(height: 6),
                      _buildMismatchBanner(p, l, m),
                    ],
                  );
                },
              ),

              // 4. 查找与替换工具条
              if (_showFindReplace) ...[
                const SizedBox(height: 4),
                FindReplaceBar(
                  codeController: _code,
                  onTextModified: () => _onCodeChanged(_code.text),
                  onClose: () => setState(() => _showFindReplace = false),
                ),
                const SizedBox(height: 4),
              ] else ...[
                const SizedBox(height: 6),
              ],

              // 5. 代码编辑器与大纲分栏
              Listener(
                onPointerSignal: _onEditorPointerSignal,
                child: Stack(
                  children: [
                    Container(
                      height: _expandedEditor ? 620 : 420,
                      decoration: BoxDecoration(
                        color: p.panelRaised,
                        borderRadius: BorderRadius.circular(AuraRadius.sm),
                        border: Border.all(color: p.hairline),
                      ),
                      child: LayoutBuilder(
                        builder: (context, box) {
                          // 编辑区文本可用宽度 = 内容区 − 大纲栏 − 行号栏 − 左右 contentPadding
                          final editorTextWidth = (box.maxWidth -
                                  (_showOutline ? 201.0 : 0.0) -
                                  gutterWidth -
                                  AuraSpace.md * 2)
                              .clamp(1.0, double.infinity);
                          final lineMetrics = _resolveLineMetrics(
                            text: _code.text,
                            style: codeStyle,
                            strutStyle: codeStrut,
                            textWidth: editorTextWidth,
                            textScaler: textScaler,
                            fallbackLineAdvance: calculatedLineHeight,
                          );

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_showOutline) ...[
                                SizedBox(
                                  width: 200,
                                  child: CodeOutlinePanel(
                                    code: _code.text,
                                    activeLine: _cursorLine,
                                    onSelectLine: _gotoLine,
                                  ),
                                ),
                                VerticalDivider(
                                    width: 1,
                                    thickness: 1,
                                    color: p.hairline),
                              ],
                              LineNumberGutter(
                                editorScrollCtrl: _editorScrollCtrl,
                                metrics: lineMetrics,
                                errorLines: _code.errorLines,
                                activeLine: _cursorLine,
                                onSelectLine: _gotoLine,
                                fontSize: gutterFontSize,
                              ),
                              Expanded(
                                child: CallbackShortcuts(
                                  bindings: <ShortcutActivator, VoidCallback>{
                                    const SingleActivator(LogicalKeyboardKey.keyF,
                                        control: true): () {
                                      setState(() =>
                                          _showFindReplace = !_showFindReplace);
                                    },
                                    const SingleActivator(LogicalKeyboardKey.keyS,
                                        control: true): _saveAs,
                                    const SingleActivator(
                                        LogicalKeyboardKey.enter,
                                        control: true): _compile,
                                  },
                                  child: Actions(
                                    actions: <Type, Action<Intent>>{
                                      _EelTabIntent: _EelTabAction(),
                                    },
                                    child: Shortcuts(
                                      shortcuts:
                                          const <ShortcutActivator, Intent>{
                                        SingleActivator(LogicalKeyboardKey.tab):
                                            _EelTabIntent(shift: false),
                                        SingleActivator(LogicalKeyboardKey.tab,
                                            shift: true):
                                            _EelTabIntent(shift: true),
                                      },
                                      child: TextField(
                                        controller: _code,
                                        focusNode: _editorFocus,
                                        scrollController: _editorScrollCtrl,
                                        maxLines: null,
                                        expands: true,
                                        style: codeStyle,
                                        strutStyle: codeStrut,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          contentPadding:
                                              EdgeInsets.all(AuraSpace.md),
                                        ),
                                        onChanged: _onCodeChanged,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if ((_editorFontSize - _kDefaultFontSize).abs() > 0.01)
                      Positioned(
                        top: 6,
                        left: _showOutline ? 206 : 6,
                        child: Tooltip(
                          message:
                              '${(_editorFontSize / _kDefaultFontSize * 100).round()}% (${l10nOf(context).liveprogFontReset})',
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _resetEditorFontSize,
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: p.panelRaised.withValues(alpha: 0.95),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: p.accent.withValues(alpha: 0.75),
                                    width: 1.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.35),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.restart_alt_rounded,
                                  size: 13,
                                  color: p.accent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),

              // 6. 底部状态行
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: ListenableBuilder(
                  listenable: m,
                  builder: (_, _) => _buildStatusBar(p, l, m),
                ),
              ),

              // 7. 控制台与诊断输出面板（折叠/展开）
              if (_showConsole) ...[
                const SizedBox(height: 6),
                LiveprogConsolePanel(
                  model: m,
                  isCompiling: _compiling,
                  activeSliders: _activeSliders,
                  issues: _issues,
                  onGotoLine: _gotoLine,
                  onClose: () => setState(() => _showConsole = false),
                ),
              ],
            ],
          ),
        ),

        // ---- 脚本参数调节滑块面板 ----
        LiveprogSlidersPanel(
          model: m,
          activeSliders: _activeSliders,
        ),
      ],
    );
  }
}

/* ---- Tab 缩进意图 ---- */
class _EelTabIntent extends Intent {
  final bool shift;
  const _EelTabIntent({this.shift = false});
}

class _EelTabAction extends Action<_EelTabIntent> {
  _EelTabAction();

  @override
  Object? invoke(covariant _EelTabIntent intent) {
    final ctx = primaryFocus?.context;
    if (ctx != null) {
      final state = ctx.findAncestorStateOfType<_LiveprogPageState>();
      state?._insertTab(indentLess: intent.shift);
    }
    return null;
  }
}
