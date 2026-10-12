import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/features/chain_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_zh.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_en.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_ja.dart';

void main() {
  group('Compressor & DDC (VDC) Chain & State Tests', () {
    test('kStageMeta exposes comp and ddc', () {
      final compMeta = kStageMeta.firstWhere((s) => s.id == 'comp');
      final ddcMeta = kStageMeta.firstWhere((s) => s.id == 'ddc');

      expect(compMeta.exposed, isTrue, reason: '压限器必须对外暴露为可控制节点');
      expect(ddcMeta.exposed, isTrue, reason: 'VDC/DDC 空间校正必须对外暴露为可控制节点');
    });

    test('stageLabelOf maps ddc and comp in zh/en/ja', () {
      final zh = AppLocalizationsZh();
      final en = AppLocalizationsEn();
      final ja = AppLocalizationsJa();

      expect(stageLabelOf(zh, 'ddc'), 'VDC 空间校正');
      expect(stageLabelOf(en, 'ddc'), 'VDC Spatial Correction');
      expect(stageLabelOf(ja, 'ddc'), 'VDC 空間補正');

      expect(stageLabelOf(zh, 'comp'), '压限器');
      expect(stageLabelOf(en, 'comp'), 'Limiter');
      expect(stageLabelOf(ja, 'comp'), 'リミッター');
    });

    test('AppModel defaults for comp', () {
      final m = AppModel();
      expect(m.compOn, isFalse);
      expect(m.compTimeconstant, 0.14);
      expect(m.compGranularity, 1);
      expect(m.compTfresolution, 1);
      expect(m.isStageEnabled('comp'), isFalse);
    });

    test('AppModel stage toggle and latency fallback', () {
      final m = AppModel();
      expect(m.isStageEnabled('comp'), isFalse);
      m.setCompEnabled(true);
      expect(m.isStageEnabled('comp'), isTrue);
      expect(m.componentLatency('comp').ms, 85.0);

      m.setCompEnabled(false);
      expect(m.isStageEnabled('comp'), isFalse);
      expect(m.componentLatency('comp').ms, 0.0);

      m.setCompTimeconstant(0.25);
      expect(m.compTimeconstant, 0.25);

      m.setCompGranularity(2);
      expect(m.compGranularity, 2);

      m.setCompTfresolution(0);
      expect(m.compTfresolution, 0);
    });

    test('Presets capture and apply comp state', () {
      final m1 = AppModel();
      m1.setCompEnabled(true);
      m1.setCompTimeconstant(0.35);
      m1.setCompGranularity(2);
      m1.setCompTfresolution(0);

      final preset = PresetLibrary.snapshot(m1, name: 'CompTest');
      expect(preset.params['comp'], isNotNull);
      final compMap = preset.params['comp'] as Map<String, dynamic>;
      expect(compMap['enable'], isTrue);
      expect(compMap['timeconstant'], 0.35);
      expect(compMap['granularity'], 2);
      expect(compMap['tfresolution'], 0);

      final m2 = AppModel();
      expect(m2.compOn, isFalse);
      PresetLibrary.apply(m2, preset);
      expect(m2.compOn, isTrue);
      expect(m2.compTimeconstant, 0.35);
      expect(m2.compGranularity, 2);
      expect(m2.compTfresolution, 0);
    });
  });
}
