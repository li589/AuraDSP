import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/eel_slider_parser.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/sliders/liveprog_sliders_panel.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EelSliderParser 动态变量匹配与热替换测试', () {
    test('hasVariableAssignment 与 replaceVariableValue 正确识别并替换 EEL2 脚本赋值', () {
      const script = '''
slider1:0<0,18,1{A,B,C}>dPreset
slider2:50<0,100,1>dBassGain
@init
dPreset = 18;
dBassGain = 100;
freq = 60.5;
@sample
spl0 = spl0;
''';

      expect(EelSliderParser.hasVariableAssignment(script, 'dPreset'), isTrue);
      expect(EelSliderParser.hasVariableAssignment(script, 'dBassGain'), isTrue);
      expect(EelSliderParser.hasVariableAssignment(script, 'freq'), isTrue);
      expect(EelSliderParser.hasVariableAssignment(script, 'unknownVar'), isFalse);
      // 词界测试：不应误匹配前缀重合的变量名
      expect(EelSliderParser.hasVariableAssignment(script, 'dPre'), isFalse);

      final replaced1 = EelSliderParser.replaceVariableValue(script, 'dPreset', 3, step: 1.0);
      expect(replaced1, contains('dPreset = 3;'));
      expect(replaced1, isNot(contains('dPreset = 18;')));

      final replaced2 = EelSliderParser.replaceVariableValue(replaced1, 'freq', -12.5, step: 0.1);
      expect(replaced2, contains('freq = -12.5;'));
    });

    test('alignCodeWithSliders 在编译前完成声明默认值与代码硬编码值的全量对齐', () {
      const script = '''
slider1:0<0,18,1{Off,Preset1,Preset2}>dPreset
slider2:50<0,100,1>dBassGain
@init
dPreset = 18;
dBassGain = 100;
@sample
spl0 = spl0;
''';

      final metas = EelSliderParser.parse(script);
      final sliderValues = <int, double>{
        1: 2.0, // 用户或状态恢复为 Preset2
      };

      final aligned = EelSliderParser.alignCodeWithSliders(script, sliderValues, metas);
      // dPreset 应该被对齐为 sliderValues 里的 2
      expect(aligned, contains('dPreset = 2;'));
      // dBassGain 未在 sliderValues 中，应被对齐为 meta.defaultVal (50)
      expect(aligned, contains('dBassGain = 50;'));
      expect(aligned, isNot(contains('dBassGain = 100;')));
    });
  });

  group('AppModel Liveprog 滑块与预设下拉实时生效链路测试', () {
    test('setLiveprogCode 自动对齐代码并注册 lpSliderMetas 与下发命令', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      const script = '''
slider1:0<0,18,1{Off,Preset1,Preset2}>dPreset
slider2:80<0,100,1>dBassGain
@init
dPreset = 18;
dBassGain = 100;
@sample
spl0 = spl0;
''';

      model.setLiveprogCode(script);

      // 验证 metas 已被记录
      expect(model.lpSliderMetas.containsKey(1), isTrue);
      expect(model.lpSliderMetas.containsKey(2), isTrue);

      // 验证 lpCode 被 alignCodeWithSliders 规范化
      expect(model.lpCode, contains('dPreset = 0;'));
      expect(model.lpCode, contains('dBassGain = 80;'));

      // 验证向测试总线发送了 setParamStr
      expect(
        model.sentStrParamsForTesting.any((p) => p['id'] == 'liveprog.code'),
        isTrue,
      );
    });

    test('离散步进/预设下拉切换时立即触发代码热重载并下发', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      const script = '''
slider1:0<0,2,1{Flat,Punchy,Deep}>dPreset
@init
dPreset = 0;
@sample
spl0 = spl0;
''';

      model.setLiveprogCode(script);
      final initialSentCount = model.sentStrParamsForTesting.length;

      // 模拟用户下拉选择预设 "Punchy" (index 1)
      final meta = model.lpSliderMetas[1]!;
      model.setLiveprogSliderVal(1, 1.0, meta: meta);

      // 验证模型状态立即更新
      expect(model.lpSliderValues[1], equals(1.0));
      expect(model.lpCode, contains('dPreset = 1;'));

      // 离散参数无防抖，立即下发 setParamStr
      expect(model.sentStrParamsForTesting.length, equals(initialSentCount + 1));
      // 同时作为 slider1 也会向 engine 参数表下发 setFloat
      expect(
        model.sentParamsForTesting.any((p) => p['id'] == 'liveprog.param1' && p['value'] == 1.0),
        isTrue,
      );
    });

    test('连续滑块调节在 35ms 节流下重载代码并下发', () async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      const script = '''
slider1:0<-12,12,0.1>gain
@init
gain = 0;
@sample
spl0 = spl0;
''';

      model.setLiveprogCode(script);
      final initialSentCount = model.sentStrParamsForTesting.length;

      final meta = model.lpSliderMetas[1]!;
      // 模拟快速拖动滑块
      model.setLiveprogSliderVal(1, 3.5, meta: meta);
      model.setLiveprogSliderVal(1, 6.0, meta: meta);

      // 立即检查：代码中的数值已经及时更新
      expect(model.lpCode, contains('gain = 6;'));

      // 等待 50ms 超过 35ms 节流窗口
      await Future.delayed(const Duration(milliseconds: 50));

      expect(model.sentStrParamsForTesting.length, greaterThan(initialSentCount));
    });
  });

  group('LiveprogSlidersPanel UI 交互端到端测试', () {
    testWidgets('枚举下拉框选中预设项立即更新代码并通知引擎', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      const script = '''
slider1:0<0,2,1{Normal,BassBoost,TrebleBoost}>presetMode
@init
presetMode = 0;
@sample
spl0 = spl0;
''';

      model.setLiveprogCode(script);
      final metas = EelSliderParser.parse(script);

      await tester.pumpWidget(_wrap(LiveprogSlidersPanel(
        model: model,
        activeSliders: metas,
      )));
      await tester.pumpAndSettle();

      // 验证界面渲染了预设名与当前选项 Normal
      expect(find.text('Normal'), findsOneWidget);

      // 点击下拉框打开菜单
      await tester.tap(find.text('Normal'));
      await tester.pumpAndSettle();

      // 验证下拉列表项
      expect(find.text('BassBoost'), findsOneWidget);
      expect(find.text('TrebleBoost'), findsOneWidget);

      // 选择 BassBoost
      await tester.tap(find.text('BassBoost').last);
      await tester.pumpAndSettle();

      // 验证模型状态与代码已被同步修改为 1
      expect(model.lpSliderValues[1], equals(1.0));
      expect(model.lpCode, contains('presetMode = 1;'));
      expect(find.text('BassBoost'), findsOneWidget);
    });
  });
}
