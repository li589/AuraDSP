/*
 * param_schema_test.dart — 全链路参数元数据注册中心与 AppModel 数据驱动对账测试 (Phase 3)
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/param_schema.dart';
import 'package:auradsp_app/core/state.dart';

void main() {
  group('ParamRegistry Schema & Metadata Consistency Tests', () {
    test('全量参数表 ParamRegistry.allParams 完整登记与唯一性检查', () {
      expect(ParamRegistry.allParams.isNotEmpty, isTrue);
      expect(ParamRegistry.sections.length, greaterThanOrEqualTo(23));

      final seenIds = <String>{};
      for (final spec in ParamRegistry.allParams) {
        expect(spec.id.isNotEmpty, isTrue, reason: '参数 id 不能为空');
        expect(spec.section.isNotEmpty, isTrue, reason: '参数 section 不能为空');
        expect(spec.key.isNotEmpty, isTrue, reason: '参数 key 不能为空');
        expect(seenIds.contains(spec.id), isFalse,
            reason: '参数 id 必须全局唯一: ${spec.id}');
        seenIds.add(spec.id);

        // 数值型边界合法性校验
        if (spec.type == ParamType.float || spec.type == ParamType.int32) {
          expect(spec.min, lessThanOrEqualTo(spec.max),
              reason: '参数 ${spec.id} 的 min 必须 <= max');
          if (spec.defaultValue is num) {
            final dv = (spec.defaultValue as num).toDouble();
            expect(dv, greaterThanOrEqualTo(spec.min - 1e-6),
                reason: '参数 ${spec.id} 默认值必须 >= min');
            expect(dv, lessThanOrEqualTo(spec.max + 1e-6),
                reason: '参数 ${spec.id} 默认值必须 <= max');
          }
        }
      }

      // 索引表映射一致性
      expect(ParamRegistry.byId.length, equals(ParamRegistry.allParams.length));
      for (final spec in ParamRegistry.allParams) {
        expect(ParamRegistry.byId[spec.id], same(spec));
      }
    });

    test('ParamSpec clamp 与 cast 类型安全兜底', () {
      final tubeGainSpec = ParamRegistry.tubeGain;
      expect(tubeGainSpec.clamp(20.0), closeTo(12.0, 1e-6));
      expect(tubeGainSpec.clamp(-10.0), closeTo(-3.0, 1e-6));
      expect(tubeGainSpec.clamp(5.5), closeTo(5.5, 1e-6));

      expect(tubeGainSpec.cast('8.5'), closeTo(8.5, 1e-6));
      expect(tubeGainSpec.cast(null), equals(tubeGainSpec.defaultValue));

      final tubeStyleSpec = ParamRegistry.tubeStyle;
      expect(tubeStyleSpec.clamp(5), equals(2));
      expect(tubeStyleSpec.clamp(-1), equals(0));
      expect(tubeStyleSpec.cast('2'), equals(2));

      final tubeEnableSpec = ParamRegistry.tubeEnable;
      expect(tubeEnableSpec.cast(1), isTrue);
      expect(tubeEnableSpec.cast(0), isFalse);
      expect(tubeEnableSpec.cast(true), isTrue);
      expect(tubeEnableSpec.cast(null), equals(tubeEnableSpec.defaultValue));
    });
  });

  group('AppModel Data-Driven getParam / setParam Integration Tests', () {
    test('getParam 默认值回显与 setParam 安全写入、钳位与更新通知', () {
      final m = AppModel(testing: true);

      // 默认值回显
      expect(m.getParam(ParamRegistry.tubeGain), closeTo(4.5, 1e-6));
      expect(m.getParam(ParamRegistry.tubeEnable), isFalse);
      expect(m.getParam(ParamRegistry.inputGain), closeTo(0.0, 1e-6));

      // 设值并验证
      var notifyCount = 0;
      m.addListener(() => notifyCount++);

      m.setParam(ParamRegistry.tubeGain, 7.5);
      expect(m.getParam(ParamRegistry.tubeGain), closeTo(7.5, 1e-6));
      expect(m.tubeGain, closeTo(7.5, 1e-6), reason: '双向绑定到原有字段');
      expect(notifyCount, greaterThan(0));

      // 钳位验证
      m.setParam(ParamRegistry.tubeGain, 99.0);
      expect(m.getParam(ParamRegistry.tubeGain), closeTo(12.0, 1e-6));
      expect(m.tubeGain, closeTo(12.0, 1e-6));

      // 开关验证
      m.setParam(ParamRegistry.tubeEnable, true);
      expect(m.getParam(ParamRegistry.tubeEnable), isTrue);
      expect(m.tubeOn, isTrue);
    });

    test('getParamById 与 setParamById 动态反射通道', () {
      final m = AppModel(testing: true);

      m.setParamById('shelf.freq', 150.0);
      expect(m.getParamById('shelf.freq'), closeTo(150.0, 1e-6));
      expect(m.shelfFreq, closeTo(150.0, 1e-6));

      m.setParamById('bass.mode', 1);
      expect(m.getParamById('bass.mode'), equals(1));
      expect(m.bassMode, equals(1));
    });

    test('isSectionEnabled 与 isStageEnabled 一致性联动', () {
      final m = AppModel(testing: true);

      expect(m.isSectionEnabled('input'), isTrue, reason: '输入门始终启用');
      expect(m.isSectionEnabled('routing'), isTrue, reason: '路由始终启用');

      expect(m.isSectionEnabled('tube'), isFalse);
      m.setParam(ParamRegistry.tubeEnable, true);
      expect(m.isSectionEnabled('tube'), isTrue);

      expect(m.isSectionEnabled('comp'), isFalse);
      m.setParam(ParamRegistry.compEnable, true);
      expect(m.isSectionEnabled('comp'), isTrue);
    });

    test('所有参数 spec.read(m) 与 spec.write(m, val) 100% 往返无异常', () {
      final m = AppModel(testing: true);

      for (final spec in ParamRegistry.allParams) {
        final val = spec.read(m);
        expect(val, isNotNull, reason: '${spec.id} 无法读取');

        // 写回默认值应不抛出异常
        expect(() => spec.write(m, spec.defaultValue), returnsNormally,
            reason: '${spec.id} 无法写入默认值');
      }
    });
  });

  group('Isolate Full Readback Simulation Tests (14 Parameter Categories)', () {
    test('params 消息包含此前遗漏的 14 类参数时，AppModel 状态与 _paramValues 字典全量更新', () {
      final m = AppModel(testing: true);

      final fakeParamsMsg = {
        'evt': 'params',
        'bassEnable': 1,
        'bassGain': 6.0,
        'reverbPreset': 2,
        'stereoMix': 0.8,
        'eqEnable': 1,
        'postGain': -2.0,
        'limiterEnable': 1,
        'channelsMode': 0,
        'lpEnable': 1,
        'lpStatus': 1,
        'convEnable': 0,
        'convReady': 0,
        'convFrames': 0,
        'convChannels': 0,
        'convSrcRate': 0,
        'convPeak': 0.0,
        'tubeEnable': 1,
        'xfeedEnable': 1,
        'stereoBandUsed': 1,
        'convMix': 1.0,
        'ddcEnable': 0,
        'ddcReady': 0,
        'shelfEnable': 1,
        'shelfFreq': 120.0,
        'shelfGain': 3.0,
        'bassmonoEnable': 1,
        'bassmonoFreq': 150.0,
        'haasEnable': 1,
        'haasDelay': 15.0,
        'haasMix': 0.8,
        'haasSide': 1,
        // 14 类此前遗漏的参数：
        'inputGain': 2.5,
        'inputBalanceL': 0.9,
        'inputBalanceR': 0.85,
        'tubeGain': 8.0,
        'stereoEnable': 1,
        'stereoBands': [0.1, 0.2, 0.3, 0.4, 0.5],
        'fvRoomSize': 1.5,
        'fvWidth': 1.8,
        'eqBandsCount': 10,
        'eqFilter': 1,
        'eqInterp': 1,
        'eqQ': 3.2,
        'bassMode': 2,
        'bassIntensity': 0.75,
        'lpParams': [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
        'chainOrder': 'tube,comp,bass,eq,reverb,post',
      };

      m.handleMessageForTesting(fakeParamsMsg);

      // 验证此前遗漏的 14 类参数全量被 AppModel 采纳
      expect(m.inputGain, closeTo(2.5, 1e-6));
      expect(m.inputBalanceL, closeTo(0.9, 1e-6));
      expect(m.inputBalanceR, closeTo(0.85, 1e-6));
      expect(m.tubeGain, closeTo(8.0, 1e-6));
      expect(m.stereoOn, isTrue);
      expect(m.stereoBands[0], closeTo(0.1, 1e-6));
      expect(m.stereoBands[4], closeTo(0.5, 1e-6));
      expect(m.fvRoomSize, closeTo(1.5, 1e-6));
      expect(m.fvWidth, closeTo(1.8, 1e-6));
      expect(m.eqBandsCount, equals(10));
      expect(m.eqFilter, equals(1));
      expect(m.eqInterp, equals(1));
      expect(m.eqQ, closeTo(3.2, 1e-6));
      expect(m.bassMode, equals(2));
      expect(m.bassIntensity, closeTo(0.75, 1e-6));
      expect(m.lpParams[0], closeTo(0.1, 1e-6));
      expect(m.lpParams[7], closeTo(0.8, 1e-6));
      expect(m.graphOrder, equals('tube,comp,bass,eq,reverb,post'));

      // 验证 _paramValues 同步
      expect(m.getParam(ParamRegistry.tubeGain), closeTo(8.0, 1e-6));
      expect(m.getParam(ParamRegistry.inputGain), closeTo(2.5, 1e-6));
      expect(m.getParam(ParamRegistry.bassMode), equals(2));
    });
  });
}
