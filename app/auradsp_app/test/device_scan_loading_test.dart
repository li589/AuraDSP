// device_scan_loading_test.dart — 第四十二轮 S4：设备枚举
// 加载态 + APO 端点列表限高滚动。枚举走 isolate 消息不阻塞
// UI；加载态旗标驱动面板在首轮枚举未回时呈加载行（不误报
// 「无可用端点」），列表本体由 _ApoEndpointList 限高滚动。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/state.dart';

void main() {
  group('第四十二轮 S4：设备枚举加载态', () {
    test('新模型未发起枚举（面板呈空文案，加载只认在途旗）', () {
      final m = AppModel(testing: true);
      expect(m.deviceScanDone, isFalse);
      expect(m.deviceScanInFlight, isFalse);
      // 面板判据（收口复验修正）：只认在途旗 → 未发起过枚举
      // 时不呈加载行（无 isolate 环境里动画永转会挂死设置页
      // 测试的 pump；生产中枚举恒由就绪流发起）。
      expect(m.deviceScanInFlight, isFalse);
    });

    test('refreshVaioDetect 置在途旗（测试模式不设看守表）', () {
      final m = AppModel(testing: true);
      m.refreshVaioDetect();
      expect(m.deviceScanInFlight, isTrue);
      expect(m.deviceScanDone, isFalse);
    });

    test('面板源码契约：限高滚动列表 + 加载判据在位', () {
      final src = File(
              'lib/features/settings/panels/sections.dart')
          .readAsStringSync();
      expect(src.contains('class _ApoEndpointList'), isTrue);
      expect(src.contains('BoxConstraints(maxHeight: 164)'), isTrue);
      expect(src.contains('model.deviceScanInFlight'), isTrue);
      final stateSrc =
          File('lib/core/state/state_events.dart').readAsStringSync();
      expect(stateSrc.contains('deviceScanInFlight = false'), isTrue);
      expect(stateSrc.contains('deviceScanDone = true'), isTrue);
    });
  });
}
