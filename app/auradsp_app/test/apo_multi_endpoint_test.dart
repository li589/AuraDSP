// 第四十一轮（APO 多端点 v2）App 侧契约测试：
// ① 端点 id 的 FNV-1a 哈希与 C++ ApoEndpointProps.h 同算法——
//    向量取 S0 尖刺实测（开发机 Voicemeeter AUX 端点 id 的哈希
//    由原生侧算得 a1c76bcb09ad3503），双侧必须恒等，否则分端点
//    telemetry 块名与参数块 v3 覆写表键全部错位。
// ② 分端点声道覆写配置的容错解码（形状不对跳过、值钳 {0,1}）。
// ③ 参数块 v3 布局常量（生成文件）：覆写表偏移 = v2 used bytes。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/engine/apo_param_index.dart';
import 'package:auradsp_app/engine/audio_isolate.dart';

void main() {
  group('第四十一轮：端点哈希与分块名（与原生同算法）', () {
    const vbId = '{0.0.0.00000000}.{4de6de64-cb29-4d51-8fc0-26e25654314d}';
    test('FNV-1a 向量（S0 尖刺原生实测值）', () {
      expect(apoEndpointHash(vbId), 0xa1c76bcb09ad3503);
    });
    test('分块名 = Global 前缀 + 小写 16 位哈希', () {
      expect(apoTelemetryNameFor(vbId),
          'Global\\AuraDSP_ApoTelemetry_a1c76bcb09ad3503');
    });
    test('不同端点哈希不同（基本健全性）', () {
      expect(apoEndpointHash('{0.0.0.00000000}.{3e07aa9a-3203-41a9-8d18-aa5a413c228d}'),
          isNot(apoEndpointHash(vbId)));
    });
  });

  group('第四十一轮：分端点声道覆写配置解码', () {
    test('正常条目原样解码', () {
      final m = AppConfig.parseEndpointChannels({
        'ep-a': {'mode': 1, 'fill': 0},
        'ep-b': {'mode': 0, 'fill': 1},
      });
      expect(m.length, 2);
      expect(m['ep-a'], (mode: 1, fill: 0));
      expect(m['ep-b'], (mode: 0, fill: 1));
    });
    test('坏形状跳过、越界值钳制', () {
      final m = AppConfig.parseEndpointChannels({
        'ok': {'mode': 7, 'fill': -2},
        'junk1': 'x',
        'junk2': {'mode': 'a'},
        42: {'mode': 1, 'fill': 1},
      });
      expect(m.keys, ['ok']);
      expect(m['ok'], (mode: 1, fill: 0));
    });
    test('非 Map 输入回空表', () {
      expect(AppConfig.parseEndpointChannels(null), isEmpty);
      expect(AppConfig.parseEndpointChannels('nope'), isEmpty);
    });
    test('config 往返：toJson → fromJson 不丢覆写', () {
      final c = AppConfig();
      c.apoEndpointChannels['ep-x'] = (mode: 1, fill: 1);
      final back = AppConfig.fromJson(c.toJson());
      expect(back.apoEndpointChannels['ep-x'], (mode: 1, fill: 1));
    });
  });

  group('第四十一轮：参数块 v3 布局常量', () {
    test('覆写表紧贴 v2 主体尾部，块版本为 3', () {
      expect(kApoParamBlockVersion, 3);
      expect(kApoEpOverrideOffset, 27084);
      expect(kApoEpOverrideCount, 8);
      expect(kApoEpOverrideEntryBytes, 24);
      expect(kApoBlockUsedBytes,
          kApoEpOverrideOffset + kApoEpOverrideCount * kApoEpOverrideEntryBytes);
      expect(kApoBlockUsedBytes, lessThan(kApoBlockMappingBytes));
    });
  });
}
