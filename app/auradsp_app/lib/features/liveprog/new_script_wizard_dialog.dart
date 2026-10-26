/*
 * new_script_wizard_dialog.dart — Liveprog IDE 新建脚本向导与模板选择对话框
 *
 * 功能：
 * - 聚合展示 6 大经典音频 DSP 起步代码模板
 * - 左侧模板卡片列表选择，右侧完整代码高亮与特性介绍预览
 * - 确认后一键替换当前编辑器内容并触发即时 Lint
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/liveprog/eel_templates.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';

class NewScriptWizardDialog extends StatefulWidget {
  const NewScriptWizardDialog({super.key});

  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const NewScriptWizardDialog(),
    );
  }

  @override
  State<NewScriptWizardDialog> createState() => _NewScriptWizardDialogState();
}

class _NewScriptWizardDialogState extends State<NewScriptWizardDialog> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final isZh = Localizations.localeOf(context).languageCode.toLowerCase().startsWith('zh');
    final templates = EelTemplates.list;
    final selected = templates[_selectedIndex.clamp(0, templates.length - 1)];

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
          Icon(Icons.auto_stories_rounded, size: 20, color: p.accent),
          const SizedBox(width: AuraSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.lpTemplates, style: sectionOf(p)),
                Text(l.lpTemplatesDesc, style: captionOf(p)),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 800,
        height: 480,
        child: Row(
          children: [
            // Left list of templates
            SizedBox(
              width: 280,
              child: Container(
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: ListView.separated(
                  itemCount: templates.length,
                  padding: const EdgeInsets.all(AuraSpace.xs),
                  separatorBuilder: (_, _) => const SizedBox(height: AuraSpace.xxs),
                  itemBuilder: (ctx, idx) {
                    final t = templates[idx];
                    final isSelected = idx == _selectedIndex;
                    final title = isZh ? t.titleZh : t.titleEn;
                    final desc = isZh ? t.descZh : t.descEn;

                    return InkWell(
                      onTap: () => setState(() => _selectedIndex = idx),
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? p.accent.withValues(alpha: 0.15) : Colors.transparent,
                          borderRadius: BorderRadius.circular(AuraRadius.sm),
                          border: Border.all(
                            color: isSelected ? p.accent : Colors.transparent,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: isSelected ? p.accent : p.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              desc,
                              style: captionOf(p).copyWith(fontSize: 10.5),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),

            // Right preview panel
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(AuraSpace.sm),
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isZh ? selected.titleZh : selected.titleEn,
                      style: sectionOf(p).copyWith(fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isZh ? selected.descZh : selected.descEn,
                      style: captionOf(p),
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    Divider(height: 1, color: p.hairline),
                    const SizedBox(height: AuraSpace.sm),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SelectableText(
                          selected.code,
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
          onPressed: () => Navigator.of(context).pop(selected.code),
          child: Text(l.lpTemplateUse),
        ),
      ],
    );
  }
}
