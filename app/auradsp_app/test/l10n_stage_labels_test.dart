// B4 D5/D4d：表现层三语标签与命名规则的固化回归。
//
// 覆盖两类"人肉同步"风险：
//   1. D5 阶段标签：chainStage* 5 键 × zh/en/ja 必须全部存在且非空
//      （旧实现 chain_page.dart 硬编码英文 'Stage 0 (Pre-DSP)'）。
//   2. D4d 命名：槽位卡标题键 plugMountedTitleNamed 带 {name} 占位，
//      三语均可用——"槽位卡显示用户所选名"的机器可查形式；
//      空 vendor 观感（不显示"未知厂商"）由 hero 卡渲染保证，
//      此处断言占位键存在即可兜住键漂移。
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_zh.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_en.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_ja.dart';

void main() {
  const stageKeys = [
    'chainStagePreDsp',
    'chainStagePreVendor',
    'chainStagePostVendor',
    'chainStagePostReverb',
    'chainStagePostLimiter',
  ];

  final locales = <String, AppLocalizations Function()>{
    'zh': AppLocalizationsZh.new,
    'en': AppLocalizationsEn.new,
    'ja': AppLocalizationsJa.new,
  };

  group('B4 D5 阶段标签三语', () {
    for (final entry in locales.entries) {
      test('${entry.key}：5 个阶段键全部非空', () {
        final l = entry.value();
        // 直接取字段而非反射：键缺失会在编译期暴露。
        final values = <String>[
          l.chainStagePreDsp,
          l.chainStagePreVendor,
          l.chainStagePostVendor,
          l.chainStagePostReverb,
          l.chainStagePostLimiter,
        ];
        expect(values.length, stageKeys.length);
        for (final v in values) {
          expect(v.trim(), isNotEmpty);
        }
      });
    }

    test('zh/en/ja 三语互不相同（排除漏翻）', () {
      final zh = AppLocalizationsZh().chainStagePreDsp;
      final en = AppLocalizationsEn().chainStagePreDsp;
      final ja = AppLocalizationsJa().chainStagePreDsp;
      expect(zh, isNot(en));
      expect(zh, isNot(ja));
      expect(en, isNot(ja));
    });
  });

  group('B4 D4d 槽位卡命名键', () {
    for (final entry in locales.entries) {
      test('${entry.key}：plugMountedTitleNamed 含插槽号与用户所选名', () {
        final l = entry.value();
        final text = l.plugMountedTitleNamed(2, 'Pro-Q 3');
        expect(text.contains('2'), isTrue);
        expect(text.contains('Pro-Q 3'), isTrue);
      });
    }
  });
}
