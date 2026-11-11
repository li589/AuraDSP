import 'package:auradsp_app/features/liveprog/eel_editor_support.dart';
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

    test('宿主环境条目齐备且与引擎实现一致（2026-11-08 声道信息收口）', () {
      final names = EelManualRegistry.entries.map((e) => e.name).toList();
      // P-038 宿主环境变量必须有条目（此前缺失，用户无从知晓）
      expect(names.any((n) => n.contains('num_ch')), isTrue,
          reason: 'num_ch / nch entry required');
      expect(names.any((n) => n.contains('dev_srate')), isTrue,
          reason: 'dev_srate entry required');
      // VM 中不存在的函数不得收录（freembuf 曾是幽灵条目，编译实测 Syntax error）
      expect(names.any((n) => n.contains('freembuf')), isFalse,
          reason: 'freembuf does not exist in the EEL VM');
      // 复合条目必须写真实函数全名，简写照抄无法编译
      expect(names.any((n) => n.contains('fractionalDelayLineProcess')), isTrue);
      expect(names.any((n) => n.contains('fractionalDelayLineSetDelay')), isTrue);
      expect(
          names.any((n) => n.contains('PolyphaseFilterbankSynthesisStereo')),
          isTrue);
      // spl 条目必须写明「只处理前 2 声道、其余直通」的声道真相
      final spl = EelManualRegistry.entries
          .firstWhere((e) => e.name.contains('spl0'));
      expect(spl.descZh, contains('直通'));
      expect(spl.descEn.toLowerCase(), contains('pass through'));
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
