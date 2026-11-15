/// 桥非计划死亡的自动重启闸门（纯逻辑，音频 isolate 使用）。
///
/// 背景（2026-11-15 vm-win10 无声事件定罪）：桥的原生泵在输出端点
/// 被系统重建（如扬声器配置向导走一遍）后会自判死亡、退出并在
/// status 里报 running=false，但 isolate 的 BridgeManager 仍记着
/// 该桥为当前后端——UI 补发的启动命令被 start 的在跑早退静默吞
/// 掉，链路永久无声只能重启 App。修复口径：状态轮询发现「记账
/// 在跑、桥自报已停」即走正式 stop→start 回收（原生 stop 对泵自
/// 死形态有全拆解路径）；本闸门只负责给自动重启限速——短窗内
/// 反复死亡说明端点真出了问题，停手并留明确状态，不无限打转。
/// 用户显式切模式/热重启视为重新布防（reset）。
class BridgeDeathGate {
  BridgeDeathGate({this.windowMs = 120000, this.maxRestarts = 3});

  /// 死亡计数窗口（毫秒）：窗口外的旧死亡不再计入限速。
  final int windowMs;

  /// 窗口内允许的自动重启次数：第 maxRestarts 次死亡仍可重启，
  /// 其后停手。
  final int maxRestarts;

  final Map<String, List<int>> _deaths = {};

  /// 记录一次非计划死亡，返回本次是否允许自动重启。
  bool recordDeath(String backend, int nowMs) {
    final list = _deaths.putIfAbsent(backend, () => <int>[]);
    list.removeWhere((t) => nowMs - t > windowMs);
    list.add(nowMs);
    return list.length <= maxRestarts;
  }

  /// 显式指令（切模式开/热重启）后清零该后端的死亡计数。
  void reset(String backend) {
    _deaths.remove(backend);
  }

  /// 当前窗口内的死亡次数（日志/诊断用）。
  int deathCount(String backend, int nowMs) {
    final list = _deaths[backend];
    if (list == null) return 0;
    return list.where((t) => nowMs - t <= windowMs).length;
  }
}
