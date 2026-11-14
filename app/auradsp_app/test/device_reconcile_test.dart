// 第三十四轮（2026-11-14）：选择调和 reconcileDeviceSelections——
// 已存设备选择在端点从系统消失后自动改回默认；端点仅被禁用
// （在场键集仍含）必须保留；互斥筛选不得成为误清判据。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/state.dart';

void main() {
  group('reconcileDeviceSelections', () {
    test('输入/输出/VAIO 落点全消失 → 连续两次缺席后三项改回默认', () {
      final m = AppModel(testing: true);
      m.config.pipelineInputDevice = 'gone-in';
      m.config.pipelineOutputDevice = 'gone-out';
      m.config.vaioOutputEndpoint = 'Gone Speakers';
      // 两次确认防抖：第一次缺席只计数，不修。
      m.reconcileDeviceSelections({'other-id', 'Other Name'});
      expect(m.config.pipelineInputDevice, 'gone-in');
      expect(m.config.pipelineOutputDevice, 'gone-out');
      expect(m.config.vaioOutputEndpoint, 'Gone Speakers');
      m.reconcileDeviceSelections({'other-id', 'Other Name'});
      expect(m.config.pipelineInputDevice, '');
      expect(m.config.pipelineOutputDevice, '');
      expect(m.config.vaioOutputEndpoint, '');
    });

    test('瞬态抖动：缺席一次后复现 → 计数清零，永不误清', () {
      final m = AppModel(testing: true);
      m.config.pipelineOutputDevice = 'hda-id';
      m.reconcileDeviceSelections({'other'}); // 缺席 1 次（服务重启瞬间）
      expect(m.config.pipelineOutputDevice, 'hda-id');
      m.reconcileDeviceSelections({'hda-id'}); // 复现 → 清零
      m.reconcileDeviceSelections({'other'}); // 又缺席 1 次（重新计数）
      expect(m.config.pipelineOutputDevice, 'hda-id');
      m.reconcileDeviceSelections({'other'}); // 连续第 2 次 → 修复
      expect(m.config.pipelineOutputDevice, '');
    });

    test('端点仍在场（按 id 或名称）→ 全部保留', () {
      final m = AppModel(testing: true);
      m.config.pipelineInputDevice = 'in-id';
      m.config.pipelineOutputDevice = 'Speakers (Card B)';
      m.config.vaioOutputEndpoint = 'HDA Speakers';
      m.reconcileDeviceSelections(
          {'in-id', 'Speakers (Card B)', 'HDA Speakers'});
      expect(m.config.pipelineInputDevice, 'in-id');
      expect(m.config.pipelineOutputDevice, 'Speakers (Card B)');
      expect(m.config.vaioOutputEndpoint, 'HDA Speakers');
    });

    test('避让不误清：输出就是输入占用的那块卡（互斥撤下中）→ 保留', () {
      // 互斥规格：输入选渲染端点 a 时输出下拉撤下 a；若某时刻
      // 输出存值恰为 a（历史存量），它「不在下拉里」但设备真实
      // 在场——调和的存在性按原始枚举判，绝不能清它。
      final m = AppModel(testing: true);
      m.wasapiDevices = const [
        AudioDeviceItem(id: 'a', name: 'Speakers (Card A)', isRender: true),
        AudioDeviceItem(id: 'b', name: 'Headphones (Card B)', isRender: true),
      ];
      m.config.pipelineInputDevice = 'a';
      m.config.pipelineOutputDevice = 'a';
      expect(m.wasapiOutputsExcludingInput.map((d) => d.id), ['b']);
      m.reconcileDeviceSelections({'a', 'b'});
      expect(m.config.pipelineOutputDevice, 'a');
    });

    test('禁用≠消失：在场键集含而设备表不含（非 ACTIVE）→ 保留', () {
      final m = AppModel(testing: true);
      m.wasapiDevices = const []; // ACTIVE 表为空（设备被禁用）
      m.config.pipelineOutputDevice = 'disabled-id';
      m.reconcileDeviceSelections({'disabled-id'});
      expect(m.config.pipelineOutputDevice, 'disabled-id');
    });

    test('在场键集为空（扫描异常）→ 不调和，防误清全场', () {
      final m = AppModel(testing: true);
      m.config.pipelineInputDevice = 'x';
      m.config.pipelineOutputDevice = 'y';
      m.config.vaioOutputEndpoint = 'Z';
      m.reconcileDeviceSelections({});
      expect(m.config.pipelineInputDevice, 'x');
      expect(m.config.pipelineOutputDevice, 'y');
      expect(m.config.vaioOutputEndpoint, 'Z');
    });

    test('捕获腿在跑且输入消失 → 两次确认后停腿并清输入选择', () {
      final m = AppModel(testing: true);
      m.config.pipelineInputDevice = 'gone-in';
      m.captureActive = true;
      m.reconcileDeviceSelections({'something-else'});
      expect(m.config.pipelineInputDevice, 'gone-in');
      expect(m.captureActive, isTrue);
      m.reconcileDeviceSelections({'something-else'});
      expect(m.config.pipelineInputDevice, '');
      expect(m.captureActive, isFalse);
    });

    test('本来就空（默认）的选择不被触碰', () {
      final m = AppModel(testing: true);
      m.config.pipelineInputDevice = '';
      m.config.pipelineOutputDevice = '';
      m.config.vaioOutputEndpoint = '';
      m.reconcileDeviceSelections({'a'});
      expect(m.config.pipelineInputDevice, '');
      expect(m.config.pipelineOutputDevice, '');
      expect(m.config.vaioOutputEndpoint, '');
    });
  });
}
