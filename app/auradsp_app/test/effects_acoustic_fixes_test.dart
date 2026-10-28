// effects_acoustic_fixes_test.dart — 空间音效跳变修复、混响卡禁止预设0、去vendor/跨平台文案断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_zh.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_en.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_ja.dart';

void main() {
  group('1. 空间音效浮点精度与跳变防护', () {
    test('单精度 0.7f (0.699999988079071) 百分比计算为 70% 而不是 69%', () {
      const floatVal = 0.699999988079071;
      expect((floatVal * 100).round(), 70);
      expect((floatVal * 100).toInt(), 69, reason: '旧版的 toInt 确实会导致跳变成 69%');
    });

    test('引擎回读单精度 float 时自动清理噪声', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      // 模拟底层单精度 float 0.7f 传入
      m.handleMessageForTesting({
        'evt': 'params',
        'bassEnable': 0,
        'bassGain': 0.0,
        'reverbPreset': -1,
        'stereoMix': 0.0,
        'eqEnable': 0,
        'postGain': 0.0,
        'limiterEnable': 1,
        'lpEnable': 0,
        'lpStatus': 0,
        'convEnable': 0,
        'convReady': 0,
        'convFrames': 0,
        'convChannels': 2,
        'convSrcRate': 48000,
        'convPeak': 0.0,
        'tubeEnable': 0,
        'xfeedEnable': 0,
        'stereoBandUsed': 0,
        'convMix': 1.0,
        'shelfEnable': 0,
        'shelfFreq': 100.0,
        'shelfGain': 0.0,
        'spatialEnable': 1,
        'spatialStyle': 0,
        'spatialRoom': 0.699999988079071,
        'spatialWidth': 0.999999988079071,
        'spatialCenter': 0.800000011920929,
      });

      expect(m.spatialRoom, 0.7);
      expect(m.spatialWidth, 1.0);
      expect(m.spatialCenter, 0.8);
    });
  });

  group('2. 空间混响卡彻底禁止显示与选择“旧版预设0”', () {
    test('首次开启混响默认使用大音乐厅(5)而非旧版0', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      expect(m.reverbPreset, -1);
      m.setSpatialReverbEnabled(true);
      expect(m.reverbPreset, 5, reason: '开启时必须恢复为精选第1档大音乐厅(5)');
      expect(kReverbCuratedPresets.contains(m.reverbPreset), isTrue);
    });

    test('selectReverbPreset(0) 自动归整为精选预设 5', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.selectReverbPreset(0);
      expect(m.reverbPreset, 5);
      expect(m.reverbPreset, isNot(0));
    });

    test('引擎回读 reverb.preset=0 自动规范化为 5', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.handleMessageForTesting({
        'evt': 'params',
        'bassEnable': 0,
        'bassGain': 0.0,
        'reverbPreset': 0,
        'stereoMix': 0.0,
        'eqEnable': 0,
        'postGain': 0.0,
        'limiterEnable': 1,
        'lpEnable': 0,
        'lpStatus': 0,
        'convEnable': 0,
        'convReady': 0,
        'convFrames': 0,
        'convChannels': 2,
        'convSrcRate': 48000,
        'convPeak': 0.0,
        'tubeEnable': 0,
        'xfeedEnable': 0,
        'stereoBandUsed': 0,
        'convMix': 1.0,
        'shelfEnable': 0,
        'shelfFreq': 100.0,
        'shelfGain': 0.0,
        'spatialEnable': 0,
        'spatialStyle': 0,
        'spatialRoom': 0.7,
        'spatialWidth': 1.0,
        'spatialCenter': 0.8,
      });

      expect(m.reverbPreset, 5, reason: '引擎回读0自动映射为精选第1档5');
    });
  });

  group('3. 文本声学专业化与去vendor/跨平台校验', () {
    test('立体声混响引擎标签不包含 Vendor', () {
      final zh = AppLocalizationsZh();
      final en = AppLocalizationsEn();
      final ja = AppLocalizationsJa();

      expect(zh.reverbEngineStereo, '立体声');
      expect(en.reverbEngineStereo, 'Stereo');
      expect(ja.reverbEngineStereo, 'ステレオ');

      expect(zh.reverbEngineStereo.toLowerCase().contains('vendor'), isFalse);
      expect(en.reverbEngineStereo.toLowerCase().contains('vendor'), isFalse);
      expect(ja.reverbEngineStereo.toLowerCase().contains('vendor'), isFalse);
    });

    test('混响与低音提示词条面向调音师声学描述，无底层 vendor/progenitor 术语', () {
      final zh = AppLocalizationsZh();
      final en = AppLocalizationsEn();
      final ja = AppLocalizationsJa();

      expect(zh.reverbEngineInfo.toLowerCase().contains('vendor'), isFalse);
      expect(zh.reverbEngineInfo.toLowerCase().contains('progenitor'), isFalse);
      expect(zh.bassModeTooltip.toLowerCase().contains('vendor'), isFalse);
      expect(zh.eelEmptyInit.toLowerCase().contains('vendor'), isFalse);

      expect(en.reverbEngineInfo.toLowerCase().contains('vendor'), isFalse);
      expect(en.reverbEngineInfo.toLowerCase().contains('progenitor'), isFalse);
      expect(en.bassModeTooltip.toLowerCase().contains('vendor'), isFalse);
      expect(en.eelEmptyInit.toLowerCase().contains('vendor'), isFalse);

      expect(ja.reverbEngineInfo.toLowerCase().contains('vendor'), isFalse);
      expect(ja.reverbEngineInfo.toLowerCase().contains('progenitor'), isFalse);
      expect(ja.bassModeTooltip.toLowerCase().contains('ベンダー'), isFalse);
      expect(ja.eelEmptyInit.toLowerCase().contains('vendor'), isFalse);
    });

    test('跨平台描述杜绝硬编码 Windows 专属路径与单平台偏颇', () {
      final zh = AppLocalizationsZh();
      final en = AppLocalizationsEn();
      final ja = AppLocalizationsJa();

      expect(zh.plugCustomEmpty.contains('C:\\'), isFalse);
      expect(en.plugCustomEmpty.contains('C:\\'), isFalse);
      expect(ja.plugCustomEmpty.contains('C:\\'), isFalse);

      expect(zh.sysHint.contains('Windows'), isFalse);
      expect(en.sysHint.contains('Windows'), isFalse);
      expect(ja.sysHint.contains('Windows'), isFalse);
    });
  });
}
