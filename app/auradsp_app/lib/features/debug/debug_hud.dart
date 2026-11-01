/*
 * debug_hud.dart — `--debug` 启动时的实时调试面板（仅调试构建/启动参数）
 *
 * 面板刻意用英文，避免 l10n 硬编码门禁；显示最近 UI/param/engine 事件，
 * 以及「已出现控件 / 参数注册表总数 / 已收到引擎回执」覆盖率。
 * 点击标题折叠，避免遮挡具体控件。
 */
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/debug/debug_trace.dart';
import '../../core/param_schema.dart';

class DebugTraceHud extends StatefulWidget {
  const DebugTraceHud({super.key});

  @override
  State<DebugTraceHud> createState() => _DebugTraceHudState();
}

class _DebugTraceHudState extends State<DebugTraceHud> {
  bool _expanded = true;

  /// 定时采样保证面板始终跟随事件流。
  ///
  /// 事件可能在 build/布局阶段产生（控件登记就发生在 build 里），此时
  /// ValueNotifier 触发的 markNeedsBuild 会被同帧合并甚至丢弃，面板会
  /// 停在旧数据上，必须点标题触发一次 setState 才恢复。改为按 seq 轮询，
  /// 与事件来自哪个阶段无关。
  Timer? _tick;
  int _lastSeq = -1;

  @override
  void initState() {
    super.initState();
    _lastSeq = _currentSeq();
    _tick = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final seq = _currentSeq();
      if (seq == _lastSeq) return;
      _lastSeq = seq;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }

  int _currentSeq() {
    final events = DebugTrace.instance.lastEvents;
    return events.isEmpty ? 0 : events.last.seq;
  }

  int get _totalControls {
    var n = 0;
    for (final s in ParamRegistry.sections) {
      for (final spec in s.specs) {
        if (!spec.isDerivation) n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final events = DebugTrace.instance.lastEvents;
    final shown = _expanded ? events.reversed.take(8).toList() : const <DebugEvent>[];
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 390,
        constraints: const BoxConstraints(maxHeight: 260),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.5)),
          boxShadow: const [
            BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: Row(
                  children: [
                    Icon(Icons.bug_report_rounded,
                        size: 15, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'DEBUG TRACE  ·  UI ${DebugTrace.instance.controlCount}/$_totalControls'
                        '  ·  ACK ${DebugTrace.instance.ackCount}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final e = shown[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        e.oneLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.25,
                          fontFamily: 'Consolas',
                          color: e.cat == 'engine'
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
