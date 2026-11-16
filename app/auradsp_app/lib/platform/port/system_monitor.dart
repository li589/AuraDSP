// system_monitor.dart — 统一系统监听端口（第四十二轮 S5）。
//
// 事件词汇与快照类型在此（契约层），实现位于
// platform/system/windows_system_monitor.dart 与
// linux_system_monitor.dart；core 只依赖本端口与工厂，
// 不直连具体实现（F11 隔离门禁）。
import '../system/linux_system_monitor.dart';
import '../system/windows_system_monitor.dart';

/// 系统监听事件类别（Win/Linux 同词汇）。
enum SysMonEventKind {
  /// 设备集变化：端点出现/消失（插拔、驱动重载、虚拟设备增减）。
  deviceSetChanged,

  /// 默认设备变化（默认渲染/捕获端点、Linux 默认 sink/source）。
  defaultDeviceChanged,

  /// 既有设备格式变化（采样率/声道数/位深——系统里改声道模式
  /// 走此路）。Linux 快照不含格式面，此类仅 Windows 产生。
  formatChanged,

  /// 音频服务重启（Windows Audio 服务 / PipeWire·PulseAudio）：
  /// 探针连续失败后恢复（Win）或快照塌空后恢复（Linux）的
  /// 启发式判定——端点与 APO 拓扑都可能已被重建，消费方应
  /// 做全量状态复核。
  audioServiceRestarted,

  /// APO 附加拓扑变化：已附加端点集与基线不一致（本 App 之
  /// 外的附加/分离或状态漂移）。仅 Windows 产生。
  apoTopologyChanged,
}

/// 一条系统监听事件。
class SysMonEvent {
  const SysMonEvent(this.kind,
      {this.endpointIds = const {}, this.scan, this.detail = ''});

  final SysMonEventKind kind;

  /// 相关端点 id 集（设备集/格式/APO 拓扑事件携带；可空）。
  final Set<String> endpointIds;

  /// 触发本事件的那轮端点扫描（Windows 设备类事件携带，
  /// 消费方直接应用免重扫；Linux 事件恒为空）。
  final Map<String, dynamic>? scan;

  /// 人读说明（日志用）。
  final String detail;

  @override
  String toString() => 'SysMonEvent(${kind.name} $detail)';
}

/// Linux 音频面快照（监听探针的采样值；字段即状态层既有
/// linux* 状态的真值面）。
class LinuxAudioSnapshot {
  const LinuxAudioSnapshot({
    this.defaultSink = '',
    this.captureSource = '',
    this.virtualSinkPresent = false,
    this.captureActive = false,
    this.driverLoaded = false,
  });

  final String defaultSink;
  final String captureSource;
  final bool virtualSinkPresent;
  final bool captureActive;
  final bool driverLoaded;

  /// 有内容（PA/PipeWire 可达的常态）。
  bool get populated =>
      defaultSink.isNotEmpty || virtualSinkPresent || driverLoaded;

  /// 塌空（守护进程不可达/重启中的形态）。
  bool get collapsed => !populated;

  @override
  bool operator ==(Object other) =>
      other is LinuxAudioSnapshot &&
      other.defaultSink == defaultSink &&
      other.captureSource == captureSource &&
      other.virtualSinkPresent == virtualSinkPresent &&
      other.captureActive == captureActive &&
      other.driverLoaded == driverLoaded;

  @override
  int get hashCode => Object.hash(defaultSink, captureSource,
      virtualSinkPresent, captureActive, driverLoaded);
}

/// Windows 监听扫描探针：一轮 apo_inspect 扫描结果 JSON；
/// null = 本轮失败（枚举工具缺失/非零退出/解析失败/服务不可达）。
typedef SysMonScanProbe = Future<Map<String, dynamic>?> Function();

/// Windows APO 拓扑探针：当前已附加端点 id 集（轻量读）；
/// null = 本轮不适用/失败（跳过拓扑比对）。
typedef SysMonApoProbe = Future<Set<String>?> Function();

/// Windows 统一系统监听端口。
abstract interface class WindowsSystemMonitorPort {
  void start();
  void stop();

  /// 外部路径（手动刷新等）已应用一轮扫描时同步基线，
  /// 避免监听下一轮把同一变化重复上报。
  void noteExternalScan(Map<String, dynamic> json);
}

/// Linux 统一系统监听端口。
abstract interface class LinuxSystemMonitorPort {
  void start();
  void stop();

  /// 外部路径已回填新真值时同步基线。
  void noteExternalSnapshot(LinuxAudioSnapshot snap);
}

/// Windows 监听实现装配（参数语义见实现类）。
WindowsSystemMonitorPort createWindowsSystemMonitor({
  required SysMonScanProbe scanProbe,
  required void Function(SysMonEvent) onEvent,
  SysMonApoProbe? apoProbe,
  void Function(Map<String, dynamic> scan)? onTick,
  bool Function()? gate,
  Duration interval = const Duration(seconds: 4),
  int apoEveryTicks = 3,
}) =>
    WindowsSystemMonitor(
      scanProbe: scanProbe,
      onEvent: onEvent,
      apoProbe: apoProbe,
      onTick: onTick,
      gate: gate,
      interval: interval,
      apoEveryTicks: apoEveryTicks,
    );

/// Linux 监听实现装配（参数语义见实现类）。
LinuxSystemMonitorPort createLinuxSystemMonitor({
  required LinuxAudioSnapshot Function() probe,
  required void Function(SysMonEvent) onEvent,
  void Function()? onTick,
  Duration interval = const Duration(seconds: 5),
}) =>
    LinuxSystemMonitor(
      probe: probe,
      onEvent: onEvent,
      onTick: onTick,
      interval: interval,
    );
