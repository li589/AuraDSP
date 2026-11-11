// round7_device_guard_test.dart — 第七轮 S2（项 3/4/5）设备面契约。
//
// 定罪背景：① 反馈守卫只符号比较 ''，输入选「系统默认[环回]」+
// 输出选默认端点的具名项时自激对漏网（项 3）；② 输入 VAIO 时
// WASAPI 输出设备字段不被链路消费、UI 却照常可改且无提示（项 4）；
// ③ 输入/输出开关从未接线分发器、纯装饰（项 5）。本组契约钉住：
// 默认别名解析后的守卫纯函数口径 + 各处接线形态。
import 'dart:io';

import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String relPath) {
  for (final base in const ['', '../', '../../']) {
    final f = File('$base$relPath');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $relPath（cwd=${Directory.current.path}）');
}

/// 取函数体窗口（定长夹紧，防花括号切分与窗口越界两坑）。
String _window(String src, String marker, [int len = 700]) {
  final start = src.indexOf(marker);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $marker');
  final end = (start + len > src.length) ? src.length : start + len;
  return src.substring(start, end);
}

void main() {
  group('idsConflictResolved：默认别名解析后的自激判定', () {
    const def = '{default-render-id}';
    const spk = '{speaker-id}';
    const other = '{other-id}';
    const mic = '{mic-id}';

    test('双默认恒冲突（默认身份已知/未知都拦）', () {
      expect(idsConflictResolved('', '', def), isTrue);
      expect(idsConflictResolved('', '', ''), isTrue);
    });

    test('项 3 本体：默认回录 vs 默认端点的具名输出 = 冲突', () {
      expect(idsConflictResolved('', def, def), isTrue);
      // 对称形态：具名回录默认端点 vs 默认输出。
      expect(idsConflictResolved(def, '', def), isTrue);
    });

    test('默认回录 vs 另一块声卡的具名输出 = 不冲突', () {
      expect(idsConflictResolved('', other, def), isFalse);
    });

    test('话筒直采 vs 默认输出 = 不冲突', () {
      expect(idsConflictResolved(mic, '', def), isFalse);
    });

    test('同名端点对恒冲突、异名恒放行（旧口径不回归）', () {
      expect(idsConflictResolved(spk, spk, def), isTrue);
      expect(idsConflictResolved(spk, other, def), isFalse);
    });

    test('默认身份未知时单侧默认不误拦具名输出', () {
      expect(idsConflictResolved('', spk, ''), isFalse);
      expect(idsConflictResolved(spk, '', ''), isFalse);
    });
  });

  group('源码契约', () {
    final modes = _read('app/auradsp_app/lib/core/state/state_audio_modes.dart');
    final state = _read('app/auradsp_app/lib/core/state.dart');
    final events = _read('app/auradsp_app/lib/core/state/state_events.dart');
    final panel = _read(
        'app/auradsp_app/lib/features/settings/panels/hardware_io_output.dart');

    test('默认端点身份被解析保存（地基）', () {
      expect(modes.contains("json['defaultRender']"), isTrue);
      expect(modes.contains("json['defaultCapture']"), isTrue);
      expect(state.contains('String defaultRenderId'), isTrue);
    });

    test('守卫委托解析口径、下拉互斥撤默认具名别名', () {
      expect(modes.contains('idsConflictResolved(capId, outId, defaultRenderId)'),
          isTrue);
      expect(state.contains('d.id != defaultRenderId'), isTrue);
    });

    test('开关接线分发器且总闸压过分发器/模式直发/就绪恢复', () {
      expect(_window(modes, 'void setPipelineInputEnabled'),
          contains('applyPipelineChain();'));
      expect(_window(modes, 'void setPipelineOutputEnabled'),
          contains('applyPipelineChain();'));
      expect(modes.contains('_pipelineIoSuppressed'), isTrue);
      expect(_window(modes, 'void applyPipelineChain()', 500),
          contains('_pipelineIoSuppressed'));
      expect(events.contains('!_pipelineIoSuppressed'), isTrue);
    });

    test('刷新后重估在跑捕获链的自激面（只停不起）', () {
      expect(
          modes.contains('stopped after refresh (feedback pair)'), isTrue);
    });

    test('输出面板被桥吸收呈现 + 极端文案区分', () {
      expect(panel.contains('overriddenByBridge'), isTrue);
      expect(panel.contains('ioOutputOverriddenByVaio'), isTrue);
      expect(panel.contains('ioOutputOverriddenByAsio'), isTrue);
      expect(panel.contains('ioOnlyVirtualOutputs'), isTrue);
      expect(panel.contains('overriddenByAsio'), isTrue);
    });
  });
}
