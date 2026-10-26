/*
 * liveprog_console_panel.dart — EEL2 控制台与诊断输出面板
 */
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/state.dart';
import '../../../core/theme.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../eel_editor_support.dart';

class LiveprogConsolePanel extends StatefulWidget {
  final AppModel model;
  final bool isCompiling;
  final Map<int, EelSliderMeta> activeSliders;
  final List<EelLintIssue> issues;
  final void Function(int line) onGotoLine;
  final VoidCallback onClose;

  const LiveprogConsolePanel({
    super.key,
    required this.model,
    required this.isCompiling,
    required this.activeSliders,
    required this.issues,
    required this.onGotoLine,
    required this.onClose,
  });

  @override
  State<LiveprogConsolePanel> createState() => _LiveprogConsolePanelState();
}

class _LiveprogConsolePanelState extends State<LiveprogConsolePanel> {
  bool _cleared = false;

  @override
  void didUpdateWidget(covariant LiveprogConsolePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCompiling && !oldWidget.isCompiling) {
      // 重新编译时自动唤醒输出
      _cleared = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = AppLocalizations.of(context)!;
    final m = widget.model;

    final st = m.lpStatus;
    final err = m.lpError;
    final hasErr = st < 0 || (st == 0 && err != null);
    final statusColor = widget.isCompiling
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
                icon: const Icon(Icons.cleaning_services_rounded, size: 13),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: l.lpConsoleClear,
                onPressed: () => setState(() => _cleared = true),
              ),
              const SizedBox(width: AuraSpace.xs),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 13),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: l.dlgClose,
                onPressed: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          Divider(color: p.hairline, height: 1),
          const SizedBox(height: AuraSpace.xs),
          if (_cleared)
            Text(
              '> Output cleared.',
              style: monoOf(p, size: 10.5, color: p.textDim),
            )
          else if (widget.isCompiling)
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
            if (widget.activeSliders.isNotEmpty)
              Text(
                '> Sliders bound: ${widget.activeSliders.keys.map((k) => 'slider$k').join(', ')}',
                style: monoOf(p, size: 10.5, color: p.textDim),
              ),
          ],
          if (widget.issues.isNotEmpty) ...[
            const SizedBox(height: AuraSpace.xs),
            for (final issue in widget.issues)
              InkWell(
                onTap: issue.line > 0 ? () => widget.onGotoLine(issue.line) : null,
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
                          style: captionOf(p, color: p.warning),
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
}
