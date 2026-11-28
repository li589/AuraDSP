// chain_spectrum_analyzer_test.dart — 全流程复合频响测量与延迟反哺测试
import 'dart:io';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/plugins/plugin_manager.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';
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

    test('全链路总延迟与 PDC 槽位延迟严格对齐；端到端 latencyMs = 路径 + 链路（r44 S3 定源）', () {
      final model = AppModel(testing: true);
      model.limiterOn = true; // 核心 1.5ms lookahead
      // 模拟第三方插件槽位 0 有 96 samples @ 48kHz (2.0ms)
      model.pluginManager.onPluginSlotStatus(0, {
        'hasActive': true,
        'status': 2,
        'latency': 96,
        'plugin': {'name': 'TestEQ', 'vendor': 'Test', 'format': 'vst3', 'category': 'EQ', 'path': '/vst/test.vst3'},
      }, PluginInsertStage.preDsp);

      final res = FullChainTransferCalculator.compute(
        model: model,
        channel: 'stereo',
      );
      expect(res.coreLatencyMs, closeTo(1.5, 0.05));
      expect(res.pluginLatencyMs, closeTo(2.0, 0.05));
      expect(res.totalLatencyMs, closeTo(3.5, 0.05));

      // R-05：拆分值必须与 AppModel 单一出口一致，分析器不再有第二套算式
      expect(model.coreChainLatencyMs, closeTo(res.coreLatencyMs, 0.001));
      expect(model.pluginChainLatencyMs, closeTo(res.pluginLatencyMs, 0.001));
      expect(model.fullChainLatencyMs, closeTo(res.totalLatencyMs, 0.001));

      // 第四十四轮 S3 定源：链路延迟只活在 fullChainLatencyMs
      // 族，不再覆写状态面延迟；端到端 latencyMs 为派生值
      // （路径延迟 + 链路延迟），路径未上报时即链路值本身。
      expect(model.latencyMs, closeTo(3.5, 0.05));
      model.pathLatencyMs = 2.0;
      expect(model.latencyMs, closeTo(5.5, 0.05));
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

      expect(find.text('最终频响'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('FL'), findsOneWidget);
      expect(find.text('FR'), findsOneWidget);

      // 点击切换至 FL 声道
      await tester.tap(find.text('FL'));
      await tester.pumpAndSettle();

      // 点击切换至几何折线模式
      await tester.tap(find.byIcon(Icons.show_chart_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.timeline_rounded), findsOneWidget);
    });

    testWidgets('最终频响标题行：模式/刷新按钮贴卡片右缘', (tester) async {
      tester.view.physicalSize = const Size(1600, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(ChainSpectrumAnalyzer(model: model)));
      await tester.pumpAndSettle();

      expect(find.text('最终频响'), findsOneWidget);
      final cardRight =
          tester.getRect(find.byType(ChainSpectrumAnalyzer)).right;
      final buttons = find.byType(IconButton);
      expect(buttons, findsNWidgets(2));
      // 末位按钮（刷新）右缘距卡片右缘恰为卡片内边距（12）。
      final refreshRight = tester.getRect(buttons.last).right;
      expect((cardRight - refreshRight - 12).abs(), lessThan(2.0));
      // 模式切换按钮在刷新按钮左侧。
      final toggleRight = tester.getRect(buttons.first).right;
      expect(toggleRight, lessThanOrEqualTo(refreshRight));
    });

    test('多声道根据 effectiveChannelCount 动态展示 FL/FR/C/LFE/SL/SR 等', () {
      final model = AppModel(testing: true);
      model.channelsCountMode = 1;
      model.channelsCount = 8;
      expect(model.effectiveChannelCount, 8);

      final resLfe = FullChainTransferCalculator.compute(
        model: model,
        channel: 'LFE',
      );
      expect(resLfe.frequencies.length, 256);
      expect(resLfe.gainsDb.length, 256);
    });

    test('空间音效、卷积、DDC校准与Liveprog真实联动频响增益', () {
      final model = AppModel(testing: true);

      // 1. Spatial 开启产生真实声学空间增益变动
      final res0 = FullChainTransferCalculator.compute(model: model, channel: 'FL');
      model.spatialOn = true;
      model.spatialOutGain = 3.0;
      model.spatialMix = 1.0;
      final resSpatial = FullChainTransferCalculator.compute(model: model, channel: 'FL');
      expect(resSpatial.maxGain, greaterThan(res0.maxGain));

      // 2. Convolver 开启产生滤波增益变动
      model.convEnabled = true;
      model.convReady = true;
      model.convMix = 1.0;
      final resConv = FullChainTransferCalculator.compute(model: model, channel: 'FL');
      expect(resConv.gainsDb != resSpatial.gainsDb, isTrue);

      // 3. Liveprog 无代码/直通时诚实无偏染色；启用 EqualizerAPO / RBJ 峰值 / 多声道 MC 时真实反应
      model.lpEnabled = true;
      final resLpEmpty = FullChainTransferCalculator.compute(model: model, channel: 'FL');
      expect(resLpEmpty.gainsDb, equals(resConv.gainsDb));

      model.setLiveprogCode('''
slider1:1000<100,10000,10>Frequency (Hz)
slider2:6.0<-18,18,0.5>Gain (dB)
slider3:2.0<0.1,10,0.05>Q Factor
@init
@slider
eqL.calc_biquad(slider1, slider3, slider2);
eqR.calc_biquad(slider1, slider3, slider2);
@sample
spl0 = eqL.process_biquad(spl0);
spl1 = eqR.process_biquad(spl1);
''');
      final resLp = FullChainTransferCalculator.compute(model: model, channel: 'FL');
      expect(resLp.gainsDb != resConv.gainsDb, isTrue);
      // Center around 1 kHz boosted ~ +6 dB compared to resConv
      final idx1k = resLp.frequencies.indexWhere((f) => f >= 1000.0);
      expect(resLp.gainsDb[idx1k] - resConv.gainsDb[idx1k], closeTo(6.0, 0.35));
    });

    test('空间音效频响全频平滑无阶跃突变且严守声道门控', () {
      for (final ch in ['FL', 'FR', 'all']) {
        final m = AppModel(testing: true);
        m.spatialOn = true;
        m.spatialRoom = 0.7;
        m.spatialWidth = 1.0;
        m.spatialCenter = 0.8;
        m.spatialMix = 1.0;
        m.spatialOutGain = 0.0;
        final res = FullChainTransferCalculator.compute(model: m, channel: ch);
        var maxStep = 0.0;
        for (var i = 1; i < res.gainsDb.length; i++) {
          final step = (res.gainsDb[i] - res.gainsDb[i - 1]).abs();
          if (step > maxStep) maxStep = step;
        }
        // 旧实现在 2kHz 有 0.5dB 阶跃且在 3k/7.5kHz 有尖锐折角，连续 HRTF 物理模型步长极小
        expect(maxStep, lessThan(0.25), reason: 'channel=$ch maxStep=$maxStep');
      }

      // LFE 永不参与 Spatial；离散多声道模式下中置 C 不参与 Spatial
      final dm = AppModel(testing: true);
      dm.channelsCountMode = 1;
      dm.channelsCount = 6;
      dm.channelsMode = 1; // discrete
      dm.spatialOn = true;
      dm.spatialOutGain = 4.0;
      dm.spatialMix = 1.0;

      final resLfe = FullChainTransferCalculator.compute(model: dm, channel: 'LFE');
      final resC = FullChainTransferCalculator.compute(model: dm, channel: 'C');
      final resFl = FullChainTransferCalculator.compute(model: dm, channel: 'FL');
      expect(resLfe.gainsDb.every((g) => g == 0.0), isTrue);
      expect(resC.gainsDb.every((g) => g == 0.0), isTrue);
      expect(resFl.gainsDb.any((g) => g.abs() > 0.5), isTrue);
    });

    test('Liveprog 立体声离散门控与 MC 多声道脚本及实测缓存回放真实反应', () {
      // EqualizerAPO 左/右声道分流与 Preamp 联动
      final m = AppModel(testing: true);
      m.lpEnabled = true;
      m.setLiveprogCode('''
@init
g_preamp_db = -3.00;
l_preamp_db = 0.00;
r_preamp_db = 0.00;
// Global Filters (Both Channels)
// Filter 1: PK 1000Hz 6.0dB Q=2.0
g_f1_L.calc_peaking(1000, 6.0, 2.0);
g_f1_R.calc_peaking(1000, 6.0, 2.0);
// Channel L Specific Filters
// Filter 1: PK 200Hz -6.0dB Q=2.0
l_f1.calc_peaking(200, -6.0, 2.0);
@sample
spl0 *= gain_l;
''');
      final resL = FullChainTransferCalculator.compute(model: m, channel: 'FL');
      final resR = FullChainTransferCalculator.compute(model: m, channel: 'FR');
      final idx200 = resL.frequencies.indexWhere((f) => f >= 200.0);
      final idx1k = resL.frequencies.indexWhere((f) => f >= 1000.0);
      expect(resL.gainsDb[idx1k], closeTo(3.0, 0.4));
      expect(resR.gainsDb[idx1k], closeTo(3.0, 0.4));
      expect(resL.gainsDb[idx200], closeTo(-9.0, 0.5));
      expect(resR.gainsDb[idx200], closeTo(-3.0, 0.4));

      // 离散多声道模式下：立体声 lpEnabled 仅作用于 FL/FR，不作用于 C；
      // 启用 lpMcEnabled 后多声道 C 正常响应（包括真实 C++ 探针缓存覆盖插值）
      m.channelsCountMode = 1;
      m.channelsCount = 6;
      m.channelsMode = 1;
      final resDiscreteC = FullChainTransferCalculator.compute(model: m, channel: 'C');
      expect(resDiscreteC.gainsDb.every((g) => g == 0.0), isTrue);

      m.lpEnabled = false;
      m.lpMcEnabled = true;
      m.setLiveprogMcCode('''
slider1:-4.0<-24,12,0.5>Trim (dB)
@init
@slider
g = 10 ^ (slider1 / 20);
@sample
spl2 *= g;
''');
      final resMcFallback = FullChainTransferCalculator.compute(model: m, channel: 'C');
      expect(resMcFallback.gainsDb.first, closeTo(-4.0, 0.05));

      // 验证缓存的真实 C++ 探针曲线对数插值优先于离线估算
      final sr = m.engineRate > 0 ? m.engineRate : 48000;
      final params = m.effectiveLiveprogParams(multichannel: true);
      final key = StateChain.liveprogProbeKey(
        multichannel: true,
        probeChannel: 2,
        code: m.lpMcCode!.trim(),
        sampleRate: sr,
        params: params,
      );
      m.lpMcResponseCache[key] = (
        fMax: 20000.0,
        gainsDb: List<double>.filled(AppModel.lpResponsePoints, -9.5),
      );
      final resMcCached = FullChainTransferCalculator.compute(model: m, channel: 'C');
      expect(resMcCached.gainsDb[idx1k], closeTo(-9.5, 0.01));
    });

    test('Dart FFI measureLiveprogResponse 与状态缓存全链端到端联动', () {
      const candidates = [
        '../../core/desktop/windows/out/Release/auradsp_engine.dll',
        'core/desktop/windows/out/Release/auradsp_engine.dll',
      ];
      String? dllPath;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          dllPath = File(c).absolute.path;
          break;
        }
      }
      if (dllPath == null) {
        return; // 无已编译 Windows DLL 的纯无头环境跳过原生活体联动
      }
      final lib = AuraDspLib.load(dllPath);
      const peakCode = '''
slider1:1000<100,10000,10>Frequency (Hz)
slider2:0.0<-18,18,0.5>Gain (dB)
slider3:1.41<0.1,10,0.05>Q Factor
@init
PI = 3.141592653589793;
b0=1; b1=0; b2=0; a1=0; a2=0; x1=x2=y1=y2=r1=r2=z1=z2=0;
@slider
w0 = 2 * PI * slider1 / srate;
alpha = sin(w0) / (2 * slider3);
A = 10 ^ (slider2 / 40);
a0 = 1 + alpha / A;
b0 = (1 + alpha * A) / a0;
b1 = (-2 * cos(w0)) / a0;
b2 = (1 - alpha * A) / a0;
a1 = (-2 * cos(w0)) / a0;
a2 = (1 - alpha / A) / a0;
@sample
yl = b0*spl0 + b1*x1 + b2*x2 - a1*y1 - a2*y2;
x2=x1; x1=spl0; y2=y1; y1=yl; spl0=yl;
yr = b0*spl1 + b1*r1 + b2*r2 - a1*z1 - a2*z2;
r2=r1; r1=spl1; z2=z1; z1=yr; spl1=yr;
''';
      final db = lib.measureLiveprogResponse(
        peakCode,
        48000,
        params: const [2000.0, 6.0, 2.0],
        channel: -1,
        multichannel: false,
        nPoints: AppModel.lpResponsePoints,
        fMax: 20000.0,
      );
      expect(db, isNotNull);
      expect(db!.length, AppModel.lpResponsePoints);

      final m = AppModel(testing: true);
      m.lpEnabled = true;
      m.setLiveprogCode(peakCode);
      m.setLiveprogSliderVal(1, 2000.0);
      m.setLiveprogSliderVal(2, 6.0);
      m.setLiveprogSliderVal(3, 2.0);
      final params = m.effectiveLiveprogParams(multichannel: false);
      final key = StateChain.liveprogProbeKey(
        multichannel: false,
        probeChannel: 0,
        code: m.lpCode!.trim(),
        sampleRate: 48000,
        params: params,
      );
      m.lpResponseCache[key] = (fMax: 20000.0, gainsDb: db);
      final res = FullChainTransferCalculator.compute(model: m, channel: 'FL');
      final idx2k = res.frequencies.indexWhere((f) => f >= 2000.0);
      final idx100 = res.frequencies.indexWhere((f) => f >= 100.0);
      expect(res.gainsDb[idx2k], closeTo(6.0, 0.45));
      expect(res.gainsDb[idx100], closeTo(0.0, 0.3));

      // 验证多声道 MC FFI 探针单独命中 channel=2 (C)
      const mcCode = '''
slider1:-5.0<-24,12,0.5>Center Trim
@init
gc = 1.0;
@slider
gc = 10 ^ (slider1 / 20);
@sample
spl2 *= gc;
''';
      final mcDb = lib.measureLiveprogResponse(
        mcCode,
        48000,
        params: const [-5.0],
        channel: 2,
        multichannel: true,
        nPoints: AppModel.lpResponsePoints,
        fMax: 20000.0,
      );
      expect(mcDb, isNotNull);
      expect(mcDb![mcDb.length ~/ 2], closeTo(-5.0, 0.15));
    });
  });
}
