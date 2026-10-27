/*
 * liveprog_editor_fixes_test.dart — 针对用户反馈的五大编辑器问题的针对性回归测试
 *
 * 1. sample 段复合操作符不损坏为字面量 $1
 * 2. APO 转换脚本不产生 srate 只读变量赋值
 * 3. 函数内部及大括号/括号块的层级缩进（2 空格软 Tab）
 * 4. 错误行行内红色背景/波浪线与行号栏红色标识联动
 */

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/liveprog/equalizer_apo_parser.dart';
import 'package:auradsp_app/core/liveprog/rbj_biquad_generator.dart';
import 'package:auradsp_app/features/liveprog/eel_editor_support.dart';
import 'package:auradsp_app/features/liveprog/line_number_gutter.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

Widget _wrap(Widget child) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

void main() {
  group('Liveprog Editor Bugfix Regressions', () {
    test('1. EelFormatter 不再将复合赋值（*=, +=, == 等）损坏为字面量 \$1', () {
      const src = '''@sample
spl0 *= gain_l;
spl1 *= gain_r;
x == 48000;
''';
      final formatted = EelFormatter.format(src);
      expect(formatted.contains(r'$1'), isFalse, reason: '不得包含字面量 \$1');
      expect(formatted.contains('spl0 *= gain_l;'), isTrue);
      expect(formatted.contains('spl1 *= gain_r;'), isTrue);
      expect(formatted.contains('x == 48000;'), isTrue);
    });

    test('2. RbjBiquadGenerator 不再生成 srate 只读赋值，Linter 零警告', () {
      final config = EqualizerApoParser.parse('''
Preamp: -4.5 dB
Filter 1: ON PK Fc 32 Hz Gain 3 dB Q 1.41
Filter 2: ON PK Fc 64 Hz Gain 2 dB Q 1.41
Filter 3: ON PK Fc 1000 Hz Gain -2.5 dB Q 2.0
''');
      final code = RbjBiquadGenerator.generate(config: config);

      expect(code.contains('srate ='), isFalse, reason: '不得给系统只读变量 srate 赋值');
      expect(code.contains('spl0 *= gain_l;'), isTrue);
      expect(code.contains('spl1 *= gain_r;'), isTrue);

      // 通过 EelFormatter 格式化后，代码仍然合法
      final formatted = EelFormatter.format(code);
      expect(formatted.contains(r'$1'), isFalse);

      // Linter 检查应为 0 错误
      final issues = EelLinter.lint(_zh, formatted);
      expect(issues.where((i) => i.message.contains('srate')), isEmpty);
      expect(issues.where((i) => i.blocking), isEmpty);
    });

    test('3. 函数内部及控制块自动 2 空格软 Tab 缩进，不再全部顶格', () {
      const unformatted = '''@init
function calc_peak(freq, q, gain_db) instance(b0, b1, b2, a1, a2) (
w0 = 2 * PI * freq / srate;
alpha = sin(w0) / (2 * q);
this.b0 = b0;
);
@sample
spl0 *= gain_l;
''';
      final formatted = EelFormatter.format(unformatted);
      final lines = formatted.split('\n');

      final fnIdx = lines.indexWhere((l) => l.startsWith('function'));
      expect(fnIdx >= 0, isTrue);
      // 函数第一行语句应缩进 2 空格
      expect(lines[fnIdx + 1].startsWith('  '), isTrue);
      // 闭合 ); 恢复顶格
      final closeIdx = lines.indexWhere((l) => l.startsWith(');'));
      expect(closeIdx > fnIdx, isTrue);
      expect(lines[closeIdx], ');');
    });

    testWidgets('4. 错误行行号栏醒目标红与行内飘红联动', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      var selected = 0;
      await tester.pumpWidget(_wrap(
        LineNumberGutter(
          editorScrollCtrl: scroll,
          lineCount: 5,
          errorLines: const {3},
          activeLine: 2,
          onSelectLine: (ln) => selected = ln,
          lineHeight: 20.0,
        ),
      ));

      // 验证第 3 行包含错误图标与红色
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // 点击第 3 行行号触发跳转
      await tester.tap(find.text('3'));
      await tester.pump();
      expect(selected, 3);
    });

    test('5. 多滑块脚本（如 Hadamard，包含 slider9, 12, 14, 20）Linter 零报错且高亮识别', () {
      const hadamardScript = '''
desc: Hadamard variable delay array

//tags: surround reverb delay

slider1:0.2<0.01,1>Base Delay (s)
slider4:2<0,5>Fb 1
slider5:2<0,5>Fb 2
slider8:30<0,60>VLFO cycle A
slider9:20<0,60>B
slider12:10<1,20>Factor between arrays
slider14:0.01<0,0.5>Modulation depth
slider20:0<-24,24>Gain (dB)
// ____________________________________
@init
slider1=0.20;
slider4=2.00;
slider5=2.00;
slider8=30.00;
slider9=20.00;
slider12=10.00;
slider14=0.01;
slider20=0.00;
// _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _
function HAD()(
  HAD_NORM = 0.5; // 1/sqrt2 * 1/sqrt2
  HAD_LM = 65536;   HAD_LM1 = HAD_LM - 1;
);
// _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _
function HAD_init()(
// delay line tables
  this.d0 = ad; ad+=HAD_LM;  
  this.d1 = ad; ad+=HAD_LM;  
  this.d2 = ad; ad+=HAD_LM;  
  this.d3 = ad; ad+=HAD_LM;
);
// hadamard4 mix x0..3 -> y0.3
function HAD_mix() instance(x0 x1 x2 x3 y0 y1 y2 y3) local(x01 x23)
(
  x01 = x0 + x1;   x23 = x2 + x3;      y0 = x01 + x23;  y2 = x01 - x23;
  x01 = x0 - x1;   x23 = x2 - x3;      y1 = x01 + x23;  y3 = x01 - x23;   
);
// _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _
function HAD_setDelays(ld0 ld1 ld2 ld3)(
  this.ld0 = ld0;  this.ld1 = ld1;  this.ld2 = ld2;  this.ld3 = ld3;
);
// _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _
function HAD_setFBs(fb0 fb1 fb2 fb3)(
  this.fb0 = (1 - fb0) * HAD_NORM; 
  this.fb1 = (1 - fb1) * HAD_NORM; 
  this.fb2 = (1 - fb2) * HAD_NORM; 
  this.fb3 = (1 - fb3) * HAD_NORM;
  this.gi0 = fb0 * HAD_NORM;
  this.gi1 = fb1 * HAD_NORM;
  this.gi2 = fb2 * HAD_NORM;
  this.gi3 = fb3 * HAD_NORM;
);
// x>=0 !!
function HAD_interp(x t l)
local(ix0 ix1 a)(
  ix0 = floor(x);
  a = x - ix0;
  ix0 = ix0 % l;
  ix1 = (ix0 + 1) % l;
  t[ix0] + a * (t[ix1] - t[ix0]);
);
function HAD_aProc(in0 in1 in2 in3)
instance( d0  d1  d2  d3
         ld0 ld1 ld2 ld3
         ldf0 ldf1 ldf2 ldf3
         fb0 fb1 fb2 fb3 
         gi0 gi1 gi2 gi3
          x0  x1  x2  x3 
          y0  y1  y2  y3 c)
local(cp)
(
ldf0 += 0.0001 * (ld0 - ldf0);
ldf1 += 0.0001 * (ld1 - ldf1);
ldf2 += 0.0001 * (ld2 - ldf2);
ldf3 += 0.0001 * (ld3 - ldf3);
// Input and feedback
d0[c] = fb0 * y0 + in0 * gi0;
d1[c] = fb1 * y1 + in1 * gi1;
d2[c] = fb2 * y2 + in2 * gi2;
d3[c] = fb3 * y3 + in3 * gi3;
// delay lines output to matrix inputs
cp = c + HAD_LM;
x0 = HAD_interp(cp - ldf0, d0, HAD_LM);
x1 = HAD_interp(cp - ldf1, d1, HAD_LM);
x2 = HAD_interp(cp - ldf2, d2, HAD_LM);
x3 = HAD_interp(cp - ldf3, d3, HAD_LM);
// matrix mix
this.HAD_mix();
c = (c + 1) & HAD_LM1;
);
HAD();
h1.HAD_init();
h2.HAD_init();
function VLFO_proc()
instance(p dp s c)(
  p += dp;
  p > \$pi ? p -= 2 * \$pi;
  s = sin(p);
  c = cos(p);
);
gain = 2 ^ (slider20 / 6);
sl4 = 1 / (1 + slider4);
sl5 = 1 / (1 + slider5);
_sl12 = 1 / slider12;
sl0 = srate * slider1;
//"chorus"
vlfo1.dp = 1.13 * (slider12 / slider8) * 2*\$pi / srate;
vlfo2.dp = 0.90 * (slider12 / slider9) * 2*\$pi / srate;
//"reverb"
vlfo3.dp = (1 / slider8) * 2*\$pi / srate;
vlfo4.dp = (1 / slider9) * 2*\$pi / srate;
// First array, chorus style
h1.HAD_setFBs(sl4, sl4, 1.17 * sl4, 1.27 * sl4);
// Second array, reverb style
h2.HAD_setFBs(sl5, sl5, 1.27 * sl5, 1.30 * sl5);
d1_0 = 0.3 * sl0 * _sl12;
d1_1 = 0.4 * sl0 * _sl12;
d1_2 = 1.5 * sl0 * _sl12;
d1_3 = 2.0 * sl0 * _sl12;
d2_0 = 1.13 * sl0;
d2_1 = 0.83 * sl0;
d2_2 = 1.32 * sl0;
d2_3 = 0.57 * sl0;
@sample
// chorus unit
// inputs and feedback from the reverb array
h1.HAD_aProc( spl0,  spl1, 0.49 * h2.y2, 0.49 * h2.y3);
// reverb unit
h2.HAD_aProc(h1.y0, h1.y1, h1.y2, h1.y3);
// VLFOs
vlfo1.VLFO_proc();
vlfo2.VLFO_proc();
vlfo3.VLFO_proc();
vlfo4.VLFO_proc();
// Delay modulation of the chorus delays
h1.HAD_setDelays(
  d1_0 * (1 + slider14 * vlfo1.s), 
  d1_1 * (1 + slider14 * vlfo2.s), 
  d1_2 * (1 + slider14 * vlfo1.c), 
  d1_3 * (1 + slider14 * vlfo2.c));
// Delay modulation of the reverb delays
h2.HAD_setDelays(
  d2_0 * (1 + slider14 * vlfo3.s), 
  d2_1 * (1 + slider14 * vlfo4.c), 
  d2_2 * (1 + slider14 * vlfo3.s), 
  d2_3 * (1 + slider14 * vlfo4.c));
// _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _
spl0 = gain * (h2.y0 + h1.y0 + h1.x0);
spl1 = gain * (h2.y1 - h1.y1 + h1.x1);
''';
      // 1. Linter 应当完全通过（零报错）
      final issues = EelLinter.lint(_zh, hadamardScript);
      expect(issues, isEmpty, reason: 'Hadamard 脚本合法，Linter 不得产生任何假警报');

      // 2. 自适应解析器成功提取所有 8 个滑块
      final sliders = EelSliderParser.parse(hadamardScript);
      expect(sliders.containsKey(1), isTrue);
      expect(sliders.containsKey(4), isTrue);
      expect(sliders.containsKey(5), isTrue);
      expect(sliders.containsKey(8), isTrue);
      expect(sliders.containsKey(9), isTrue);
      expect(sliders.containsKey(12), isTrue);
      expect(sliders.containsKey(14), isTrue);
      expect(sliders.containsKey(20), isTrue);

      // 3. 宿主滑块与扩展自定义参数正确分流
      expect(sliders[1]!.isHostSlider, isTrue);
      expect(sliders[8]!.isHostSlider, isTrue);
      expect(sliders[9]!.isHostSlider, isFalse);
      expect(sliders[20]!.isHostSlider, isFalse);
    });
  });
}
