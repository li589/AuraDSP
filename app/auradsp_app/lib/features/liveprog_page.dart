/*
 * liveprog_page.dart — 实时可编程 DSP（EEL2）编辑页（engine_api v1.1）
 *
 * 布局：编辑卡（工具行 + 代码编辑器 + 编译反馈）→ 滑块卡（slider1..8）→ 脚本库。
 * 脚本格式：@init / @sample 两段（引擎 LiveProgStringParser 契约）；
 * 注意 @init 段必须含至少一条语句（vendor 解析器约束）。
 * 脚本库目录：%APPDATA%/AuraDSP/liveprog（Windows；其它平台回退当前目录）。
 */
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'eel_editor_support.dart';
import 'chrome.dart';
import 'widgets.dart';

class LiveprogPage extends StatefulWidget {
  final AppModel model;
  const LiveprogPage({super.key, required this.model});

  @override
  State<LiveprogPage> createState() => _LiveprogPageState();
}

class _LiveprogPageState extends State<LiveprogPage> {
  final _editorFocus = FocusNode();
  int _cursorLine = 1, _cursorCol = 1;
  List<EelLintIssue> _issues = const [];

  late final TextEditingController _code = TextEditingController(
      text: LiveprogLibrary.template);
  List<String> _library = const [];

  @override
  void initState() {
    super.initState();
    _refreshLibrary();
    _runLint();
  }

  void _refreshLibrary() {
    setState(() => _library = LiveprogLibrary.list());
  }

  /// 即时 lint（括号/字符串，毫秒级）+ 光标行列
  void _onCodeChanged(String text) {
    _runLint();
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
    setState(() => _issues = EelLinter.lint(_code.text));
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
    _runLint();
  }

  void _insertTab({required bool indentLess}) {
    final text = _code.text;
    final sel = _code.selection;
    if (!sel.isValid || sel.isCollapsed) {
      // 单光标：Shift+Tab 把当前行整体左移一格，否则插入 Tab
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
    // 选区：逐行加/去一级缩进
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
    widget.model.setLiveprogCode(text);
  }

  void _save() {
    final name = _libraryNameController.text.trim();
    if (name.isEmpty) return;
    final ok = LiveprogLibrary.save(
        name.endsWith('.eel') ? name : '$name.eel', _code.text);
    _refreshLibrary();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(ok ? '已保存：$name.eel' : '保存失败（名称非法或磁盘不可写）',
          style: TextStyle(color: paletteOf(context).text, fontSize: 13)),
      duration: const Duration(seconds: 2),
    ));
  }

  final TextEditingController _libraryNameController =
      TextEditingController(text: 'my-script');

  @override
  void dispose() {
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
        // ---- 编辑卡 ----
        SectionCard(
          index: '01',
          title: l.lpEditor,
          hint: l.lpEditorHint,
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
                  AuraChip(l.lpApply, icon: Icons.play_arrow_rounded,
                      onTap: _apply),
                  AuraChip(l.lpUnload, icon: Icons.stop_rounded, danger: true,
                      onTap: () => m.unloadLiveprog()),
                  AuraChip(l.lpNew, icon: Icons.note_add_outlined,
                      onTap: () => _code.text = LiveprogLibrary.template),
                  AuraChip(l.lpFormat, icon: Icons.format_align_left_rounded,
                      onTap: _formatCode),
                ],
              ),
              const SizedBox(height: AuraSpace.md),
              // 代码编辑器
              Container(
                constraints: const BoxConstraints(minHeight: 260, maxHeight: 420),
                decoration: BoxDecoration(
                  color: p.bg,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                padding: const EdgeInsets.all(AuraSpace.md),
                child: Shortcuts(
                  // 拦截 Tab/Shift+Tab（覆盖 DefaultTextEditingShortcuts 的
                  // 焦点遍历），改为编辑器内缩进
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.tab): _EelTabIntent(),
                    SingleActivator(LogicalKeyboardKey.tab, shift: true):
                        _EelTabIntent(shift: true),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _EelTabIntent: _EelTabAction(),
                    },
                    child: Focus(
                      // 注意：这里必须用 Focus 自己创建的节点，不能与
                      // TextField 共用 _editorFocus——同一 FocusNode 被两个
                      // widget attach，debug 下 assert，release 下死循环
                      // （无限 rebuild，双核满转，差点卡死整机——2026-10-10）
                      onKeyEvent: (_, event) {
                        // Shortcuts 已消费 Tab；这里再拦一层防焦点遍历
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.tab) {
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _code,
                        focusNode: _editorFocus,
                        maxLines: null,
                        expands: true,
                        style: monoOf(p, size: 12.5, color: p.text),
                        onChanged: _onCodeChanged,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '@init\\n...\\n@sample\\n...',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AuraSpace.sm),
              // 光标位置 + 语法检查（lint）列表：点击问题跳转到对应行
              Row(children: [
                Text('行 $_cursorLine · 列 $_cursorCol',
                    style: monoOf(p, size: 11, color: p.textDim)),
                const SizedBox(width: AuraSpace.md),
                Text(
                    _issues.isEmpty
                        ? '语法检查：通过'
                        : '语法检查：$_issues 处问题',
                    style: monoOf(p,
                        size: 11,
                        color: _issues.isEmpty ? p.success : p.error)),
              ]),
              if (_issues.isNotEmpty) ...[
                const SizedBox(height: AuraSpace.xs),
                for (final issue in _issues.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: issue.line > 0 ? () => _gotoLine(issue.line) : null,
                        child: Row(children: [
                          Icon(Icons.error_outline,
                              size: 12, color: p.error),
                          const SizedBox(width: AuraSpace.xs),
                          Text(
                              issue.line > 0
                                  ? '第 ${issue.line} 行 · ${issue.message}'
                                  : issue.message,
                              style: monoOf(p, size: 11, color: p.error)),
                        ]),
                      ),
                    ),
                  ),
                if (_issues.length > 4)
                  Text('… 共 ${_issues.length} 处',
                      style: monoOf(p, size: 11, color: p.error)),
              ],
              const SizedBox(height: AuraSpace.xs),
              // 编译反馈（内联标红 / 绿色 OK）
              ListenableBuilder(
                listenable: m,
                builder: (_, _) {
                  final err = m.lpError;
                  final ok = m.lpStatus == 1;
                  final text = err ?? (ok ? l.lpCompileOk : l.lpNoCode);
                  final color = err != null
                      ? p.error
                      : (ok ? p.success : p.textDim);
                  return Row(children: [
                    Icon(
                        err != null
                            ? Icons.error_outline
                            : (ok ? Icons.check_circle_outline : Icons.info_outline),
                        size: 14, color: color),
                    const SizedBox(width: AuraSpace.sm),
                    Expanded(
                        child: Text(text,
                            style: monoOf(p, size: 11.5, color: color))),
                  ]);
                },
              ),
            ],
          ),
        ),
        // ---- 滑块卡 ----
        SectionCard(
          index: '02',
          title: l.lpSliders,
          hint: l.lpSliderHint,
          child: ListenableBuilder(
            listenable: m,
            builder: (_, _) => Column(
              children: [
                for (var i = 0; i < 8; i++)
                  _LpSlider(model: m, index: i),
              ],
            ),
          ),
        ),
        // ---- 脚本库 ----
        SectionCard(
          index: '03',
          title: l.lpLibrary,
          hint: LiveprogLibrary.dir,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_library.isEmpty)
                Text(l.lpLibraryEmpty, style: captionOf(p))
              else
                Wrap(
                  spacing: AuraSpace.sm,
                  runSpacing: AuraSpace.sm,
                  children: [
                    for (final f in _library)
                      AuraChip(f, icon: Icons.description_outlined,
                          onTap: () async {
                        final text = await LiveprogLibrary.load(f);
                        if (text != null && mounted) {
                          setState(() => _code.text = text);
                        }
                      }),
                  ],
                ),
              const SizedBox(height: AuraSpace.md),
              Row(children: [
                SizedBox(
                  width: 180,
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
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// sliderN 紧凑滑块行（-1..+4 合理域，实际语义由脚本定义）
class _LpSlider extends StatelessWidget {
  final AppModel model;
  final int index;
  const _LpSlider({required this.model, required this.index});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: EdgeInsets.only(
          bottom: index == 7 ? 0 : AuraSpace.xs),
      child: Row(children: [
        SizedBox(
          width: 64,
          child: Text('slider${index + 1}',
              style: monoOf(p, size: 11.5, color: p.textDim)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: model.lpParams[index].clamp(-1.0, 4.0),
              min: -1,
              max: 4,
              onChanged: (v) => model.setLiveprogParam(index, v),
            ),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(model.lpParams[index].toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: monoOf(p, size: 12, color: p.text)),
        ),
      ]),
    );
  }
}

/* ---- 脚本库（本地文件系统，无新依赖） ---- */

abstract final class LiveprogLibrary {
  static String? _dir;

  static String get dir {
    if (_dir != null) return _dir!;
    final appData = Platform.environment['APPDATA'];
    _dir = appData != null
        ? Directory('$appData${Platform.pathSeparator}AuraDSP'
                '${Platform.pathSeparator}liveprog').path
        : 'liveprog';
    return _dir!;
  }

  static List<String> list() {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return const [];
      return d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.eel'))
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
    } catch (_) {
      return const [];
    }
  }

  static Future<String?> load(String name) async {
    try {
      return await File('$dir${Platform.pathSeparator}$name')
          .readAsString();
    } catch (_) {
      return null;
    }
  }

  static bool save(String name, String text) {
    try {
      // 名称安全：拒绝路径分隔符/父目录引用
      if (name.contains(RegExp(r'[\\/:*?"<>|]')) || name.contains('..')) {
        return false;
      }
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      File('$dir${Platform.pathSeparator}$name').writeAsStringSync(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 新建模板：@init 段必须含至少一条语句（vendor 解析器约束）
  static const template = '''/* AuraDSP Liveprog — EEL2 实时脚本
 * 寄存器：spl0/spl1 = 左右样本（读写）, srate = 采样率
 * slider1..8 = 页面滑块（实时生效）
 * 注意：@init 段必须至少有一条语句。
 */
@init
dbg = 0;
@sample
spl0 *= slider1;
spl1 *= slider1;
''';
}

/* ---- Tab 缩进意图（覆盖 DefaultTextEditingShortcuts 的焦点遍历） ---- */

class _EelTabIntent extends Intent {
  final bool shift;
  const _EelTabIntent({this.shift = false});
}

class _EelTabAction extends Action<_EelTabIntent> {
  // Action 无 const 构造——actions 映射改为非常量
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
