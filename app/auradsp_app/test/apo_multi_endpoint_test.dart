// 第四十一轮（APO 多端点 v2）App 侧契约测试：
// ① 端点 id 的 FNV-1a 哈希与 C++ ApoEndpointProps.h 同算法——
//    向量取 S0 尖刺实测（开发机 Voicemeeter AUX 端点 id 的哈希
//    由原生侧算得 a1c76bcb09ad3503），双侧必须恒等，否则分端点
//    telemetry 块名全部错位。
// ② 第四十二轮 S2：分端点声道覆写已废除——旧 config 的
//    apoEndpointChannels 键加载忽略、保存消失。
// ③ 参数块 v3 布局常量（生成文件）：覆写表偏移 = v2 used bytes
//    （表本体保留休眠，块版本不动）。
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

  group('第四十二轮 S2：覆写配置键已废除', () {
    test('旧 config 的 apoEndpointChannels 加载忽略、保存消失', () {
      final legacy = AppConfig().toJson();
      (legacy['audio'] as Map<String, dynamic>)['apoEndpointChannels'] = {
        'ep-x': {'mode': 1, 'fill': 1},
      };
      final back = AppConfig.fromJson(legacy);
      final audio = back.toJson()['audio'] as Map<String, dynamic>;
      expect(audio.containsKey('apoEndpointChannels'), isFalse);
    });
  });

  group('第四十一轮立项、第四十七轮升 v4、Task 18 升 v6：参数块布局常量', () {
    test('文件效果开关追加尾部，覆写表随 v6 主体后移', () {
      expect(kApoParamBlockVersion, 6);
      expect(kApoNumParamCount, 342);
      expect(kApoNumParamIndex['convolver.enable'], 340);
      expect(kApoNumParamIndex['ddc.enable'], 341);
      expect(kApoNumParamIndex['channels.count'], 335);
      expect(kApoNumParamIndex['viz.fftSize'], 339);
      expect(kApoEpOverrideOffset, 29144);
      expect(kApoEpOverrideCount, 8);
      expect(kApoEpOverrideEntryBytes, 24);
      expect(kApoBlockUsedBytes,
          kApoEpOverrideOffset + kApoEpOverrideCount * kApoEpOverrideEntryBytes);
      expect(kApoBlockUsedBytes, lessThan(kApoBlockMappingBytes));
    });
  });
}
