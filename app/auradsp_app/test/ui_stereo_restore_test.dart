import 'package:auradsp_app/core/param_schema.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-19 用户上报回归：立体声扩展滑块"打开都是 0 → 自己跑到 50%"、
/// 高级面板 0% 但归位按钮回到 50%、且 0% 不是用户上次的会话记忆。
///
/// 根因（两个叠加缺陷）：
/// 1. `getParam` 自填充缓存优先于 getter——会话恢复（postApply）/readback/
///    resetStereoBand 走字段直写不经过缓存，UI 读到陈旧值；"归位默认"
///    按钮恰好走 setParam（同步刷缓存）才显示正确，两条显示链路打架。
/// 2. 开关关闭时回放把引擎 stereo.mix 写 0（静音语义，k=0 直发），
///    readback 又把 0 当"引擎真相"回写 UI 字段 → 滑块自己清零 →
///    autoSave 把 0 存回会话（记忆销毁）；下次打开开关被
///    setStereoEnabled 的兜底拉回 0.5（"自己跑到 50%"）。
Map<String, dynamic> _paramsEvt({double stereoMix = 0.0, int stereoBandUsed = 0}) =>
    {
      // 'params' 处理器前段的非空断言键必须全部在场
      'evt': 'params',
      'bassEnable': 0,
      'bassGain': 0.0,
      'reverbPreset': -1,
      'stereoMix': stereoMix,
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
      'stereoBandUsed': stereoBandUsed,
      'convMix': 1.0,
      'shelfEnable': 0,
      'shelfFreq': 100.0,
      'shelfGain': 0.0,
    };

void main() {
  group('立体声恢复链回归（2026-10-19）', () {
    test('getParam 以字段真相为准：字段直写立即可见', () {
      final m = AppModel(testing: true);
      // UI 先读一次（旧实现此时把默认值自填充进缓存）
      expect(m.getParam(ParamRegistry.stereoBands[0]), 0.5);
      expect(m.getParam(ParamRegistry.stereoWide), 0.0);

      // 模拟会话恢复 postApply 的字段直写路径
      m.stereoBands[0] = 0.158;
      m.setStereoMix(0.5);

      // 旧实现：band 缓存命中 0.5（陈旧）、mix 缓存命中 0.0（陈旧）
      expect(m.getParam(ParamRegistry.stereoBands[0]), 0.158,
          reason: 'postApply 直写后滑块必须立即反映新值');
      expect(m.getParam(ParamRegistry.stereoWide), 0.5);
    });

    test('开关关闭时 readback 不清零 UI 滑块记忆（会话销毁根因）', () {
      final m = AppModel(testing: true);
      m.setStereoMix(0.5);
      m.setStereoEnabled(false); // 用户关着开关退出（UI 值保留）
      expect(m.stereoMix, 0.5);

      // 引擎侧此时是静音语义 0（回放已推 0），对账不得当作滑块真相
      m.handleMessageForTesting(_paramsEvt(stereoMix: 0.0));
      expect(m.stereoMix, 0.5,
          reason: '静音值 0 不代表用户滑块记忆，回写=销毁会话记忆');
    });

    test('开关开启时 readback 正常对账（引擎钳位/纠正仍生效）', () {
      final m = AppModel(testing: true);
      m.setStereoEnabled(true);
      m.setStereoMix(0.4);
      // UI 0.4 × widenMax 0.75 = 引擎 0.3；回读 0.3 应还原为 0.4
      m.handleMessageForTesting(_paramsEvt(stereoMix: 0.3, stereoBandUsed: 1));
      expect(m.stereoMix, closeTo(0.4, 1e-9));
    });

    test('打开开关且滑块为 0 时的兜底恢复为 0.5（既有 UX 语义保留）', () {
      final m = AppModel(testing: true);
      expect(m.stereoMix, 0.0);
      m.setStereoEnabled(true);
      expect(m.stereoMix, 0.5);
    });
  });

  group('延迟刷新三档口径（2026-10-19 用户上报"点不动"）', () {
    test('低音塑形/差分环绕/空间音效都有 ↻，且语义各归其位', () {
      // 三张卡（用户点不动的）都必须可刷新
      expect(AppModel.hasLatencyRefresh('bass_shaping'), isTrue);
      expect(AppModel.hasLatencyRefresh('haas'), isTrue);
      expect(AppModel.hasLatencyRefresh('spatial'), isTrue);
      // 2026-10-19 探针升级：haas/spatial 已入引擎 kSupported（逐声道首非零
      // 取最大），不再是「结构性不可测」——必须走真探针而非标称刷新档。
      expect(AppModel.isLatencyProbeSupported('haas'), isTrue);
      expect(AppModel.isLatencyProbeSupported('spatial'), isTrue);
      // 低音塑形走别名真探针：引擎实名 shelf + bassmono（均受支持）
      expect(AppModel.kLatencyProbeAliases['bass_shaping'],
          ['shelf', 'bassmono']);
    });

    test('haas/spatial 走真探针档：tick 前进 + 实测真实值（不再冒充标称）', () async {
      final m = AppModel(testing: true);
      m.setHaasEnabled(true);
      final haasTick0 = m.getComponentLatencyTick('haas');
      final spTick0 = m.getComponentLatencyTick('spatial');
      await m.refreshComponentLatency('haas');
      await m.refreshComponentLatency('spatial');
      expect(m.getComponentLatencyTick('haas'), greaterThan(haasTick0));
      expect(m.getComponentLatencyTick('spatial'), greaterThan(spTick0));
      // 测试环境可加载真实 DLL：haas 按当前延迟（默认 12ms）实测出 576 样本
      // （@48k → 12.0ms）；spatial 诚实测出 0ms（链上无前瞻）。二者都不再
      // 走「≈标称」估算档。
      expect(m.componentLatency('haas').measured, isTrue,
          reason: 'haas 应走真探针实测');
      expect(m.componentLatency('haas').ms, closeTo(12.0, 0.5));
      expect(m.componentLatency('spatial').measured, isTrue,
          reason: 'spatial 应走真探针实测');
      expect(m.componentLatency('spatial').ms, closeTo(0.0, 0.1));
    });
  });
}
