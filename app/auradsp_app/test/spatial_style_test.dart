// spatial_style_test.dart — 2026-10-26: spatial.style=3 自定义态回归
//
// 引擎语义（engine_param_table.h）：
//   - style 0/1/2 是整组预设，hook_spatial_style 会写入 room/width/center；
//   - 手动改 room/width/center 时 hook_spatial_custom_param 把 style 置 3；
//   - style=3 显式写入不覆盖当前 room/width/center。
//
// UI 侧此前三处 clamp(0,2) 把引擎的 3 钳成 2，且 setSpatialStyle 在 3 时
// 误套中性预设，导致自定义态不可见、点“中性”反而覆盖自定义值。
import 'package:auradsp_app/core/param_schema.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 'params' 处理器前段的非空断言键必须全部在场（参考 ui_stereo_restore_test）。
Map<String, dynamic> _paramsEvt({
  int spatialStyle = 0,
  double room = 0.7,
  double width = 1.0,
  double center = 0.8,
}) =>
    {
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
      'spatialEnable': 1,
      'spatialStyle': spatialStyle,
      'spatialRoom': room,
      'spatialWidth': width,
      'spatialCenter': center,
    };

void main() {
  group('spatial.style=3 自定义态（2026-10-26）', () {
    test('params 回读 style=3 不再被钳成 2', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.handleMessageForTesting(_paramsEvt(
        spatialStyle: 3,
        room: 0.42,
        width: 1.28,
        center: 0.64,
      ));

      expect(m.spatialStyle, 3, reason: '引擎自定义态必须原样回读');
      expect(m.spatialRoom, closeTo(0.42, 1e-9));
      expect(m.spatialWidth, closeTo(1.28, 1e-9));
      expect(m.spatialCenter, closeTo(0.64, 1e-9));
    });

    test('setSpatialStyle(3) 保留自定义值，只下发 style', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.setSpatialStyle(0);
      m.setSpatialRoom(0.42);
      m.setSpatialWidth(1.28);
      m.setSpatialCenter(0.64);
      expect(m.spatialStyle, 3, reason: '手动改参数应立即进入自定义态');

      m.sentParamsForTesting.clear();
      m.setSpatialStyle(3);

      expect(m.spatialStyle, 3);
      expect(m.spatialRoom, closeTo(0.42, 1e-9));
      expect(m.spatialWidth, closeTo(1.28, 1e-9));
      expect(m.spatialCenter, closeTo(0.64, 1e-9));
      expect(m.sentParamsForTesting.map((e) => e['id']).toList(),
          ['spatial.style']);
    });

    test('setSpatialStyle(2) 应用中性预设，且不再下发三个参数', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.setSpatialStyle(0);
      m.sentParamsForTesting.clear();
      m.setSpatialStyle(2);

      expect(m.spatialStyle, 2);
      expect(m.spatialRoom, 0.0);
      expect(m.spatialWidth, 1.0);
      expect(m.spatialCenter, 0.5);
      // 预设值由引擎 style hook 写入；再发 room/width/center 会触发
      // custom hook 把 style 改回 3。
      expect(m.sentParamsForTesting.map((e) => e['id']).toList(),
          ['spatial.style']);
      expect(m.sentParamsForTesting.single['value'], 2);
    });

    test('手动改 room/width/center 立即下发 style=3 并保留新值', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.setSpatialStyle(2);
      m.sentParamsForTesting.clear();
      m.setSpatialRoom(0.33);

      expect(m.spatialStyle, 3);
      expect(m.spatialRoom, closeTo(0.33, 1e-9));
      expect(m.spatialWidth, 1.0, reason: '改 room 不应动 width');
      expect(m.spatialCenter, 0.5, reason: '改 room 不应动 center');
      expect(m.sentParamsForTesting.map((e) => e['id']).toList(),
          ['spatial.style', 'spatial.room']);
    });

    test('写入预设规范值不误触自定义态', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      m.setSpatialStyle(2);
      m.sentParamsForTesting.clear();

      m.setSpatialRoom(0.0); // 中性预设规范值
      m.setSpatialWidth(1.0);
      m.setSpatialCenter(0.5);

      expect(m.spatialStyle, 2);
      expect(m.sentParamsForTesting, isEmpty,
          reason: '规范值已由 style hook 写入，重复下发会误触 custom hook');
    });

    test('预设应用先写 style，再写规范值：保持预设档', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      final preset = AuraPreset(
        name: '__spatial_neutral__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'spatial': {
            'style': 2,
            'room': 0.0,
            'width': 1.0,
            'center': 0.5,
          },
        },
      );
      PresetLibrary.apply(m, preset, fullRewrite: false);

      expect(m.spatialStyle, 2);
      expect(m.spatialRoom, 0.0);
      expect(m.sentParamsForTesting.where((e) => e['id'] == 'spatial.room'),
          isEmpty);
      expect(m.sentParamsForTesting.where((e) => e['id'] == 'spatial.style')
          .single['value'], 2);
    });

    test('旧会话 style=2 + 自定义值迁移为 style=3，不丢自定义值', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      // 旧版本 UI 把引擎的 3 钳成 2 后保存：style=2 但值不是中性预设。
      final preset = AuraPreset(
        name: '__spatial_legacy_custom__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'spatial': {
            'style': 2,
            'room': 0.42,
            'width': 1.28,
            'center': 0.64,
          },
        },
      );
      PresetLibrary.apply(m, preset, fullRewrite: false);

      expect(m.spatialStyle, 3, reason: '值偏离预设 → 迁移为自定义态');
      expect(m.spatialRoom, closeTo(0.42, 1e-9));
      expect(m.spatialWidth, closeTo(1.28, 1e-9));
      expect(m.spatialCenter, closeTo(0.64, 1e-9));
    });

    test('ParamRegistry.spatialStyle 暴露 4 档（含自定义）', () {
      expect(ParamRegistry.spatialStyle.max, 3);
      expect(ParamRegistry.spatialStyle.options, hasLength(4));
      expect(ParamRegistry.spatialStyle.options!.last, '自定义');
    });
  });
}
