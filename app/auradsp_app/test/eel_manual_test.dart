import 'package:auradsp_app/features/eel_editor_support.dart';
import 'package:auradsp_app/core/liveprog/eel_manual_registry.dart';
import 'package:auradsp_app/core/liveprog/eel_templates.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  group('EelManualRegistry', () {
    test('条目总数与内容结构完整性', () {
      expect(EelManualRegistry.entries.length, greaterThanOrEqualTo(80));

      // 验证全部 9 个分类均有收录
      final categoriesFound =
          EelManualRegistry.entries.map((e) => e.category).toSet();
      for (final cat in EelManualCategory.values) {
        expect(categoriesFound.contains(cat), isTrue,
            reason: 'Category ${cat.id} must have manual entries');
      }

      // 验证每个条目的必需字段非空
      for (final e in EelManualRegistry.entries) {
        expect(e.name, isNotEmpty);
        expect(e.signature, isNotEmpty);
        expect(e.summaryZh, isNotEmpty);
        expect(e.summaryEn, isNotEmpty);
        expect(e.descZh, isNotEmpty);
        expect(e.descEn, isNotEmpty);
        expect(e.snippet, isNotEmpty);
      }
    });

    test('模糊搜索与分类筛选功能', () {
      // 搜索 sin
      final sinResults = EelManualRegistry.search(query: 'sin');
      expect(sinResults, isNotEmpty);
      expect(sinResults.any((e) => e.name.contains('sin')), isTrue);

      // 按分类筛选 math
      final mathResults =
          EelManualRegistry.search(category: EelManualCategory.math);
      expect(mathResults, isNotEmpty);
      expect(
          mathResults.every((e) => e.category == EelManualCategory.math), isTrue);

      // 组合搜索
      final fftResults = EelManualRegistry.search(
        query: 'fft',
        category: EelManualCategory.spectral,
      );
      expect(fftResults, isNotEmpty);
    });
  });

  group('EelTemplates', () {
    test('全部 6 个预设代码模板合法性验证', () {
      expect(EelTemplates.list.length, 6);

      for (final t in EelTemplates.list) {
        expect(t.id, isNotEmpty);
        expect(t.titleZh, isNotEmpty);
        expect(t.titleEn, isNotEmpty);
        expect(t.code, isNotEmpty);
        expect(t.code.contains('@init'), isTrue);
        expect(t.code.contains('@sample'), isTrue);

        // 验证每个模板均能通过 EelLinter，无阻断性结构错误
        final issues = EelLinter.lint(_zh, t.code);
        final blocking = issues.where((i) => i.blocking).toList();
        expect(blocking, isEmpty,
            reason: 'Template ${t.id} must pass EelLinter without blocking issues');
      }
    });
  });
}
