// master_status_console_test.dart — 专业硬件总控舱与延迟计算统一性测试
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('MasterStatusConsole 专业工控态监视舱测试', () {
    testWidgets('渲染固态硬件 LED 与 Monospace PDC 延迟，支持旁路点击与延迟刷新', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      bool toggleBypassCalled = false;
      bool refreshLatencyCalled = false;

      await tester.pumpWidget(_wrap(
        MasterStatusConsole(
          engineState: 1,
          bypass: false,
          live: true,
          latencyMs: 3.5,
          onToggleBypass: () => toggleBypassCalled = true,
          onRefreshLatency: () => refreshLatencyCalled = true,
        ),
      ));
      await tester.pumpAndSettle();

      // 1. 验证没有 AI 味道的扩散呼吸圆点，呈现专业 DSP ACTIVE 状态与 PDC 延迟
      expect(find.text('DSP ACTIVE'), findsOneWidget);
      expect(find.text('PDC'), findsOneWidget);
      expect(find.text('3.5 ms'), findsOneWidget);

      // 2. 点击 DSP 区域触发旁路切换
      await tester.tap(find.text('DSP ACTIVE'));
      expect(toggleBypassCalled, isTrue);

      // 3. 点击延迟区域触发全链路测量与时钟同步
      await tester.tap(find.text('3.5 ms'));
      expect(refreshLatencyCalled, isTrue);
    });

    testWidgets('DSP 旁路与待机状态正常显示', (tester) async {
      await tester.pumpWidget(_wrap(
        const MasterStatusConsole(
          engineState: 1,
          bypass: true,
          live: true,
          latencyMs: 0.0,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('DSP BYPASS'), findsOneWidget);
      expect(find.text('0.0 ms'), findsOneWidget);
    });
  });

  group('效果器延迟计算与 UI 颜色规范统一性测试', () {
    test('各状态色彩规范严格统一（实测、实时推算、测定中、零延迟、未测定）', () {
      final p = auraDark;

      // 1. 测定中 probing: 活力青
      final cProbing = LatencyPresenter.colorByMode(
        mode: LatencyMode.probing,
        ms: 0.0,
        p: p,
      );
      expect(cProbing, p.accent);

      // 2. 实测 measured (< 5ms 录音监听级纯绿)
      final cMeasuredLow = LatencyPresenter.colorByMode(
        mode: LatencyMode.measured,
        ms: 2.5,
        p: p,
      );
      expect(cMeasuredLow, p.success);

      // 3. 实时推算 estimated (统一天青/Accent)
      final cEst = LatencyPresenter.colorByMode(
        mode: LatencyMode.estimated,
        ms: 12.0,
        p: p,
      );
      expect(cEst, p.accent);

      // 4. 零延迟直通 zero 统一为录音监听级高保真绿 (与 0.0ms 其它效果器一致)
      final cZero = LatencyPresenter.colorByMode(
        mode: LatencyMode.zero,
        ms: 0.0,
        p: p,
      );
      expect(cZero, p.success);

      // 5. 未测定 unmeasured (次级灰)
      final cUnmeasured = LatencyPresenter.colorByMode(
        mode: LatencyMode.unmeasured,
        ms: 0.0,
        p: p,
      );
      expect(cUnmeasured, p.textDim);
    });

    test('组件延迟自动提供实时参数推算值（Convolver / Limiter / Spatial / Bass）', () {
      final model = AppModel(testing: true);

      // Convolver 开启时，根据帧数与采样率推算
      model.convEnabled = true;
      model.convReady = true;
      model.convFrames = 480;
      final convLat = model.componentLatency('convolver');
      expect(convLat.ms, closeTo(10.0, 0.01));
      expect(convLat.estimated, isTrue);
      expect(convLat.mode, LatencyMode.estimated);

      // Limiter 开启时，实时推算 1.5ms 前瞻
      model.limiterOn = true;
      final limitLat = model.componentLatency('limiter');
      expect(limitLat.ms, 1.5);
      expect(limitLat.estimated, isTrue);
      expect(limitLat.mode, LatencyMode.estimated);

      // Spatial 开启时，诚实零算法延迟（近耳直达实时输出）
      model.spatialOn = true;
      final spatLat = model.componentLatency('spatial');
      expect(spatLat.ms, 0.0);
      expect(spatLat.mode, LatencyMode.zero);
    });
  });
}

