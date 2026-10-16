// chain_groups_test.dart — Phase 2 链组节点回归：
// 6 组头渲染 + 空间行（电平槽 20）+ 整组旁路语义（跳过常驻限幅器）。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/chain_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: ChainPage(model: model)),
    );

void main() {
  testWidgets('chain groups render with spatial row', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = AppModel(testing: true);
    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();
    // 6 组头（音色与动态组覆盖默认链序的 dyneq..bass 连续段）。
    // 'Spatial' 出现 3 次：组头 + 空间行 + 底部信号流节点，单独断言。
    for (final name in [
      'Input Shaping',
      'Tone & Dynamics',
      'EQ & Script',
      'Soundstage',
      'Output Stage',
    ]) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.text('Spatial'), findsNWidgets(3));
    // 空间行（B 组单行）与默认顺序（haas 之后）
    expect(kDefaultCoreOrder.indexOf('spatial'),
        kDefaultCoreOrder.indexOf('haas') + 1);
    expect(model.stageMeterIndex('spatial'), 20);
  });

  test('group bypass toggles members but spares limiter', () {
    final model = AppModel(testing: true);
    // 空间组：开
    model.setChainGroup('chSpatial', true);
    expect(model.spatialOn, isTrue);
    // 输出组：关——exciter/reverb/loudness 全关，限幅器不动
    expect(model.limiterOn, isTrue);
    model.setChainGroup('chOut', false);
    expect(model.limiterOn, isTrue,
        reason: 'limiter stays on under group bypass');
    // 未知组：无操作，不抛
    model.setChainGroup('nope', true);
    // 输入组：开后再关
    model.setChainGroup('chInput', true);
    expect(model.gateOn, isTrue);
    expect(model.filterOn, isTrue);
    model.setChainGroup('chInput', false);
    expect(model.gateOn, isFalse);
    expect(model.filterOn, isFalse);
  });
}
