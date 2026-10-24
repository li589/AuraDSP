/*
 * backend_switch.dart — 后端互斥切换的失败语义（D4-a）。
 *
 * 背景：进程内有四路输出后端（WASAPI / VB / ASIO / VAIO），任一时刻只允许
 * **一路**在出声。"切换"分两步：停旧 → 起新。
 *
 * 原实现把第一步写成
 *     try { wasapi?.stop(); } catch (_) {}
 * 就继续往前走。于是「停不下来」和「停下来了」在控制流上完全等价：
 *   · 旧后端还在跑 + 新后端已起来 → 两路同时出声（真实双声/梳状），
 *     用户听到的是"切换后有回声"，日志里一个字都没有；
 *   · `WasapiOut.stop()` 自身还把 `IAudioClient::Stop` 的 HRESULT 丢掉、
 *     无条件把 `started` 清零，于是失败后连"其实还在跑"这个事实都没留下。
 *
 * 本文件只负责**决定**，不碰 FFI：
 *   停旧成功 → 允许起新；
 *   停旧失败 → 把已经起来的新后端拆掉（回到切换前的状态），并带出原因。
 * 宁可切换失败（旧后端继续正常出声 + UI 有提示），也不要静默双开。
 */

/// 一次交接的结果。[ok] 为真表示「旧后端已确认静音，可以起新后端」。
class HandoverResult {
  const HandoverResult._(this.ok, this.reason);

  const HandoverResult.ok() : this._(true, '');

  const HandoverResult.failed(String reason) : this._(false, reason);

  final bool ok;

  /// `ok == false` 时的原因（写进对应 *status 事件的 note，UI 可见）。
  final String reason;

  @override
  String toString() => ok ? 'HandoverResult.ok' : 'HandoverResult.failed($reason)';
}

/// 执行「停旧后端」这一步，并按结果决定是否回滚。
///
/// [haltOld]     停旧后端；停不下来就抛（**不要**在里面 catch 掉）。
/// [rollbackNew] 失败时拆掉刚起的新后端（它已经在出声了），回到切换前状态。
///   自身失败不改变返回值（原因已记进 [onError]），因为此时已经在错误路径上。
/// [onError]     记录诊断串（隔离区里传 dbgLog）。
HandoverResult runHandover({
  required void Function() haltOld,
  required void Function() rollbackNew,
  void Function(String message)? onError,
}) {
  try {
    haltOld();
    return const HandoverResult.ok();
  } catch (e) {
    onError?.call('handover: halt-old failed: $e');
    try {
      rollbackNew();
    } catch (e2) {
      onError?.call('handover: rollback-new failed: $e2');
    }
    return HandoverResult.failed('$e');
  }
}
