import 'package:auradsp_app/features/liveprog/eel_editor_support.dart';
import 'package:auradsp_app/core/liveprog/equalizer_apo_parser.dart';
import 'package:auradsp_app/core/liveprog/rbj_biquad_generator.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  group('EqualizerApoParser', () {
    test('解析全局 Preamp 与基础 Peak 滤波器', () {
      const txt = '''
# Peace configuration
Preamp: -4.2 dB
Filter 1: ON PK Fc 100 Hz Gain 3.5 dB Q 1.41
Filter 2: ON PK Fc 1000 Hz Gain -2.0 dB Q 2.0
Filter 3: OFF PK Fc 5000 Hz Gain 5.0 dB Q 1.0
''';
      final config = EqualizerApoParser.parse(txt);
      expect(config.globalPreamp, -4.2);
      expect(config.leftPreamp, 0.0);
      expect(config.rightPreamp, 0.0);
      expect(config.hasStereoDifference, isFalse);
      expect(config.filters.length, 3);
      expect(config.activeFilters.length, 2);

      final f1 = config.filters[0];
      expect(f1.enabled, isTrue);
      expect(f1.type, ApoFilterType.peaking);
      expect(f1.freq, 100.0);
      expect(f1.gainDb, 3.5);
      expect(f1.q, 1.41);

      final f3 = config.filters[2];
      expect(f3.enabled, isFalse);
    });

    test('解析架设与多类型滤波器', () {
      const txt = '''
Preamp: 0 dB
Filter: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.71
Filter: ON LP Fc 20000 Hz Gain 0 dB Q 0.707
Filter: ON HP Fc 20 Hz Gain 0 dB Q 0.707
Filter: ON NO Fc 60 Hz Gain 0 dB Q 10
''';
      final config = EqualizerApoParser.parse(txt);
      expect(config.filters.length, 5);
      expect(config.filters[0].type, ApoFilterType.lowShelf);
      expect(config.filters[1].type, ApoFilterType.highShelf);
      expect(config.filters[2].type, ApoFilterType.lowPass);
      expect(config.filters[3].type, ApoFilterType.highPass);
      expect(config.filters[4].type, ApoFilterType.notch);
    });

    test('解析左右声道独立均衡配置', () {
      const txt = '''
Channel: L
Preamp: -2.0 dB
Filter 1: ON PK Fc 500 Hz Gain 4.0 dB Q 1.0

Channel: R
Preamp: -1.0 dB
Filter 1: ON PK Fc 800 Hz Gain -3.0 dB Q 1.5

Channel: all
Filter 2: ON HSC Fc 12000 Hz Gain 2.0 dB Q 0.7
''';
      final config = EqualizerApoParser.parse(txt);
      expect(config.hasStereoDifference, isTrue);
      expect(config.leftPreamp, -2.0);
      expect(config.rightPreamp, -1.0);
      expect(config.leftFilters.length, 1);
      expect(config.rightFilters.length, 1);
      expect(config.globalFilters.length, 1);
    });
  });

  group('RbjBiquadGenerator', () {
    test('生成标准 EEL2 脚本并通过 Linter 词法/语法无阻断校验', () {
      const txt = '''
Preamp: -3.0 dB
Filter 1: ON PK Fc 150 Hz Gain 4.0 dB Q 1.41
Filter 2: ON LSC Fc 80 Hz Gain 3.0 dB Q 0.71
Filter 3: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.71
''';
      final config = EqualizerApoParser.parse(txt);
      final eelCode = RbjBiquadGenerator.generate(
        config: config,
        presetName: 'Test Equalizer',
        channelSwap: true,
        invertPolarity: true,
      );

      expect(eelCode.contains('@init'), isTrue);
      expect(eelCode.contains('@sample'), isTrue);
      expect(eelCode.contains('Channel Swap'), isTrue);
      expect(eelCode.contains('Polarity Inversion'), isTrue);
      expect(eelCode.contains('calc_peak'), isTrue);
      expect(eelCode.contains('calc_lowshelf'), isTrue);
      expect(eelCode.contains('calc_highshelf'), isTrue);

      // 验证生成的 EEL2 语法通过 EelLinter 且无 blocking 结构性错误
      final issues = EelLinter.lint(_zh, eelCode);
      final blocking = issues.where((e) => e.blocking).toList();
      expect(blocking, isEmpty,
          reason: 'Generated EEL2 code must not have blocking lint errors');
    });

    test('左右独立声道生成双通道独立级联', () {
      const txt = '''
Channel: L
Filter 1: ON PK Fc 250 Hz Gain 3.0 dB Q 1.0
Channel: R
Filter 1: ON PK Fc 400 Hz Gain -3.0 dB Q 1.0
''';
      final config = EqualizerApoParser.parse(txt);
      final eelCode = RbjBiquadGenerator.generate(
        config: config,
        presetName: 'Independent Stereo Test',
      );

      expect(eelCode.contains('l_f1.calc_peak'), isTrue);
      expect(eelCode.contains('r_f1.calc_peak'), isTrue);
      expect(eelCode.contains('spl0 = l_f1.process_biquad(spl0);'), isTrue);
      expect(eelCode.contains('spl1 = r_f1.process_biquad(spl1);'), isTrue);

      final issues = EelLinter.lint(_zh, eelCode);
      expect(issues.where((e) => e.blocking), isEmpty);
    });
  });
}
