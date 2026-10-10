/*
 * liveprog_page.dart — 实时可编程 DSP（EEL2）编辑页（engine_api v1.1）
 *
 * 优化与提升：
 * 1. 编辑器语法高亮（EelSyntaxTextEditingController：段指令、控制流、内置变量、函数、常量、注释）
 * 2. 文本对齐与格式化（EelFormatter：层级缩进、操作符空格、连续赋值等号对齐、分号规整）
 * 3. 自适应滑块调节（EelSliderParser：根据代码引用及声明动态呈现活跃参数与自定义名称/范围）
 * 4. 外部预设文件夹加载（多目录递归遍历 .eel / .txt，一键加载生效）
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

  late final EelSyntaxTextEditingController _code =
      EelSyntaxTextEditingController(text: LiveprogLibrary.template);

  List<LiveprogItem> _libraryItems = const [];
  Map<int, EelSliderMeta> _activeSliders = {};
  bool _showAllSliders = false;

  final TextEditingController _libraryNameController =
      TextEditingController(text: 'my-script');

  @override
  void initState() {
    super.initState();
    _refreshLibrary();
    _activeSliders = EelSliderParser.parse(_code.text);
    _runLint();
  }

  void _refreshLibrary() {
    setState(() {
      _libraryItems =
          LiveprogLibrary.listAll(widget.model.config.customScriptDirs);
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

  void _addExternalScriptDirDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          title: Text('添加外部脚本预设目录', style: sectionOf(p)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('请输入包含 .eel / .txt 脚本预设的完整文件夹路径：', style: captionOf(p)),
              const SizedBox(height: AuraSpace.sm),
              TextField(
                controller: ctrl,
                style: monoOf(p, size: 12),
                decoration: InputDecoration(
                  hintText: r'例：D:\AudioScripts\EelPresets',
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
              child: Text('取消', style: labelOf(p)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
              ),
              onPressed: () {
                final path = ctrl.text.trim();
                if (path.isNotEmpty) {
                  widget.model.addCustomScriptDir(path);
                  Navigator.of(ctx).pop();
                  _refreshLibrary();
                }
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
  }

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
        // ---- 01 编辑卡 ----
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
                  AuraChip(l.lpApply,
                      icon: Icons.play_arrow_rounded, onTap: _apply),
                  AuraChip(l.lpUnload,
                      icon: Icons.stop_rounded,
                      danger: true,
                      onTap: () => m.unloadLiveprog()),
                  AuraChip(l.lpNew,
                      icon: Icons.note_add_outlined, onTap: () {
                    _code.text = LiveprogLibrary.template;
                    _onCodeChanged(_code.text);
                  }),
                  AuraChip(l.lpFormat,
                      icon: Icons.format_align_left_rounded, onTap: _formatCode),
                ],
              ),
              const SizedBox(height: AuraSpace.md),

              // 代码编辑器（支持语法着色）
              Container(
                constraints:
                    const BoxConstraints(minHeight: 260, maxHeight: 420),
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.md),
                  border: Border.all(color: p.hairline),
                ),
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
                    '${_code.text.length} 字符',
                    style: monoOf(p, size: 11, color: p.textDim),
                  ),
                  const Spacer(),
                  if (_issues.isEmpty)
                    Row(
                      children: [
                        Icon(Icons.check_circle_outline_rounded,
                            size: 13, color: p.success),
                        const SizedBox(width: 4),
                        Text('语法就绪',
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
                          '${_issues.length} 处潜在问题',
                          style: monoOf(p, size: 11, color: p.warning),
                        ),
                      ],
                    ),
                ],
              ),

              // Lint 提示列表
              if (_issues.isNotEmpty) ...[
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
                                ? '第 ${issue.line} 行：${issue.message}'
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
          hint: '滑块条已自适应当前脚本声明与引用的 slider 参数；支持点击右上角切换模式。',
          trailing: AuraChip(
            _showAllSliders ? '全部 8 槽' : '自适应 (${_activeSliders.length})',
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
                        '当前代码未声明或引用 slider1..8 参数（纯算法处理）',
                        style: captionOf(p),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _showAllSliders = true),
                        icon: const Icon(Icons.expand_more_rounded, size: 14),
                        label: const Text('展开全部 8 槽滑块'),
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
          hint: '支持本地 %APPDATA% 库与外部多预设文件夹自动索引。',
          trailing: OutlinedButton.icon(
            onPressed: _addExternalScriptDirDialog,
            icon: const Icon(Icons.create_new_folder_rounded, size: 15),
            label: const Text('添加外部目录'),
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
                  spacing: AuraSpace.sm,
                  runSpacing: AuraSpace.sm,
                  children: [
                    for (final item in _libraryItems)
                      AuraChip(
                        item.isExternal
                            ? '${item.name} [${item.folderName}]'
                            : item.name,
                        icon: item.isExternal
                            ? Icons.folder_shared_rounded
                            : Icons.description_outlined,
                        onTap: () async {
                          final text =
                              await LiveprogLibrary.loadFromPath(item.path);
                          if (text != null && mounted) {
                            setState(() {
                              _code.text = text;
                              _onCodeChanged(text);
                            });
                          }
                        },
                      ),
                  ],
                ),
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
    final minVal = meta?.minVal ?? -1.0;
    final maxVal = meta?.maxVal ?? 4.0;
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

  static String get dir {
    if (_dir != null) return _dir!;
    final appData = Platform.environment['APPDATA'];
    _dir = appData != null
        ? Directory('$appData${Platform.pathSeparator}AuraDSP'
                '${Platform.pathSeparator}liveprog')
            .path
        : 'liveprog';
    return _dir!;
  }

  /// 聚合本地库与用户自定义外部目录
  static List<LiveprogItem> listAll(List<String> customDirs) {
    final items = <LiveprogItem>[];

    // 1. 本地默认目录
    try {
      final d = Directory(dir);
      if (d.existsSync()) {
        for (final f in d.listSync().whereType<File>()) {
          final p = f.path.toLowerCase();
          if (p.endsWith('.eel') || p.endsWith('.txt')) {
            items.add(LiveprogItem(
              name: f.uri.pathSegments.last,
              path: f.path,
              isExternal: false,
              folderName: 'Local',
            ));
          }
        }
      }
    } catch (_) {}

    // 2. 外部预设目录
    for (final cDir in customDirs) {
      try {
        final d = Directory(cDir);
        if (d.existsSync()) {
          final segments = d.uri.pathSegments.where((s) => s.isNotEmpty);
          final folderName = segments.isNotEmpty ? segments.last : cDir;
          for (final f in d.listSync(recursive: true).whereType<File>()) {
            final p = f.path.toLowerCase();
            if (p.endsWith('.eel') || p.endsWith('.txt')) {
              items.add(LiveprogItem(
                name: f.uri.pathSegments.last,
                path: f.path,
                isExternal: true,
                folderName: folderName,
              ));
            }
          }
        }
      } catch (_) {}
    }

    items.sort((a, b) => a.name.compareTo(b.name));
    return items;
  }

  static Future<String?> loadFromPath(String filePath) async {
    try {
      return await File(filePath).readAsString();
    } catch (_) {
      return null;
    }
  }

  static bool save(String name, String text) {
    try {
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
