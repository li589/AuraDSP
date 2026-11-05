// chain_spectrum_analyzer_test.dart — 全流程复合频响测量与延迟反哺测试
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/chain/chain_spectrum_analyzer.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('FullChainTransferCalculator 纯内存静音频响与延迟测试', () {
    test('对数频率轴均匀覆盖 20Hz ~ 20kHz', () {
      final freqs = FullChainTransferCalculator.getLogFrequencies();
      expect(freqs.length, 256);
      expect(freqs.first, closeTo(20.0, 0.01));
      expect(freqs.last, closeTo(20000.0, 1.0));
      // 验证严格单调递增
      for (var i = 0; i < freqs.length - 1; i++) {
        expect(freqs[i] < freqs[i + 1], isTrue);
      }
    });

    test('默认直通全平 0 dB', () {
      final model = AppModel(testing: true);
      // 默认关闭非核心滤波
      final res = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
      );
      expect(res.frequencies.length, 256);
      expect(res.gainsDb.length, 256);
      // 默认没有开启 EQ、Shelf、Filter 时增益接近 0 dB
      for (final g in res.gainsDb) {
        expect(g.abs(), lessThan(0.5));
      }
      expect(res.isBusBypassed, isFalse);
    });

    test('Filter 开启后高低切频响响应计算准确', () {
      final model = AppModel(testing: true);
      model.filterOn = true;
      model.filterType = 0; // HPF 高通
      model.filterFreq = 200.0;
      model.filterQ = 0.707;

      final res = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
      );
      // 在 20Hz 处增益应有明显低切衰减 (< -20 dB)
      expect(res.gainsDb.first, lessThan(-20.0));
      // 在 10kHz 处应接近直通 (约 0 dB)
      expect(res.gainsDb.last, closeTo(0.0, 1.0));
    });

    test('EQ 峰值增益叠加响应', () {
      final model = AppModel(testing: true);
      model.eqOn = true;
      model.eqGains[0] = 6.0; // 提升 6 dB
      model.eqFrequencies[0] = 1000.0;
      model.eqQs[0] = 2.0;

      final res = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
      );
      // 1000Hz 附近增益明显抬高
      expect(res.maxGain, greaterThan(4.0));
    });

    test('Voicemeeter 模式总线掩码旁路识别', () {
      final model = AppModel(testing: true);
      model.setAttachmentMode(AudioModes.attachVoicemeeterApi);
      model.vbBusMask = 0x01; // 只启用 A1 (bit 0)

      // 访问 A1 (index 0) 应正常计算
      final resA1 = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
        vbBusIndex: 0,
      );
      expect(resA1.isBusBypassed, isFalse);

      // 访问 A2 (index 1) 应识别为被禁用总线，直通 0 dB
      final resA2 = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
        vbBusIndex: 1,
      );
      expect(resA2.isBusBypassed, isTrue);
      for (final g in resA2.gainsDb) {
        expect(g, 0.0);
      }
    });

    test('全链路端到端总延迟反哺 model.latencyMs', () {
      final model = AppModel(testing: true);
      model.limiterOn = true; // 1.5ms
      model.bassOn = true; // 4.0ms
      model.haasOn = true;
      model.haasDelayMs = 15.0; // 15.0ms

      final res = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
      );
      expect(res.coreLatencyMs, closeTo(20.5, 0.1));
      expect(res.totalLatencyMs, closeTo(20.5, 0.1));

      model.updateFullChainMeasuredLatency(res.totalLatencyMs);
      expect(model.latencyMs, closeTo(20.5, 0.1));
    });
  });

  group('ChainSpectrumAnalyzer 组件渲染与交互测试', () {
    testWidgets('渲染标题、静音提示、声道切换与曲线图', (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(ChainSpectrumAnalyzer(model: model)));
      await tester.pumpAndSettle();

      expect(find.text('全流程复合频响测量'), findsOneWidget);
      expect(find.text('(EqualizerAPO 响应风格)'), findsOneWidget);
      expect(find.text('纯内存静音测算 · 扬声器不发声'), findsOneWidget);
      expect(find.text('立体声 (L/R)'), findsOneWidget);
      expect(find.text('左声道 (L)'), findsOneWidget);
      expect(find.text('右声道 (R)'), findsOneWidget);

      // 点击切换至左声道
      await tester.tap(find.text('左声道 (L)'));
      await tester.pumpAndSettle();

      // 点击切换至折线模式
      await tester.tap(find.byIcon(Icons.show_chart_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.timeline_rounded), findsOneWidget);
    });
  });
}
