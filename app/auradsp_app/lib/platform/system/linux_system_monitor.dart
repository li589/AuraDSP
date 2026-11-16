// linux_system_monitor.dart — 第四十二轮 S5：Linux 统一系统
// 监听模块（单文件，平台层；契约与事件类型在 port/system_monitor）。
//
// 与 Windows 侧同词汇、同形状：专责感知系统音频面的变化——
// 默认 sink/source 变更、设备集变化（虚拟 sink 出现/消失、采
// 集源切换）、PulseAudio/PipeWire 服务重启。Linux 侧的状态面
// 比 Windows 薄：设备真值由音频 isolate 内的
// LinuxModeController 经 PA 探针维护并以 linuxstatus 事件回
// 推，本模块的探针即状态层字段快照（默认 sink/采集源/虚拟
// sink 在场/采集活跃/驱动在位），分类在其上进行；状态层在
// linuxstatus 事件到达时以 noteExternalSnapshot 同步基线，本
// 模块的节拍则主动催一次 linuxstatus 刷新请求（经 onTick 钩
// 子），使静默期的系统变化也能被数秒内感知。
//
// 服务重启判定（启发式）：快照曾完整（populated）后塌空
// （collapsed）记一次「服务不可达」，其后恢复完整即判服务
// 重启——PA/PipeWire 重启期间探针取不到默认设备，是本通道
// 的可靠信号。格式维度不在快照内（PA 侧格式由流协商，状态
// 面不持有），故 formatChanged 在 Linux 侧不产生。
import 'dart:async';

import '../port/system_monitor.dart';

typedef LinuxSysMonProbe = LinuxAudioSnapshot Function();

class LinuxSystemMonitor implements LinuxSystemMonitorPort {
  LinuxSystemMonitor({
    required this.probe,
    required this.onEvent,
    this.onTick,
    this.interval = const Duration(seconds: 5),
  });

  final LinuxSysMonProbe probe;
  final void Function(SysMonEvent) onEvent;

  /// 每轮回调（状态层据此向 isolate 催一次 linuxstatus 刷新）。
  final void Function()? onTick;

  final Duration interval;

  Timer? _timer;
  LinuxAudioSnapshot? _prev;
  bool _wasDown = false;

  bool get running => _timer != null;

  @override
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => tick());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// isolate linuxstatus 事件已带来新真值时同步基线。
  @override
  void noteExternalSnapshot(LinuxAudioSnapshot snap) {
    _prev = snap;
    if (snap.populated) _wasDown = false;
  }

  /// 两份快照的变化分类（纯函数）：默认 sink 变更 / 设备集
  /// 变化（虚拟 sink 出现消失、采集源切换、采集活跃翻转、
  /// 驱动在位翻转）。
  static List<SysMonEvent> classify(
    LinuxAudioSnapshot prev,
    LinuxAudioSnapshot next,
  ) {
    final events = <SysMonEvent>[];
    if (prev.defaultSink != next.defaultSink) {
      events.add(SysMonEvent(
        SysMonEventKind.defaultDeviceChanged,
        detail: 'defaultSink:${next.defaultSink}',
      ));
    }
    if (prev.virtualSinkPresent != next.virtualSinkPresent ||
        prev.captureSource != next.captureSource ||
        prev.captureActive != next.captureActive ||
        prev.driverLoaded != next.driverLoaded) {
      events.add(SysMonEvent(
        SysMonEventKind.deviceSetChanged,
        detail: 'virtual=${next.virtualSinkPresent} '
            'capture=${next.captureSource} active=${next.captureActive}',
      ));
    }
    return events;
  }

  /// 一轮监听（定时器与测试共用入口）。
  void tick() {
    onTick?.call();
    final snap = probe();
    final prev = _prev;
    if (prev != null && snap != prev) {
      // 塌空→恢复的服务重启判定优先于普通分类。
      if (_wasDown && snap.populated) {
        onEvent(const SysMonEvent(
          SysMonEventKind.audioServiceRestarted,
          detail: 'pulse/pipewire probe recovered',
        ));
        _wasDown = false;
      } else {
        for (final e in classify(prev, snap)) {
          onEvent(e);
        }
      }
    }
    if (snap.populated) _wasDown = false;
    if (prev != null && prev.populated && snap.collapsed) {
      _wasDown = true;
    }
    _prev = snap;
  }
}
