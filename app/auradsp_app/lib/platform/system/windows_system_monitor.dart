// windows_system_monitor.dart — 第四十二轮 S5：Windows 统一系统
// 监听模块（单文件，平台层）。
//
// 专责感知系统音频面的变化：硬件插拔/启停、默认设备变更、端点
// mix 格式变更（率/声道/位深）、音频服务重启、其它 APO 的附加
// 与分离。此前这些感知散在状态层的 4 秒签名看守（state 内嵌
// Timer + 签名比对）与 checkApoStatus 的按需轮询里，触发点与
// 口径各行其是；现收敛于此：
//   · 节拍、签名、变化分类、失败恢复判定都在本文件；
//   · 状态层只提供两个探针闭包（端点扫描、APO 附加集轻量读）
//     与一个事件处理器（应用扫描/对账/回退钳制在状态层）；
//   · S1 的 chcap 与 S3 的显示合成以本模块事件为触发源（经
//     状态层 _applyDeviceScan / checkApoStatus 的既有尾巴）。
//
// 探针口径：端点扫描 = apo_inspect 一次性扫描 JSON（与状态层
// _applyDeviceScan 的输入同形）；扫描失败（工具非零退出/服务
// 不可用）由探针以 null 表示——连续失败后恢复即判音频服务
// 重启（audiosrv 重启期间 MMDevice 枚举失败，是本通道唯一可
// 靠信号，属启发式，事件 detail 注明）。
import 'dart:async';

/// 系统音频事件种类（与 Linux 侧同词汇，见 linux_system_monitor）。
enum SysMonEventKind {
  /// 端点集合变化（插拔/启停）：endpointIds 为增减的端点集。
  deviceSetChanged,

  /// 默认渲染/采集端点变化。
  defaultDeviceChanged,

  /// 既有端点 mix 格式变化：endpointIds 为格式变了的端点集。
  formatChanged,

  /// 音频服务重启（扫描失败后恢复，启发式）。
  audioServiceRestarted,

  /// APO 附加拓扑变化（本 App 之外的附加/分离，或状态漂移）。
  apoTopologyChanged,
}

class SysMonEvent {
  final SysMonEventKind kind;
  final Set<String> endpointIds;
  final Map<String, dynamic>? scan;
  final String detail;
  const SysMonEvent(
    this.kind, {
    this.endpointIds = const {},
    this.scan,
    this.detail = '',
  });

  @override
  String toString() =>
      'SysMonEvent($kind, ids=${endpointIds.length}, $detail)';
}

/// 端点扫描探针：成功返回 apo_inspect JSON，失败返回 null。
typedef SysMonScanProbe = Future<Map<String, dynamic>?> Function();

/// APO 附加集探针：返回当前已附加端点 id 集；不适用/失败 null。
typedef SysMonApoProbe = Future<Set<String>?> Function();

class WindowsSystemMonitor {
  WindowsSystemMonitor({
    required this.scanProbe,
    required this.onEvent,
    this.apoProbe,
    this.onTick,
    this.gate,
    this.interval = const Duration(seconds: 4),
    this.apoEveryTicks = 3,
  });

  final SysMonScanProbe scanProbe;
  final void Function(SysMonEvent) onEvent;

  /// 轮次门（可空）：返回 false 时本轮静默跳过（不计失败）——
  /// 状态层在手动刷新在飞/分离阻塞期间据此让行，避免把「让
  /// 行」误判成扫描失败、进而误报服务重启。
  final bool Function()? gate;

  /// APO 附加集探针（可空：未提供则不监听 APO 拓扑）。
  final SysMonApoProbe? apoProbe;

  /// 每轮成功扫描后回调（含无变化轮次）：状态层据此推进
  /// 「缺席待确认」类需要持续复核的调和，不必等变化事件。
  final void Function(Map<String, dynamic> scan)? onTick;

  final Duration interval;

  /// APO 探针的节拍除数（apo_config 状态读比 inspect 重，降频）。
  final int apoEveryTicks;

  Timer? _timer;
  bool _busy = false;
  int _tickCount = 0;
  int _consecutiveFailures = 0;
  Map<String, dynamic>? _prevScan;
  Set<String>? _apoIds;

  bool get running => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 外部（如手动刷新）已应用一轮扫描时同步基线，避免下一轮
  /// 把同一变化重复分类上报。
  void noteExternalScan(Map<String, dynamic> scan) {
    _prevScan = scan;
  }

  /// 设备签名：默认端点身份 + 全部 ACTIVE 端点的 id 与 mix
  /// format（率/声道/位深）。系统里改默认、插拔、改声道数/采
  /// 样率/位深都会改变签名；纯粹改名不纳入（名称是显示面，
  /// 不是可用性面）。自状态层旧 _deviceSignatureOf 原样迁入。
  static String signatureOf(Map<String, dynamic> json) {
    final eps = (json['endpoints'] as List?) ?? const [];
    final rows = <String>[];
    for (final ep in eps) {
      if (ep is Map) {
        final state = (ep['state'] as num?)?.toInt() ?? 1;
        if (state != 1) continue;
        rows.add('${ep['id']}|${ep['rate'] ?? 0}|${ep['ch'] ?? 0}'
            '|${ep['bits'] ?? 0}');
      }
    }
    rows.sort();
    return <String>[
      (json['defaultRender'] as String?) ?? '',
      (json['defaultCapture'] as String?) ?? '',
      ...rows,
    ].join('\n');
  }

  static Map<String, Map<String, dynamic>> _activeById(
      Map<String, dynamic> json) {
    final out = <String, Map<String, dynamic>>{};
    final eps = (json['endpoints'] as List?) ?? const [];
    for (final ep in eps) {
      if (ep is Map) {
        final state = (ep['state'] as num?)?.toInt() ?? 1;
        if (state != 1) continue;
        final id = (ep['id'] as String?) ?? '';
        if (id.isNotEmpty) {
          out[id] = Map<String, dynamic>.from(ep);
        }
      }
    }
    return out;
  }

  /// 两轮扫描的变化分类（纯函数）：默认变更 / 集合增减 / 格式
  /// 变更，可同时成立多件，按 默认→集合→格式 顺序返回。
  static List<SysMonEvent> classify(
    Map<String, dynamic> prev,
    Map<String, dynamic> next,
  ) {
    final events = <SysMonEvent>[];
    final prevDefR = (prev['defaultRender'] as String?) ?? '';
    final nextDefR = (next['defaultRender'] as String?) ?? '';
    final prevDefC = (prev['defaultCapture'] as String?) ?? '';
    final nextDefC = (next['defaultCapture'] as String?) ?? '';
    if (prevDefR != nextDefR || prevDefC != nextDefC) {
      events.add(SysMonEvent(
        SysMonEventKind.defaultDeviceChanged,
        scan: next,
        detail: 'render:$nextDefR capture:$nextDefC',
      ));
    }
    final prevById = _activeById(prev);
    final nextById = _activeById(next);
    final added = nextById.keys.toSet().difference(prevById.keys.toSet());
    final removed = prevById.keys.toSet().difference(nextById.keys.toSet());
    if (added.isNotEmpty || removed.isNotEmpty) {
      events.add(SysMonEvent(
        SysMonEventKind.deviceSetChanged,
        endpointIds: {...added, ...removed},
        scan: next,
        detail: 'added=${added.length} removed=${removed.length}',
      ));
    }
    final formatIds = <String>{};
    for (final id in prevById.keys.where(nextById.containsKey)) {
      final a = prevById[id]!;
      final b = nextById[id]!;
      if ((a['rate'] ?? 0) != (b['rate'] ?? 0) ||
          (a['ch'] ?? 0) != (b['ch'] ?? 0) ||
          (a['bits'] ?? 0) != (b['bits'] ?? 0)) {
        formatIds.add(id);
      }
    }
    if (formatIds.isNotEmpty) {
      events.add(SysMonEvent(
        SysMonEventKind.formatChanged,
        endpointIds: formatIds,
        scan: next,
        detail: 'format of ${formatIds.length} endpoint(s)',
      ));
    }
    return events;
  }

  /// 一轮监听（定时器与测试共用入口；在飞合并）。
  Future<void> tick() async {
    if (_busy) return;
    if (gate != null && !gate!()) return;
    _busy = true;
    try {
      Map<String, dynamic>? scan;
      try {
        scan = await scanProbe();
      } catch (_) {
        scan = null;
      }
      if (scan == null) {
        _consecutiveFailures++;
        return;
      }
      if (_consecutiveFailures > 0) {
        onEvent(SysMonEvent(
          SysMonEventKind.audioServiceRestarted,
          scan: scan,
          detail:
              'scan recovered after $_consecutiveFailures failed probe(s)',
        ));
        _consecutiveFailures = 0;
      }
      final prev = _prevScan;
      if (prev != null && signatureOf(prev) != signatureOf(scan)) {
        for (final e in classify(prev, scan)) {
          onEvent(e);
        }
      }
      _prevScan = scan;
      onTick?.call(scan);
      _tickCount++;
      final probe = apoProbe;
      if (probe != null && apoEveryTicks > 0 && _tickCount % apoEveryTicks == 0) {
        Set<String>? ids;
        try {
          ids = await probe();
        } catch (_) {
          ids = null;
        }
        if (ids != null) {
          final old = _apoIds;
          if (old != null &&
              (old.length != ids.length || !old.containsAll(ids))) {
            onEvent(SysMonEvent(
              SysMonEventKind.apoTopologyChanged,
              endpointIds: {
                ...ids.difference(old),
                ...old.difference(ids),
              },
              detail:
                  'added=${ids.difference(old).length} removed=${old.difference(ids).length}',
            ));
          }
          _apoIds = ids;
        }
      }
    } finally {
      _busy = false;
    }
  }
}
