/*
 * main.dart — AuraDSP UI 层入口
 *
 * APP = AuraDSP Engines（驱动层，本机为 auradsp_engine.dll）+ UI（本文件起）。
 * AppModel 创建音频 isolate；UI 仅消费状态与发命令，不触 RT 路径。
 */
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'core/design.dart';
import 'core/state.dart';
import 'core/theme.dart';
import 'engine/debug_log.dart';
import 'features/shell.dart';
import 'features/widgets.dart';
import 'l10n/gen/app_localizations.dart';

void main() {
  // 全局异常落文件（%TEMP%\auradsp_debug.log），与音频 isolate 共用
  FlutterError.onError = (d) {
    dbgLog('FLUTTER ERROR: ${d.exception}\n${d.stack}');
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    dbgLog('PLATFORM ERROR: $e\n$st');
    return false;
  };
  runZonedGuarded(() => runApp(const AuraApp()), (e, st) {
    dbgLog('ZONE ERROR: $e\n$st');
  });
}

class AuraApp extends StatefulWidget {
  const AuraApp({super.key});

  @override
  State<AuraApp> createState() => _AuraAppState();
}

class _AuraAppState extends State<AuraApp> {
  late final AppModel _model = AppModel();

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _model,
      builder: (_, _) {
        return MaterialApp(
          title: 'AuraDSP',
          debugShowCheckedModeBanner: false,
          locale: _model.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          onGenerateTitle: (ctx) => l10nOf(ctx).appName,
          theme: withAuraExtension(
              buildAuraTheme(_model.themeId), _model.themeId.palette),
          home: ShellGate(model: _model),
        );
      },
    );
  }
}

/// 连接意图明确后再进 Shell（fatal 时给修复指引，不给白屏）
class ShellGate extends StatelessWidget {
  final AppModel model;
  const ShellGate({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    switch (model.conn) {
      case EngineConn.fatal:
        return _FatalPage(msg: model.fatalMsg ?? '');
      case EngineConn.connecting:
      case EngineConn.ready:
        return Stack(children: [
          AppShell(model: model),
          EventBanner(model: model),
        ]);
    }
  }
}

class _FatalPage extends StatelessWidget {
  final String msg;
  const _FatalPage({required this.msg});

  @override
  Widget build(BuildContext context) {
    final p = auraDark;
    final l = l10nOf(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(AuraRadius.lg),
            border: Border.all(color: p.error.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.engineFailed,
                  style: TextStyle(
                      fontFamily: 'AuraDisplay',
                      fontSize: 22, fontWeight: FontWeight.w800,
                      color: p.error)),
              const SizedBox(height: 12),
              Text(l.engineFailedBody,
                  style: TextStyle(fontSize: 13.5, color: p.text, height: 1.6)),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: p.bg,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: Text(msg,
                    style: monoOf(p, size: 11, color: p.textDim)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
