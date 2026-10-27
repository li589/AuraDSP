// P-032 回归测试 —— 四项 UI 缺陷的防回归守卫。
//
// 1. 低音增强「模式」选了会被弹回「自然低音」：根因是 bass.mode 从未下发
//    引擎，引擎回读恒为 0 → 全量回读把 UI 覆盖。断言：setBassMode 必须真的
//    下发 bass.mode，且回读到真实值后 UI 保持不变。
// 2. 空间混响预设「参数和 3D 图跳两次」：WP1 后预设只推 reverb.preset，
//    3D 可视化参数留在本地；引擎回读 freeverb.* 只在自定义态(-2)对账。
//    断言：预设态不下发 freeverb.*，且回读不改写本地可视化值。
// 3. 混响「自定义」标签被回读吞掉：负值 -2 从不下发引擎，回读无条件覆盖。
//    断言：本地为自定义态时，回读不得把它改回预设号。
// 4. 脉冲响应「清除 IR」把效果器开关也关了：断言清除后开关保持开启、
//    状态回到「未加载」；同时响度卡片顶部不得再出现与气泡重复的说明行。
import 'dart:io';

import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与引擎 getParams 同形的回读消息（字段集与 param_schema_test 一致）。
Map<String, dynamic> fakeParams({
  int reverbPreset = 0,
  int bassMode = 0,
  double fvRoomSize = 1.2,
  double fvWidth = 1.0,
}) {
  return {
    'evt': 'params',
    'bassEnable': 1,
    'bassGain': 6.0,
    'reverbPreset': reverbPreset,
    'stereoMix': 0.5,
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
    'inputGain': 2.5,
    'inputBalanceL': 0.9,
    'inputBalanceR': 0.85,
    'tubeGain': 8.0,
    'stereoEnable': 1,
    'stereoBands': [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
    'fvRoomSize': fvRoomSize,
    'fvWidth': fvWidth,
    'eqBandsCount': 10,
    'eqFilter': 1,
    'eqInterp': 1,
    'eqQ': 3.2,
    'bassMode': bassMode,
    'bassIntensity': 0.75,
    'lpParams': [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
    'chainOrder': 'tube,comp,bass,eq,reverb,post',
  };
}

/// 是否下发了某个参数（最后一次取值）。
bool sentWith(AppModel m, String id, {Object? value}) {
  final hits = m.sentParamsForTesting.where((e) => e['id'] == id).toList();
  if (hits.isEmpty) return false;
  if (value == null) return true;
  final v = hits.last['value'];
  if (v is num && value is num) return (v - value).abs() < 1e-6;
  return v == value;
}

void main() {
  group('P-032 低音增强模式不被回读弹回', () {
    test('setBassMode 必须把 bass.mode 下发到引擎', () {
      final m = AppModel(testing: true);
      m.setBassMode(2);
      expect(sentWith(m, 'bass.mode', value: 2), isTrue,
          reason: 'bass.mode 未下发 → 引擎回读恒 0 → UI 模式被弹回"自然低音"');
      expect(m.bassMode, 2);
    });

    test('引擎回读到真实模式值时 UI 保持不变', () {
      final m = AppModel(testing: true);
      m.setBassMode(1);
      m.handleMessageForTesting(fakeParams(bassMode: 1));
      expect(m.bassMode, 1);
    });
  });

  group('P-032 空间混响预设不再跳变两次', () {
    test('selectReverbPreset 只推唯一开关，不再下发 freeverb.*', () {
      final m = AppModel(testing: true);
      m.selectReverbPreset(1); // 中音乐厅：room 1.1 width 0.9
      expect(sentWith(m, 'reverb.preset', value: 1), isTrue);
      expect(sentWith(m, 'freeverb.roomsize'), isFalse,
          reason: 'WP1：预设态的可视化参数只留在本地，freeverb.* 是自定义态 ABI');
      expect(sentWith(m, 'freeverb.width'), isFalse);
      expect(m.fvRoomSize, closeTo(1.1, 1e-6));
      expect(m.fvWidth, closeTo(0.9, 1e-6));

      // 进入自定义态后才把整套自定义参数下发引擎。
      m.selectReverbPreset(-2);
      expect(sentWith(m, 'freeverb.roomsize', value: 1.1), isTrue);
      expect(sentWith(m, 'freeverb.width', value: 0.9), isTrue);
    });

    test('预设切换后回读不改写本地 3D 值（不跳变）', () {
      final m = AppModel(testing: true);
      m.selectReverbPreset(3); // 音乐厅：room 1.3 width 1.0
      // 引擎回读仍是旧的自定义参数值——预设态不得用它覆盖本地可视化值。
      m.handleMessageForTesting(
          fakeParams(reverbPreset: 3, fvRoomSize: 0.2, fvWidth: 0.2));
      expect(m.fvRoomSize, closeTo(1.3, 1e-6));
      expect(m.fvWidth, closeTo(1.0, 1e-6));
    });

    test('自定义态下 fv* 回读正常对账', () {
      final m = AppModel(testing: true);
      m.selectReverbPreset(-2);
      m.handleMessageForTesting(
          fakeParams(reverbPreset: 0, fvRoomSize: 1.5, fvWidth: 1.8));
      expect(m.reverbPreset, -2);
      expect(m.fvRoomSize, closeTo(1.5, 1e-6));
      expect(m.fvWidth, closeTo(1.8, 1e-6));
    });

    test('自定义态(-2) 不被引擎回读改回预设号', () {
      final m = AppModel(testing: true);
      m.selectReverbPreset(1);
      m.setReverbCustomParam('decay', 0.62);
      expect(m.reverbPreset, -2);
      // 引擎只认 0..18，自定义态从不下发 → 回读仍是旧 preset 号
      m.handleMessageForTesting(fakeParams(reverbPreset: 1));
      expect(m.reverbPreset, -2,
          reason: '自定义标签被回读吞掉 → "自定义"芯片跳回预设芯片');
    });
  });

  group('P-032 脉冲响应清除不再关掉效果器开关', () {
    test('clearConvolver 保持开关开启并回到未加载态', () {
      final m = AppModel(testing: true);
      m.convEnabled = true;
      m.convReady = true;
      m.convIrPath = r'C:\AuraDSP\ir\hall.irs';
      m.convFrames = 48000;
      m.convChannels = 2;
      m.convSrcRate = 48000;

      m.clearConvolver();

      expect(m.convEnabled, isTrue, reason: '清除 IR 不应关掉效果器开关');
      expect(m.convReady, isFalse);
      expect(m.convIrPath, isNull);
      expect(m.convFrames, 0);
      expect(m.convChannels, 0);
    });
  });

  group('P-032 响度卡片不再重复展示说明行', () {
    test('卡片源码不得再裸用 Text(l.loudnessHint)', () {
      final f = File('lib/features/effects/loudness_card.dart');
      expect(f.existsSync(), isTrue, reason: '源码路径不对');
      final src = f.readAsStringSync();
      expect(src.contains('Text(l.loudnessHint'), isFalse,
          reason: '说明文案已由「补偿强度」滑块的气泡承载，卡片顶部不应再重复一行');
    });
  });
}
