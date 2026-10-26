/*
 * liveprog_page.dart — 实时可编程 DSP（EEL2）编辑页（engine_api v1.1）
 *
 * 优化与提升：
 * 1. 编辑器语法高亮（EelSyntaxTextEditingController：段指令、控制流、内置变量、函数、常量、注释）
 * 2. 文本对齐与格式化（EelFormatter：层级缩进、操作符空格、连续赋值等号对齐、分号规整）
 * 3. 自适应滑块调节（EelSliderParser：根据代码引用及声明动态呈现活跃参数与自定义名称/范围）
 * 4. 外部预设文件夹加载（多目录递归遍历 .eel / .txt，一键加载生效）
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/design.dart';
import '../core/config.dart';
import '../core/engine_error_map.dart';
import '../core/path_memory.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'eel_editor_support.dart';
import 'liveprog/code_outline_panel.dart';
import 'liveprog/eel_manual_panel.dart';
import 'liveprog/equalizer_apo_dialog.dart';
import 'liveprog/find_replace_bar.dart';
import 'liveprog/new_script_wizard_dialog.dart';
import 'chrome.dart';
import 'widgets.dart';

import '../core/error_sink.dart';
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
    margin: const EdgeInsets.only(bottom: AuraSpace.md),
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
  int _cursorLine = 1, _cursorCol = 1;
  List<EelLintIssue> _issues = const [];

  late final EelSyntaxTextEditingController _code =
      EelSyntaxTextEditingController(text: LiveprogLibrary.template);

  List<LiveprogItem> _libraryItems = const [];
  int _skippedCount = 0;
  Map<int, EelSliderMeta> _activeSliders = {};
  bool _showAllSliders = false;
  // v3 §3.4：编译往返 guard——防抖 + 编译中禁用应用键。
  bool _compiling = false;
  int _lastApplyMs = 0;
  Timer? _compileFallback;

  // IDE 交互状态
  bool _showFindReplace = false;
  bool _showOutline = false;
  bool _showConsole = false;

  final TextEditingController _libraryNameController =
      TextEditingController(text: 'my-script');

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModelTick);
    _refreshLibrary();
    _activeSliders = EelSliderParser.parse(_code.text);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runLint();
  }

  /// 引擎回了编译结果（成功或失败）→ 松开应用键。
  void _onModelTick() {
    if (_compiling &&
        (widget.model.lpStatus == 1 || widget.model.lpError != null)) {
      _compileFallback?.cancel();
      if (mounted) setState(() => _compiling = false);
    }
  }

  void _refreshLibrary() {
    final items =
        LiveprogLibrary.listAll(widget.model.config.customScriptDirs);
    setState(() {
      _libraryItems = items;
      _skippedCount = LiveprogLibrary.lastSkipped;
    });
  }

  /// 即时 lint + 光标行列 + 自适应滑块解析
  void _onCodeChanged(String text) {
    _runLint();
    setState(() {
      _activeSliders = EelSliderParser.parse(text);
    });
    final sel = _code.selection;
    if (sel.isValid) {
      final before = text.substring(0, sel.baseOffset.clamp(0, text.length));
      final nl = before.lastIndexOf('\n');
      setState(() {
        _cursorLine = nl < 0 ? 1 : before.split('\n').length;
        _cursorCol = before.length - (nl < 0 ? 0 : nl);
      });
    }
  }

  void _runLint() {
    setState(() => _issues = EelLinter.lint(l10nOf(context), _code.text));
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

  void _insertTab({required bool indentLess}) {
    final text = _code.text;
    final sel = _code.selection;
    if (!sel.isValid || sel.isCollapsed) {
      if (!indentLess) {
        final pos = sel.baseOffset.clamp(0, text.length);
        final newText = '${text.substring(0, pos)}\t${text.substring(pos)}';
        _code.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: pos + 1),
        );
      } else {
        final lineStart = text.lastIndexOf('\n', sel.baseOffset - 1) + 1;
        if (text.startsWith('\t', lineStart)) {
          final newText = text.substring(0, lineStart) +
              text.substring(lineStart + 1);
          _code.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(
                offset: (sel.baseOffset - 1).clamp(0, newText.length)),
          );
        }
      }
      return;
    }
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final lineStart = text.lastIndexOf('\n', start <= 0 ? 0 : start - 1) + 1;
    final affected = text.substring(lineStart, end);
    final lines = affected.split('\n');
    final rebuilt = lines.map((l) {
      if (indentLess) {
        return l.startsWith('\t') ? l.substring(1) : l;
      }
      return '\t$l';
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
    _runLint();
  }

  void _apply() {
    final text = _code.text;
    if (text.trim().isEmpty) return;
    // v1.2 §3.3：引擎必拒的结构问题（缺段/空 @init）本地拦截，不下发编译。
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
    // v3 §3.4：编译往返未归前忽略连击；500ms 防抖。
    // 引擎未连接时无状态事件回包，靠 5s 兜底松开按钮（只放行 UI，不中断编译）。
    if (_compiling) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastApplyMs < 500) return;
    _lastApplyMs = now;
    setState(() => _compiling = true);
    widget.model.setLiveprogCode(text);
    _compileFallback?.cancel();
    _compileFallback = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _compiling = false);
    });
  }

  void _save() {
    final name = _libraryNameController.text.trim();
    if (name.isEmpty) return;
    final fileName = name.endsWith('.eel') ? name : '$name.eel';
    // v3 §3.5：目标已存在 → 先弹覆盖确认，不再静默覆盖。
    final target =
        File('${LiveprogLibrary.dir}${Platform.pathSeparator}$fileName');
    if (target.existsSync()) {
      _confirmDialog(
        title: l10nOf(context).lpOverwriteTitle,
        body: l10nOf(context).lpOverwriteBody,
        actionLabel: l10nOf(context).lpOverwriteAction,
        danger: true,
        onConfirm: _doSave,
      );
      return;
    }
    _doSave();
  }

  void _doSave() {
    final name = _libraryNameController.text.trim();
    if (name.isEmpty) return;
    final ok = LiveprogLibrary.save(
        name.endsWith('.eel') ? name : '$name.eel', _code.text);
    _refreshLibrary();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(ok ? l10nOf(context).lpSaved(name) : l10nOf(context).lpSaveFailed,
          style: TextStyle(color: paletteOf(context).text, fontSize: 13)),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 通用确认框（覆盖/删除共用）：取消走 dlgCancel，确认键可标 danger。
  void _confirmDialog({
    required String title,
    required String body,
    required String actionLabel,
    required bool danger,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          title: Text(title, style: sectionOf(p)),
          content: Text(body, style: captionOf(p)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10nOf(ctx).dlgCancel, style: labelOf(p)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: danger ? p.error : p.accent,
                foregroundColor: danger
                    ? Colors.white
                    : p.accentContrast,
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                onConfirm();
              },
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openWizard() async {
    final templateCode = await NewScriptWizardDialog.show(context);
    if (templateCode != null && mounted) {
      _code.text = templateCode;
      _onCodeChanged(templateCode);
    }
  }

  Future<void> _openApoConverter() async {
    final generated = await EqualizerApoDialog.show(context);
    if (generated != null && mounted) {
      _code.text = generated;
      _onCodeChanged(generated);
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

  Widget _buildConsolePanel(AuraPalette p, dynamic l, AppModel m) {
    final st = m.lpStatus;
    final err = m.lpError;
    final hasErr = st < 0 || (st == 0 && err != null);
    final statusColor = _compiling
        ? p.accent
        : (hasErr ? p.error : (st == 1 ? p.success : p.textDim));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.terminal_rounded, size: 14, color: statusColor),
              const SizedBox(width: AuraSpace.xs),
              Text(
                l.lpConsole,
                style: monoOf(p, size: 11, color: statusColor),
              ),
              const Spacer(),
              Text(
                'VM: EEL2/NSEEL · ${m.engineRate}Hz · ${m.lpCompileMs >= 0 ? '${m.lpCompileMs}ms' : '0ms'}',
                style: monoOf(p, size: 10, color: p.textDim),
              ),
              const SizedBox(width: AuraSpace.xs),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 13),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: l.dlgClose,
                onPressed: () => setState(() => _showConsole = false),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          Divider(color: p.hairline, height: 1),
          const SizedBox(height: AuraSpace.xs),
          if (_compiling)
            Text(
              '> Compiling script...',
              style: monoOf(p, size: 11, color: p.accent),
            )
          else if (hasErr && err != null) ...[
            Text(
              '> [ERROR] Exit code: $st',
              style: monoOf(p, size: 11, color: p.error),
            ),
            const SizedBox(height: 2),
            SelectableText(
              err,
              style: monoOf(p, size: 11, color: p.error),
            ),
          ] else ...[
            Text(
              '> [OK] Script compiled successfully. Real-time audio stream ready.',
              style: monoOf(p, size: 11, color: p.success),
            ),
            if (_activeSliders.isNotEmpty)
              Text(
                '> Sliders bound: ${_activeSliders.keys.map((k) => 'slider$k').join(', ')}',
                style: monoOf(p, size: 10.5, color: p.textDim),
              ),
          ],
          if (_issues.isNotEmpty) ...[
            const SizedBox(height: AuraSpace.xs),
            for (final issue in _issues)
              InkWell(
                onTap: issue.line > 0 ? () => _gotoLine(issue.line) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 11, color: p.warning),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          issue.line > 0
                              ? l.lpIssueAt(issue.line, issue.message)
                              : issue.message,
                          style: monoOf(p, size: 10.5, color: p.warning),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _deleteItem(LiveprogItem item) {
    _confirmDialog(
      title: l10nOf(context).lpDeleteTitle,
      body: '${item.name}\n${l10nOf(context).lpDeleteBody}',
      actionLabel: l10nOf(context).lpDeleteAction,
      danger: true,
      onConfirm: () {
        final ok = LiveprogLibrary.deletePath(
            item.path, widget.model.config.customScriptDirs);
        _refreshLibrary();
        if (!ok && mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(l10nOf(context).lpOpFailed,
                style: TextStyle(
                    color: paletteOf(context).text, fontSize: 13)),
            duration: const Duration(seconds: 2),
          ));
        }
      },
    );
  }

  void _renameItem(LiveprogItem item) {
    final ctrl = TextEditingController(text: item.name);
    // 对话框 pop 后 ctx 即失效，文案提前取好。
    final l = l10nOf(context);
    final pal = paletteOf(context);
    showDialog(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          title: Text(l.lpRenameTitle, style: sectionOf(p)),
          content: TextField(
            controller: ctrl,
            style: monoOf(p, size: 12),
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                borderSide: BorderSide(color: p.hairline),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 8),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.dlgCancel, style: labelOf(p)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                final ok = LiveprogLibrary.renamePath(item.path,
                    ctrl.text.trim(), widget.model.config.customScriptDirs);
                _refreshLibrary();
                if (!ok && mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                    content: Text(l.lpOpFailed,
                        style: TextStyle(
                            color: pal.text, fontSize: 13)),
                    duration: const Duration(seconds: 2),
                  ));
                }
              },
              child: Text(l.dlgSave),
            ),
          ],
        );
      },
    );
  }

  void _addExternalScriptDirDialog() {
    final ctrl = TextEditingController(
        text: PathMemory.dirFor(PathMemory.slotLastScriptDir) ?? '');
    showDialog(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          title: Text(l10nOf(ctx).lpAddDirTitle, style: sectionOf(p)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10nOf(ctx).lpAddDirPrompt, style: captionOf(p)),
              const SizedBox(height: AuraSpace.sm),
              TextField(
                controller: ctrl,
                style: monoOf(p, size: 12),
                decoration: InputDecoration(
                  hintText: l10nOf(ctx).lpAddDirExample,
                  hintStyle: captionOf(p),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    borderSide: BorderSide(color: p.hairline),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10nOf(ctx).dlgCancel, style: labelOf(p)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
              ),
              onPressed: () {
                final path = ctrl.text.trim();
                if (path.isNotEmpty) {
                  PathMemory.setDir(PathMemory.slotLastScriptDir, path);
                  widget.model.addCustomScriptDir(path);
                  Navigator.of(ctx).pop();
                  _refreshLibrary();
                }
              },
              child: Text(l10nOf(ctx).dlgAdd),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelTick);
    _compileFallback?.cancel();
    _editorFocus.dispose();
    _code.dispose();
    _libraryNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;

    return PageScaffold(
      eyebrow: l.pageLiveprogEyebrow,
      title: l.pageLiveprogTitle,
      children: [
        // ---- 01 编辑卡 ----
        SectionCard(
          index: '01',
          title: l.lpEditor,
          titleTooltip: l.lpEditorTooltip,
          trailing: ListenableBuilder(
            listenable: m,
            builder: (_, _) => AuraSwitch(
              value: m.lpEnabled,
              onChanged: (v) => m.setLiveprogEnabled(v),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 工具行
              Wrap(
                spacing: AuraSpace.sm,
                runSpacing: AuraSpace.sm,
                children: [
                  // v3 §3.4：编译中禁用应用键（视觉置灰 + 忽略点击）
                  IgnorePointer(
                    ignoring: _compiling,
                    child: Opacity(
                      opacity: _compiling ? 0.4 : 1.0,
                      child: AuraChip(l.lpApply,
                          icon: _compiling
                              ? Icons.sync_rounded
                              : Icons.play_arrow_rounded,
                          onTap: _apply),
                    ),
                  ),
                  AuraChip(l.lpUnload,
                      icon: Icons.stop_rounded,
                      danger: true,
                      onTap: () => m.unloadLiveprog()),
                  AuraChip(l.lpNewScriptWizard,
                      icon: Icons.auto_stories_rounded,
                      onTap: _openWizard),
                  AuraChip(l.lpApoImportTitle,
                      icon: Icons.transform_rounded,
                      onTap: _openApoConverter),
                  AuraChip(l.lpFindReplace,
                      icon: Icons.search_rounded,
                      selected: _showFindReplace,
                      onTap: () => setState(() => _showFindReplace = !_showFindReplace)),
                  AuraChip(l.lpOutline,
                      icon: Icons.account_tree_outlined,
                      selected: _showOutline,
                      onTap: () => setState(() => _showOutline = !_showOutline)),
                  AuraChip(l.lpFormat,
                      icon: Icons.format_align_left_rounded, onTap: _formatCode),
                  AuraChip(l.lpManual,
                      icon: Icons.menu_book_rounded,
                      onTap: _openManual),
                  AuraChip(l.lpConsole,
                      icon: Icons.terminal_rounded,
                      selected: _showConsole,
                      onTap: () => setState(() => _showConsole = !_showConsole)),
                ],
              ),
              const SizedBox(height: AuraSpace.md),

              // 编译状态胶囊（v1.2 §3.1：lpStatus/lpError 内联可见，
              // 不依赖一闪而过的全局 EventBanner；status==0 且有 lpError
              // 视为失败——引擎 rc=0（@init 缺失）与“未加载”同值，靠 lpError 区分）
              ListenableBuilder(
                listenable: m,
                builder: (_, _) {
                  // v3：编译中优先展示（_compiling 为页内态，随 setState 重建）。
                  if (_compiling) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: AuraSpace.md),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: p.accent.withValues(alpha: 0.10),
                        borderRadius:
                            BorderRadius.circular(AuraRadius.sm),
                        border: Border.all(
                            color: p.accent.withValues(alpha: 0.45)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.sync_rounded,
                              size: 14, color: p.accent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              l.lpCompiling,
                              style: captionOf(p, color: p.accent),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final st = m.lpStatus;
                  final err = m.lpError;
                  final failed = st < 0 || (st == 0 && err != null);
                  final ok = st == 1;
                  // v3.1：编译成功 ≠ 在生效——右上角开关（lpEnabled）关着时
                  // 引擎 LiveProgDisable，脚本静默。两种绿/灰必须分开，
                  // 否则“运行中”名不副实。
                  final running = ok && m.lpEnabled;
                  final compiledIdle = ok && !m.lpEnabled;
                  // v3：慢编译（≥2s）降级为警告色——持锁编译饿音频泵，提醒勿连击。
                  // running 为真才看耗时；仅编译未启用时不谈耗时（还没进链）。
                  final slow = running && m.lpCompileMs >= 2000;
                  final Color c = running
                      ? (slow ? p.warning : p.success)
                      : (failed
                          ? p.error
                          : p.textDim);
                  final String text;
                  if (running) {
                    text = l.lpStatusOk;
                    var t = text;
                    if (m.lpCompileMs >= 0) {
                      final took = m.lpCompileMs >= 1000
                          ? '${(m.lpCompileMs / 1000).toStringAsFixed(1)}s'
                          : '${m.lpCompileMs}ms';
                      t = '$t · ${l.lpCompileTook(took)}';
                    }
                    if (slow) t = '$t · ${l.lpCompileSlow}';
                    return _capsuleBody(
                        p, c, Icons.check_circle_outline_rounded, t);
                  } else if (compiledIdle) {
                    return _capsuleBody(p, c,
                        Icons.pause_circle_outline_rounded, l.lpCompiledIdle);
                  } else if (!failed) {
                    return _capsuleBody(p, c,
                        Icons.radio_button_unchecked_rounded, l.lpStatusIdle);
                  } else {
                    final mapped = switch (st) {
                      0 => l.lpErrInitMissing,
                      -1 => l.lpErrInitSyntax,
                      -2 => l.lpErrSampleMissing,
                      -3 => l.lpErrSampleSyntax,
                      _ => null,
                    };
                    // B-2：lpError 兜底走本地化（token 命中→词条；EEL 原文透传）
                    final t = '${l.lpStatusError}：${mapped ?? (err == null ? '' : localizeEngineError(err, l))}';
                    return _capsuleBody(
                        p, c, Icons.error_outline_rounded, t,
                        err: err);
                  }
                },
              ),

              // 指纹漂移徽标（v2：预设恢复的滑块可能对不上当前代码，醒目提示）
              ListenableBuilder(
                listenable: m,
                builder: (_, _) {
                  if (!m.lpPresetCodeMismatch) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    margin: const EdgeInsets.only(bottom: AuraSpace.md),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: p.warning.withValues(alpha: 0.10),
                      borderRadius:
                          BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(
                          color: p.warning.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 14, color: p.warning),
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
                },
              ),

              // 查找与替换工具条
              if (_showFindReplace) ...[
                FindReplaceBar(
                  codeController: _code,
                  onTextModified: () => _onCodeChanged(_code.text),
                  onClose: () => setState(() => _showFindReplace = false),
                ),
                const SizedBox(height: AuraSpace.sm),
              ],

              // 代码编辑器与大纲分栏（支持语法着色与大纲跳转）
              Container(
                height: 420,
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.md),
                  border: Border.all(color: p.hairline),
                ),
                child: Row(
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
                      VerticalDivider(width: 1, thickness: 1, color: p.hairline),
                    ],
                    Expanded(
                      child: Actions(
                        actions: <Type, Action<Intent>>{
                          _EelTabIntent: _EelTabAction(),
                        },
                        child: Shortcuts(
                          shortcuts: const <ShortcutActivator, Intent>{
                            SingleActivator(LogicalKeyboardKey.tab):
                                _EelTabIntent(shift: false),
                            SingleActivator(LogicalKeyboardKey.tab, shift: true):
                                _EelTabIntent(shift: true),
                          },
                          child: TextField(
                            controller: _code,
                            focusNode: _editorFocus,
                            maxLines: null,
                            expands: true,
                            style: monoOf(p, size: 12.5, color: p.text),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(AuraSpace.md),
                            ),
                            onChanged: _onCodeChanged,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AuraSpace.xs),

              // 底部状态栏
              Row(
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
                  if (_issues.isEmpty)
                    Row(
                      children: [
                        Icon(Icons.check_circle_outline_rounded,
                            size: 13, color: p.success),
                        const SizedBox(width: 4),
                        Text(l.lpReady,
                            style: monoOf(p, size: 11, color: p.success)),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 13, color: p.warning),
                        const SizedBox(width: 4),
                        Text(
                          l.lpIssues(_issues.length),
                          style: monoOf(p, size: 11, color: p.warning),
                        ),
                      ],
                    ),
                ],
              ),

              // 控制台面板
              if (_showConsole) ...[
                const SizedBox(height: AuraSpace.sm),
                _buildConsolePanel(p, l, m),
              ],

              // Lint 提示列表（在控制台关闭时作为轻量胶囊呈现）
              if (_issues.isNotEmpty && !_showConsole) ...[
                const SizedBox(height: AuraSpace.xs),
                Wrap(
                  spacing: AuraSpace.xs,
                  runSpacing: 2,
                  children: [
                    for (final issue in _issues.take(4))
                      InkWell(
                        onTap: issue.line > 0
                            ? () => _gotoLine(issue.line)
                            : null,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Text(
                            issue.line > 0
                                ? l.lpIssueAt(issue.line, issue.message)
                                : issue.message,
                            style: captionOf(p, color: p.warning),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),

        // ---- 02 自适应滑块调节 ----
        SectionCard(
          index: '02',
          title: l.lpSliders,
          hint: l.lpSlidersHint,
          trailing: AuraChip(
            _showAllSliders ? l.lpShowAll : l.lpAdaptive(_activeSliders.length),
            icon: Icons.tune_rounded,
            selected: !_showAllSliders,
            onTap: () => setState(() => _showAllSliders = !_showAllSliders),
          ),
          child: ListenableBuilder(
            listenable: m,
            builder: (_, _) {
              if (!_showAllSliders && _activeSliders.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(AuraSpace.md),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.tune_outlined, size: 28, color: p.textDim),
                      const SizedBox(height: 6),
                      Text(
                        l.lpNoSliders,
                        style: captionOf(p),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _showAllSliders = true),
                        icon: const Icon(Icons.expand_more_rounded, size: 14),
                        label: Text(l.lpExpandSliders),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.accent,
                          side: BorderSide(color: p.hairline),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                );
              }

              final displayedIndices = _showAllSliders
                  ? List.generate(8, (i) => i + 1)
                  : (_activeSliders.keys.toList()..sort());

              return Column(
                children: [
                  for (final idx in displayedIndices)
                    _LpSlider(
                      model: m,
                      index: idx - 1,
                      meta: _activeSliders[idx],
                    ),
                ],
              );
            },
          ),
        ),

        // ---- 03 脚本库与外部预设 ----
        SectionCard(
          index: '03',
          title: l.lpLibrary,
          hint: l.lpLibraryHint,
          trailing: OutlinedButton.icon(
            onPressed: _addExternalScriptDirDialog,
            icon: const Icon(Icons.create_new_folder_rounded, size: 15),
            label: Text(l.lpAddDir),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.accent,
              side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
              visualDensity: VisualDensity.compact,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 外部文件夹徽章列表
              if (m.config.customScriptDirs.isNotEmpty) ...[
                Wrap(
                  spacing: AuraSpace.sm,
                  runSpacing: AuraSpace.xs,
                  children: m.config.customScriptDirs.map((dir) {
                    return Chip(
                      avatar: const Icon(Icons.folder_open_rounded, size: 15),
                      label: Text(dir, style: monoOf(p, size: 10.5)),
                      backgroundColor: p.panelRaised,
                      side: BorderSide(color: p.hairline),
                      deleteIcon: const Icon(Icons.close_rounded, size: 13),
                      onDeleted: () {
                        m.removeCustomScriptDir(dir);
                        _refreshLibrary();
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: AuraSpace.md),
                Divider(color: p.hairline, height: 1),
                const SizedBox(height: AuraSpace.md),
              ],

              // 预设列表
              if (_libraryItems.isEmpty)
                Text(l.lpLibraryEmpty, style: captionOf(p))
              else
                Wrap(
                  spacing: AuraSpace.xs,
                  runSpacing: AuraSpace.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final item in _libraryItems)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AuraChip(
                            item.isExternal
                                ? '${item.name} [${item.folderName}]'
                                : item.name,
                            icon: item.isExternal
                                ? Icons.folder_shared_rounded
                                : Icons.description_outlined,
                            onTap: () async {
                              final text =
                                  await LiveprogLibrary.loadFromPath(
                                      item.path);
                              if (text != null && mounted) {
                                setState(() {
                                  _code.text = text;
                                  _onCodeChanged(text);
                                });
                              }
                            },
                          ),
                          // v3 §3.5：库管理——重命名 / 删除（删前确认）。
                          IconButton(
                            tooltip: l.lpRenameTitle,
                            visualDensity: VisualDensity.compact,
                            iconSize: 14,
                            color: p.textDim,
                            icon: const Icon(Icons
                                .drive_file_rename_outline_rounded),
                            onPressed: () => _renameItem(item),
                          ),
                          IconButton(
                            tooltip: l.lpDeleteTitle,
                            visualDensity: VisualDensity.compact,
                            iconSize: 14,
                            color: p.textDim,
                            icon: const Icon(
                                Icons.delete_outline_rounded),
                            onPressed: () => _deleteItem(item),
                          ),
                        ],
                      ),
                  ],
                ),
              // v3 §3.5：门限隔离提示（超限/损坏文件被跳过，不中断整批）。
              if (_skippedCount > 0) ...[
                const SizedBox(height: AuraSpace.xs),
                Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 12, color: p.warning),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        l.lpSkipped(_skippedCount),
                        style: captionOf(p, color: p.warning),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AuraSpace.md),

              // 保存脚本
              Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _libraryNameController,
                      style: monoOf(p, size: 12.5, color: p.text),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'my-script',
                        hintStyle: monoOf(p, size: 12.5, color: p.textDim),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AuraSpace.md, vertical: AuraSpace.sm),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AuraRadius.sm),
                          borderSide: BorderSide(color: p.hairline),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AuraSpace.sm),
                  AuraChip(l.lpSave, icon: Icons.save_outlined, onTap: _save),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 自适应滑块调节行组件
class _LpSlider extends StatelessWidget {
  final AppModel model;
  final int index;
  final EelSliderMeta? meta;

  const _LpSlider({
    required this.model,
    required this.index,
    this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    // v2 §3.2：无声明时的默认域与 Parser 回填（0<0,1>）一致，不再是 -1..4。
    final minVal = meta?.minVal ?? 0.0;
    final maxVal = meta?.maxVal ?? 1.0;
    final displayName = meta?.displayName ?? 'slider${index + 1}';
    final rawName = 'slider${index + 1}';
    final currentVal = model.lpParams[index].clamp(minVal, maxVal);

    return Padding(
      padding: const EdgeInsets.only(bottom: AuraSpace.xs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        meta != null ? FontWeight.bold : FontWeight.normal,
                    color: meta != null ? p.accent : p.text,
                  ),
                ),
                Text(
                  rawName,
                  style: monoOf(p, size: 9.5, color: p.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
              ),
              child: Slider(
                value: currentVal,
                min: minVal,
                max: maxVal,
                onChanged: (v) => model.setLiveprogParam(index, v),
              ),
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          SizedBox(
            width: 58,
            child: Text(
              currentVal.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: monoOf(p, size: 12, color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// 脚本库条目
class LiveprogItem {
  final String name;
  final String path;
  final bool isExternal;
  final String folderName;

  const LiveprogItem({
    required this.name,
    required this.path,
    this.isExternal = false,
    this.folderName = '',
  });
}

/* ---- 脚本库（本地文件系统与外部文件夹聚合） ---- */
abstract final class LiveprogLibrary {
  static String? _dir;

  /// 脚本入口 FileGate L1（v3 §3.5）：单文件 ≤1MB，超限/坏文件隔离计数，
  /// 不中断整批加载。
  static const maxScriptBytes = 1024 * 1024;

  /// 最近一次 listAll 跳过的文件数（超限或不可读），供页面提示。
  static int lastSkipped = 0;

  /// 门检：null = 放行，否则为原因码（'tooLarge' / 'unreadable'）。
  /// 纯函数，可单测（对照：引擎侧 FileGate 管 IR/磁盘镜像，这里管脚本入口）。
  static String? gateCheck(File f) {
    try {
      if (f.lengthSync() > maxScriptBytes) return 'tooLarge';
      // 全文 UTF-8 试解码：malformed 抛 FormatException → 隔离。
      f.readAsStringSync(encoding: utf8);
      return null;
    } catch (e, st) {
      swallow(e, st);
      return 'unreadable';
    }
  }

  /// 统一走 ConfigManager.baseDir（此前自行拼 APPDATA，
  /// 非 Windows 上会落到相对路径 ./AuraDSP，与其它子系统分家）
  static String get dir => _dir ??= ConfigManager.path('liveprog');

  /// 聚合本地库与用户自定义外部目录
  static List<LiveprogItem> listAll(List<String> customDirs) {
    final items = <LiveprogItem>[];
    lastSkipped = 0;

    void collect(Directory d, {required bool external, required String folder}) {
      for (final f in d.listSync().whereType<File>()) {
        final p = f.path.toLowerCase();
        if (!(p.endsWith('.eel') || p.endsWith('.txt'))) continue;
        // v3 §3.5：坏文件隔离——跳过并计数，不中断整批。
        if (gateCheck(f) != null) {
          lastSkipped++;
          continue;
        }
        items.add(LiveprogItem(
          name: f.uri.pathSegments.last,
          path: f.path,
          isExternal: external,
          folderName: folder,
        ));
      }
    }

    // 1. 本地默认目录
    try {
      final d = Directory(dir);
      if (d.existsSync()) collect(d, external: false, folder: 'Local');
    } catch (e, st) { swallow(e, st); }

    // 2. 外部预设目录
    for (final cDir in customDirs) {
      try {
        final d = Directory(cDir);
        if (!d.existsSync()) continue;
        final segments = d.uri.pathSegments.where((s) => s.isNotEmpty);
        final folderName = segments.isNotEmpty ? segments.last : cDir;
        for (final f in d.listSync(recursive: true).whereType<File>()) {
          final p = f.path.toLowerCase();
          if (!(p.endsWith('.eel') || p.endsWith('.txt'))) continue;
          if (gateCheck(f) != null) {
            lastSkipped++;
            continue;
          }
          items.add(LiveprogItem(
            name: f.uri.pathSegments.last,
            path: f.path,
            isExternal: true,
            folderName: folderName,
          ));
        }
      } catch (e, st) { swallow(e, st); }
    }

    items.sort((a, b) => a.name.compareTo(b.name));
    return items;
  }

  static Future<String?> loadFromPath(String filePath) async {
    try {
      final f = File(filePath);
      // v3 §3.5：加载时复检（列出后文件可能被换掉/变大）。
      if (gateCheck(f) != null) return null;
      return await f.readAsString(encoding: utf8);
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /// 路径收敛：只允许操作本地库或已登记外部目录之下的文件，
  /// 防止调用方误传任意路径造成越界删除。
  static bool _isUnderLibrary(String filePath, List<String> customDirs) {
    final abs = File(filePath).absolute.path;
    final roots = <String>[Directory(dir).absolute.path, ...customDirs];
    for (final r in roots) {
      final root = Directory(r).absolute.path;
      if (abs == root) continue;
      if (abs.startsWith(root + Platform.pathSeparator)) return true;
    }
    return false;
  }

  /// 删除库内脚本（先判收敛；不存在视为成功，幂等）。
  static bool deletePath(String filePath, List<String> customDirs) {
    try {
      if (!_isUnderLibrary(filePath, customDirs)) return false;
      final f = File(filePath);
      if (!f.existsSync()) return true;
      f.deleteSync();
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 重命名库内脚本（同目录内先写后删；目标已存在则拒绝，由调用方弹覆盖确认）。
  static bool renamePath(
      String oldPath, String newName, List<String> customDirs) {
    try {
      if (newName.contains(RegExp(r'[\\/:*?"<>|]')) || newName.contains('..')) {
        return false;
      }
      if (!_isUnderLibrary(oldPath, customDirs)) return false;
      final old = File(oldPath);
      if (!old.existsSync() || gateCheck(old) != null) return false;
      final sep = Platform.pathSeparator;
      final parent = old.parent.path;
      final target = File('$parent$sep$newName');
      if (target.existsSync()) return false;
      target.writeAsStringSync(old.readAsStringSync(encoding: utf8));
      old.deleteSync();
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  static bool save(String name, String text) {
    try {
      if (name.contains(RegExp(r'[\\/:*?"<>|]')) || name.contains('..')) {
        return false;
      }
      // v3 §3.5：写入同样受 1MB 门限约束。
      if (utf8.encode(text).length > maxScriptBytes) return false;
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      File('$dir${Platform.pathSeparator}$name').writeAsStringSync(text);
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 新建模板：@init 段必须含至少一条语句（vendor 解析器约束）
  static const template = '''/* AuraDSP Liveprog — EEL2 实时脚本
 * 寄存器：spl0/spl1 = 左右样本（读写）, srate = 采样率
 * slider1..8 = 页面滑块（实时生效）
 * 支持头部定义参数：slider1:1.0<0,2,0.01>总音量增益
 */
slider1:1.0<0,2,0.01>总音量增益

@init
dbg = 0;

@sample
spl0 *= slider1;
spl1 *= slider1;
''';
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
