// part of audio_isolate.dart —— P1 按区拆分，纯搬运零改行。
part of 'audio_isolate.dart';
/// C2：分块扫描（异步，由 'pluginScan' 命令 fire-and-forget 启动）。
///
/// 为什么不用一次性 `pluginScan`：那是一记长阻塞 FFI——快扫 ~120ms（76 个）
/// 尚可，深扫要 LoadLibrary 每个 DLL（实测 3.6s），期间本 isolate 完全无法
/// 让出，音频泵停摆、进度无从上报。切成小步后每步只处理少量候选，步间
/// await 让出事件循环：音频继续跑、进度实时回传、列表边扫边长。
///
/// sync 消息循环里不能 await，故本函数独立存在并以事件回报结果；
/// 完成事件 'pluginScanned' 与旧的一次性路径完全同构，UI 侧无需区分。
void _scanChunked({
  required AuraDspLib lib,
  required Pointer<Void> handle,
  required String dir,
  required bool deep,
  required void Function(Map<String, dynamic>) send,
}) {
  // 深扫每步 1 个（单次 LoadLibrary 可能几十毫秒）；快扫每步 8 个
  // （PE 版本资源读取是纯 I/O，很快）。
  const quickBatch = 8;
  const deepBatch = 1;
  final batchSize = deep ? deepBatch : quickBatch;

  () async {
    try {
      var candidateTotal =
          AuraDspLib.pluginScanBeginWrap(lib, handle, dir: dir, deep: deep);
      send({
        'evt': 'pluginScanProgress',
        'done': 0,
        'total': candidateTotal,
        'found': 0,
      });

      var guard = 0;
      while (true) {
        final stepped =
            AuraDspLib.pluginScanStepWrap(lib, handle, maxItems: batchSize);
        if (stepped <= 0) break;
        final pr = AuraDspLib.pluginScanProgressWrap(lib, handle);
        final total = pr.total < 0 ? candidateTotal : pr.total;
        if (total > 0) candidateTotal = total;
        send({
          'evt': 'pluginScanProgress',
          'done': pr.processed,
          'total': total,
          'found': lib.pluginGetCount(handle),
        });
        // 让出事件循环：音频泵与未决命令得以推进（C3 同根因）。
        await Future<void>.delayed(Duration.zero);
        // 防御：候选数为 0 或引擎异常时避免死循环
        if (++guard > 20000) break;
      }

      final totalCount = AuraDspLib.pluginScanEndWrap(lib, handle);
      final allJson = AuraDspLib.pluginGetAllJson(lib, handle);
      send({
        'evt': 'pluginScanned',
        'count': totalCount,
        'json': allJson,
      });
    } catch (e) {
      send({'evt': 'error', 'msg': '插件扫描失败：$e'});
      // 失败也要收尾，避免扫描任务悬挂导致后续扫描被 begin 打断
      try {
        AuraDspLib.pluginScanEndWrap(lib, handle);
      } catch (e, st) { swallow(e, st); }
      send({'evt': 'pluginScanned', 'count': 0, 'json': '[]'});
    }
  }();
}

/// C3：异步挂载。
///
/// 旧实现在 isolate 事件循环上同步调 `pluginSlotLoadWrap`——实测挂载耗时
/// p50 77.6ms、max 1144.1ms（KV-Element-FX）。而音频泵（每 5ms 一轮推 WASAPI）
/// 与命令处理在同一事件循环上，于是 1.1s 的挂载 ≈ 跳过 220 轮泵 →
/// buffer underrun → 用户听到的就是"挂载时卡一下"。
///
/// 改为：引擎侧 `slot_load_async` 只做微秒级入队（重活挪到引擎控制线程，
/// 且不持 m_hostMutex），这里 fire-and-forget 轮询 task_state，每轮之间
/// `await Future<void>.delayed` 让出事件循环 → 音频泵照常推进。
Future<int> _slotLoadAsync(AuraDspLib lib, Pointer<Void> handle, int slot,
    String path, String id, void Function(Map<String, dynamic>) send) async {
  final (rc, timedOut) = await _submitAndWait(lib, handle, slot, send,
      isLoad: true, path: path, id: id);
  final statusJson = AuraDspLib.pluginSlotGetStatusJson(lib, handle, slot);
  final stage = AuraDspLib.pluginSlotGetInsertStageWrap(lib, handle, slot);
  send({
    'evt': 'pluginSlotLoaded',
    'slot': slot,
    'path': path,
    'rc': rc,
    'status': statusJson,
    'stage': stage,
    'busy': false,
    // D5：true = 等满上界仍无终态（插件挂死）。rc 已是 0（失败），
    // 这个字段让 UI 能区分"插件自己报错"与"它压根没回来"。
    if (timedOut) 'timedOut': true,
  });
  return rc;
}

/// C3：异步卸载。同 [_slotLoadAsync] 的根因——卸载重活（deactivate / destroy /
/// FreeLibrary，实测 p50 18.2ms、max 231.3ms）也必须移出事件循环。
Future<int> _slotUnloadAsync(AuraDspLib lib, Pointer<Void> handle, int slot,
    void Function(Map<String, dynamic>) send) async {
  final (rc, timedOut) = await _submitAndWait(lib, handle, slot, send,
      isLoad: false);
  final statusJson = AuraDspLib.pluginSlotGetStatusJson(lib, handle, slot);
  send({
    'evt': 'pluginSlotUnloaded',
    'slot': slot,
    'rc': rc,
    'status': statusJson,
    'busy': false,
    if (timedOut) 'timedOut': true,
  });
  return rc;
}

/// C3 轮询节奏与上界（D5 收口）。
///
/// 每轮 5ms 与泵节奏一致——这个间隔是"让出事件循环"的最小粒度，不改。
/// 上界原为 30000 轮 = **150s**：注释自己写着「实测 p50 18.2ms / max 231.3ms」，
/// 也就是正常路径连千分之一都用不到；而真挂死时用户对着转圈的 spinner 等
/// 2.5 分钟，期间没有任何提示（既不说"在等什么"，也不说"还要多久"）。
/// 5s 已是实测 max 的 20 倍，足够覆盖"大插件冷启动 + 磁盘慢"的极端情况。
const int kSlotTaskPollMs = 5;
const int kSlotTaskMaxWaitMs = 5000;

/// C3：提交异步任务并轮询到终态。返回 `(语义码, 是否超时)`。
/// 语义码：1 成功 / 0 失败（与引擎 load/unload 的返回约定一致）。
///
/// 超时（D5）：不再静默返回 0——先做兜底收口，再由调用方把 `timedOut` 带给 UI。
/// 兜底为什么走**同步** unload：`submitSlotUnloadAsync` 在 `taskState == 1` 时
/// 直接返回 false（"该槽已有任务在跑"），异步路径自己救不了自己。同步 unload
/// 会就地收口，且它内部等的 RT 在途块有 quarantine 上界（B3，~100ms），不会
/// 无限阻塞。代价是这一次调用卡住本 isolate，但相比"卡 150s 且无提示"可接受。
///
/// 被拒（该槽已有任务在跑）时**不发**终态事件——那个在跑的任务自己会发，
/// 这里静默返回避免误报"失败"。
Future<(int, bool)> _submitAndWait(AuraDspLib lib, Pointer<Void> handle, int slot,
    void Function(Map<String, dynamic>) send,
    {required bool isLoad, String path = '', String id = ''}) async {
  final accepted = isLoad
      ? AuraDspLib.pluginSlotLoadAsyncWrap(lib, handle, slot, path, id: id)
      : AuraDspLib.pluginSlotUnloadAsyncWrap(lib, handle, slot);
  if (accepted == 0) return (0, false);

  send({'evt': 'pluginSlotBusy', 'slot': slot, 'busy': true});
  final sw = Stopwatch()..start();
  try {
    // 按墙钟而非轮数收口：Future.delayed(5ms) 的实际调度粒度受事件循环负载
    // 影响，轮数 × 5ms 只是名义值（D2 在 C++ 侧踩过同一个坑：Sleep(1) 的
    // 实际粒度 5-15ms，3000 次循环名义 3s、实测 15-45s）。
    while (sw.elapsedMilliseconds < kSlotTaskMaxWaitMs) {
      final st = AuraDspLib.pluginSlotTaskStateWrap(lib, handle, slot);
      if (st != 1) return (st == 2 ? 1 : 0, false);
      // 关键：让出事件循环，音频泵才能在这 5ms 内推进。
      await Future<void>.delayed(const Duration(milliseconds: kSlotTaskPollMs));
    }
    _forceUnloadStuckSlot(lib, handle, slot);
  } finally {
    send({'evt': 'pluginSlotBusy', 'slot': slot, 'busy': false});
  }
  return (0, true);
}

/// D5 超时兜底：该槽的异步任务卡在 RUNNING，异步 unload 会被
/// 「taskState==1」拒掉，只能同步强制收口。兜底本身失败也不能盖掉
/// "超时"这个事实（调用方已经拿到 timedOut=true 并会上报 rc=0）。
void _forceUnloadStuckSlot(AuraDspLib lib, Pointer<Void> handle, int slot) {
  try {
    AuraDspLib.pluginSlotUnloadWrap(lib, handle, slot);
  } catch (e) {
    // 兜底失败不掩盖超时事实：rc=0 + timedOut=true 已由调用方发出。
    // 留痕以便现场排查（此时槽位可能仍被锁在 RUNNING）。
    assert(() {
      // ignore: avoid_print
      print('[audio_slots] D5 超时兜底 unload 失败 slot=$slot: $e');
      return true;
    }());
  }
}
