// system_monitor_test.dart — 第四十二轮 S5：统一系统监听模块
// （Windows/Linux 各一单文件）的纯分类与节拍行为。签名/分类自
// 状态层旧签名看守迁入后口径不变；新增服务重启（失败→恢复）
// 与 APO 拓扑（附加集差分）两类事件在此钉契约。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/platform/system/linux_system_monitor.dart'
    as linux_mon;
import 'package:auradsp_app/platform/system/windows_system_monitor.dart';

Map<String, dynamic> _scan({
  String defR = 'ep-a',
  String defC = 'mic-a',
  List<Map<String, dynamic>> eps = const [],
}) =>
    {
      'defaultRender': defR,
      'defaultCapture': defC,
      'endpoints': eps,
    };

Map<String, dynamic> _ep(String id, {int rate = 48000, int ch = 2, int bits = 16, int state = 1}) =>
    {'id': id, 'rate': rate, 'ch': ch, 'bits': bits, 'state': state};

void main() {
  group('WindowsSystemMonitor 签名与分类', () {
    test('签名：改名不敏感、改格式敏感', () {
      final a = _scan(eps: [_ep('ep-a')]);
      final renamed = _scan(eps: [
        {..._ep('ep-a'), 'name': '别的名'},
      ]);
      expect(WindowsSystemMonitor.signatureOf(a),
          WindowsSystemMonitor.signatureOf(renamed));
      final reformatted = _scan(eps: [_ep('ep-a', ch: 8)]);
      expect(WindowsSystemMonitor.signatureOf(a),
          isNot(WindowsSystemMonitor.signatureOf(reformatted)));
    });

    test('classify：默认变更', () {
      final evts = WindowsSystemMonitor.classify(
          _scan(eps: [_ep('ep-a')]), _scan(defR: 'ep-b', eps: [_ep('ep-a')]));
      expect(evts.map((e) => e.kind),
          contains(SysMonEventKind.defaultDeviceChanged));
    });

    test('classify：集合增减带端点集', () {
      final evts = WindowsSystemMonitor.classify(
        _scan(eps: [_ep('ep-a'), _ep('ep-b')]),
        _scan(eps: [_ep('ep-a'), _ep('ep-c')]),
      );
      final setEvt =
          evts.singleWhere((e) => e.kind == SysMonEventKind.deviceSetChanged);
      expect(setEvt.endpointIds, {'ep-b', 'ep-c'});
    });

    test('classify：格式变更只报格式事件', () {
      final evts = WindowsSystemMonitor.classify(
        _scan(eps: [_ep('ep-a', ch: 2)]),
        _scan(eps: [_ep('ep-a', ch: 8)]),
      );
      expect(evts.length, 1);
      expect(evts.single.kind, SysMonEventKind.formatChanged);
      expect(evts.single.endpointIds, {'ep-a'});
    });

    test('classify：无变化为空', () {
      expect(
          WindowsSystemMonitor.classify(
              _scan(eps: [_ep('ep-a')]), _scan(eps: [_ep('ep-a')])),
          isEmpty);
    });
  });

  group('WindowsSystemMonitor 节拍行为', () {
    test('失败→恢复判音频服务重启', () async {
      final got = <SysMonEvent>[];
      var fail = true;
      final mon = WindowsSystemMonitor(
        scanProbe: () async => fail ? null : _scan(eps: [_ep('ep-a')]),
        onEvent: got.add,
      );
      await mon.tick(); // 失败
      expect(got, isEmpty);
      fail = false;
      await mon.tick(); // 恢复
      expect(got.map((e) => e.kind),
          contains(SysMonEventKind.audioServiceRestarted));
    });

    test('APO 附加集差分判拓扑变化（首轮只立基线）', () async {
      final got = <SysMonEvent>[];
      var attached = {'ep-a'};
      final mon = WindowsSystemMonitor(
        scanProbe: () async => _scan(eps: [_ep('ep-a')]),
        apoProbe: () async => attached,
        apoEveryTicks: 1,
        onEvent: got.add,
      );
      await mon.tick();
      expect(got, isEmpty);
      attached = {'ep-a', 'ep-b'};
      await mon.tick();
      expect(got.map((e) => e.kind),
          contains(SysMonEventKind.apoTopologyChanged));
    });

    test('gate 关闭时整轮跳过且不计失败', () async {
      final got = <SysMonEvent>[];
      var gateOpen = false;
      var probeCalls = 0;
      final mon = WindowsSystemMonitor(
        scanProbe: () async {
          probeCalls++;
          return _scan(eps: [_ep('ep-a')]);
        },
        gate: () => gateOpen,
        onEvent: got.add,
      );
      await mon.tick();
      expect(probeCalls, 0);
      gateOpen = true;
      await mon.tick();
      expect(probeCalls, 1);
      // gate 跳过不算失败：首轮成功不带服务重启事件。
      expect(got.map((e) => e.kind),
          isNot(contains(SysMonEventKind.audioServiceRestarted)));
    });

    test('noteExternalScan 同步基线不重复上报', () async {
      final got = <SysMonEvent>[];
      final mon = WindowsSystemMonitor(
        scanProbe: () async => _scan(eps: [_ep('ep-a', ch: 8)]),
        onEvent: got.add,
      );
      mon.noteExternalScan(_scan(eps: [_ep('ep-a', ch: 8)]));
      await mon.tick();
      expect(got, isEmpty);
    });
  });

  group('LinuxSystemMonitor 分类与服务重启', () {
    const base = linux_mon.LinuxAudioSnapshot(
      defaultSink: 'sink-a',
      captureSource: 'src-a',
      captureActive: true,
      driverLoaded: true,
    );

    test('classify：默认 sink 变更', () {
      final evts = linux_mon.LinuxSystemMonitor.classify(
        base,
        const linux_mon.LinuxAudioSnapshot(
          defaultSink: 'sink-b',
          captureSource: 'src-a',
          captureActive: true,
          driverLoaded: true,
        ),
      );
      expect(evts.map((e) => e.kind),
          contains(linux_mon.SysMonEventKind.defaultDeviceChanged));
    });

    test('classify：虚拟 sink 出现判设备集变化', () {
      final evts = linux_mon.LinuxSystemMonitor.classify(
        base,
        const linux_mon.LinuxAudioSnapshot(
          defaultSink: 'sink-a',
          captureSource: 'src-a',
          virtualSinkPresent: true,
          captureActive: true,
          driverLoaded: true,
        ),
      );
      expect(evts.map((e) => e.kind),
          contains(linux_mon.SysMonEventKind.deviceSetChanged));
    });

    test('塌空→恢复判服务重启', () {
      final got = <linux_mon.SysMonEvent>[];
      var snap = base;
      final mon = linux_mon.LinuxSystemMonitor(
        probe: () => snap,
        onEvent: got.add,
      );
      mon.tick(); // 基线
      snap = const linux_mon.LinuxAudioSnapshot(); // 塌空
      mon.tick();
      snap = base; // 恢复
      mon.tick();
      expect(got.map((e) => e.kind),
          contains(linux_mon.SysMonEventKind.audioServiceRestarted));
    });
  });
}
