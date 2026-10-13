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
      } catch (_) {}
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
void _slotLoadAsync(AuraDspLib lib, Pointer<Void> handle, int slot, String path,
    String id, void Function(Map<String, dynamic>) send) {
  () async {
    final rc = await _submitAndWait(lib, handle, slot, send, isLoad: true,
        path: path, id: id);
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
    });
  }();
}

/// C3：异步卸载。同 [_slotLoadAsync] 的根因——卸载重活（deactivate / destroy /
/// FreeLibrary，实测 p50 18.2ms、max 231.3ms）也必须移出事件循环。
void _slotUnloadAsync(AuraDspLib lib, Pointer<Void> handle, int slot,
    void Function(Map<String, dynamic>) send) {
  () async {
    final rc = await _submitAndWait(lib, handle, slot, send, isLoad: false);
    final statusJson = AuraDspLib.pluginSlotGetStatusJson(lib, handle, slot);
    send({
      'evt': 'pluginSlotUnloaded',
      'slot': slot,
      'rc': rc,
      'status': statusJson,
      'busy': false,
    });
  }();
}

/// C3：提交异步任务并轮询到终态。返回引擎 load/unload 的语义码（1 成功 / 0 失败）。
///
/// 每轮间隔 5ms（与泵节奏一致）；上限 30000 轮（150s）防悬挂。
/// 被拒（该槽已有任务在跑）时**不发**终态事件——那个在跑的
/// 任务自己会发，这里静默返回避免误报"失败"。
Future<int> _submitAndWait(AuraDspLib lib, Pointer<Void> handle, int slot,
    void Function(Map<String, dynamic>) send,
    {required bool isLoad, String path = '', String id = ''}) async {
  final accepted = isLoad
      ? AuraDspLib.pluginSlotLoadAsyncWrap(lib, handle, slot, path, id: id)
      : AuraDspLib.pluginSlotUnloadAsyncWrap(lib, handle, slot);
  if (accepted == 0) return 0;

  send({'evt': 'pluginSlotBusy', 'slot': slot, 'busy': true});
  try {
    for (int i = 0; i < 30000; ++i) {
      final st = AuraDspLib.pluginSlotTaskStateWrap(lib, handle, slot);
      if (st != 1) return st == 2 ? 1 : 0;
      // 关键：让出事件循环，音频泵才能在这 5ms 内推进。
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  } finally {
    send({'evt': 'pluginSlotBusy', 'slot': slot, 'busy': false});
  }
  return 0;
}
