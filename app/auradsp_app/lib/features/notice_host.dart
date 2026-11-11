/*
 * notice_host.dart — 通用通知宿主（底部提醒框，2026-11-09 组件化）。
 *
 * 全 app 瞬时通知的唯一呈现点：监听 AppModel.eventSeq，逐条消费
 *   1) 引擎事件一次性字段（lastGuard / lastEngineError / lastInfo，
 *      本组件的前身 EventBanner 的原有通道，含 B-2 呈现层本地化）；
 *   2) 通用通知队列（AppModel.postNotice，各页面/状态层投递）。
 * 每次 eventSeq 自增恰好触发一次消费，与父级重建彻底解钩（2026-10-18
 * UI 排查结论）；队列保证同帧连发不互相吞掉，逐条排队呈现。
 * 投递方禁止再自行 ScaffoldMessenger.showSnackBar（契约测试钉死）。
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/engine_error_map.dart';
import '../core/notice.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';

class NoticeHost extends StatefulWidget {
  final AppModel model;
  const NoticeHost({super.key, required this.model});

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> {
  @override
  void initState() {
    super.initState();
    widget.model.eventSeq.addListener(_onEvent);
  }

  @override
  void dispose() {
    widget.model.eventSeq.removeListener(_onEvent);
    super.dispose();
  }

  void _onEvent() {
    if (widget.model.eventSeq.value == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drain());
  }

  void _drain() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return; // 无处呈现时不消费，事件保留
    final model = widget.model;
    final p = paletteOf(context);

    // 1) 引擎事件一次性字段（优先消费，行为与 EventBanner 时代一致）：
    //    读取即清空，杜绝后续操作重复唤起。
    final guard = model.lastGuard;
    final err = model.lastEngineError;
    final info = model.lastInfo;
    if (guard != null || err != null || info != null) {
      model.clearLastGuard();
      model.clearLastEngineError();
      model.clearLastInfo();
      final rawText = guard != null ? guard.message : (err ?? info ?? '');
      // B-2（D2）：引擎错误展示层本地化 + 脱敏（guard/error 来自引擎；
      // info 为 Dart 侧已本地化文案，原样透传）。detail 在此丢弃；
      // 原始串已由 state.dart 消费点 dbgLog 保留。
      final text = (guard != null || err != null)
          ? localizeEngineError(rawText, l10nOf(context))
          : rawText;
      if (text.isNotEmpty) {
        final isError = guard == null && err != null;
        final isInfo = guard == null && err == null;
        _show(
          messenger,
          p,
          text,
          isError
              ? Icons.error_outline
              : (isInfo ? Icons.info_outline : Icons.report_outlined),
          isError ? p.error : (isInfo ? p.accent : p.warning),
        );
      }
    } else {
      // 2) 通用通知队列：逐条消费（文案已本地化，不再过引擎本地化）。
      final notice = model.takeNotice();
      if (notice != null && notice.text.isNotEmpty) {
        final (icon, tint) = switch (notice.level) {
          NoticeLevel.error => (Icons.error_outline, p.error),
          NoticeLevel.warning => (Icons.report_outlined, p.warning),
          NoticeLevel.info => (Icons.info_outline, p.accent),
        };
        _show(messenger, p, notice.text, icon, tint);
      }
    }

    // 队列里还有积压 → 下一帧继续消费，逐条呈现不吞条。
    if (model.hasPendingNotice) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _drain());
    }
  }

  void _show(ScaffoldMessengerState messenger, AuraPalette p, String text,
      IconData icon, Color tint) {
    messenger.showSnackBar(SnackBar(
      showCloseIcon: true,
      closeIconColor: p.textDim,
      content: Row(
        children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: AuraSpace.md),
          Expanded(
            child: Text(text,
                style: TextStyle(color: p.text, fontSize: 13, height: 1.45)),
          ),
        ],
      ),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
