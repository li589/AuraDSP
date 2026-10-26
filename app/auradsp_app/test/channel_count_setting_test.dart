// channel_count_setting_test.dart — WP9 (U-1, X-8): 声道数量选择器与参数钳制测试
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      locale: model.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SettingsPage(model: model)),
    );

Map<String, dynamic> _paramsEvt({int channelsCount = 2, int channelsCountMode = 0}) => {
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
      'channelsCount': channelsCount,
      'channelsCountMode': channelsCountMode,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('channel_test_');
    ConfigManager.baseDirOverride = tempDir!.path;
  });

  tearDown(() {
    ConfigManager.baseDirOverride = null;
    try {
      tempDir?.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('WP9 X-8: channels.mode 与 channels.countMode 钳制契约', () {
    test('X-8: setInt("channels.mode", v) 下发前必须 clamp 到 0..1', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      // 尝试下发非法的高值 2 (历史 UI 的 7.1) 与 99
      model.setInt('channels.mode', 2);
      expect(model.channelsMode, 1);
      final sent1 = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.mode');
      expect(sent1['value'], 1);

      model.setInt('channels.mode', 99);
      expect(model.channelsMode, 1);
      final sent2 = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.mode');
      expect(sent2['value'], 1);

      // 尝试下发负值
      model.setInt('channels.mode', -5);
      expect(model.channelsMode, 0);
      final sent3 = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.mode');
      expect(sent3['value'], 0);
    });

    test('channels.countMode 走纯状态载体 clamp 到 0..1', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setInt('channels.countMode', 10);
      expect(model.channelsCountMode, 1);
      final sent1 = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.countMode');
      expect(sent1['value'], 1);

      model.setInt('channels.countMode', -10);
      expect(model.channelsCountMode, 0);
      final sent2 = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.countMode');
      expect(sent2['value'], 0);
    });
  });

  group('WP9 U-1: 声道数状态与回读逻辑', () {
    test('默认 channelsCountMode=0, channelsCount=2, effectiveChannelCount=2', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      expect(model.channelsCountMode, 0);
      expect(model.channelsCount, 2);
      expect(model.effectiveChannelCount, 2);
    });

    test('手动切换声道数更新 config 并下发参数', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setChannelsCountMode(1);
      model.setChannelsCount(6);

      expect(model.channelsCountMode, 1);
      expect(model.channelsCount, 6);
      expect(model.effectiveChannelCount, 6);
      expect(model.config.channelsCountMode, 1);
      expect(model.config.channelsCount, 6);

      final sentMode = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.countMode');
      expect(sentMode['value'], 1);
      final sentCount = model.sentParamsForTesting.lastWhere((m) => m['id'] == 'channels.count');
      expect(sentCount['value'], 6);
    });

    test('引擎回读 params 事件正确更新 channelsCount 与 channelsCountMode', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.handleMessageForTesting(_paramsEvt(
        channelsCount: 8,
        channelsCountMode: 0,
      ));

      expect(model.channelsCount, 8);
      expect(model.channelsCountMode, 0);
      expect(model.effectiveChannelCount, 8);
    });
  });

  group('WP9 U-1: 设置页声道数选择器 UI 交互', () {
    testWidgets('渲染自动/2.0/4.0/5.1/7.1 分段控件与自动协商提示', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();

      // 验证标题与分段控件
      expect(find.text('声道数量'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
      expect(find.text('2.0'), findsOneWidget);
      expect(find.text('4.0'), findsOneWidget);
      expect(find.text('5.1'), findsOneWidget);
      expect(find.text('7.1'), findsOneWidget);

      // 默认自动模式下，显示当前工作拓扑
      expect(find.textContaining('自动协商生效中 · 当前工作拓扑：2 声道'), findsOneWidget);

      // 点选 5.1
      await tester.tap(find.text('5.1'));
      await tester.pumpAndSettle();

      expect(model.channelsCountMode, 1);
      expect(model.channelsCount, 6);
      expect(model.effectiveChannelCount, 6);

      // 手动模式下，自动协商提示不再展示
      expect(find.textContaining('自动协商生效中'), findsNothing);

      // 切回 自动
      await tester.tap(find.text('自动'));
      await tester.pumpAndSettle();

      expect(model.channelsCountMode, 0);
      expect(find.textContaining('自动协商生效中 · 当前工作拓扑：6 声道'), findsOneWidget);
    });
  });
}
