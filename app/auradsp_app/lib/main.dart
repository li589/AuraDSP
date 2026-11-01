/*
 * main.dart — AuraDSP UI 层入口
 *
 * APP = AuraDSP Engines（驱动层，本机为 auradsp_engine.dll）+ UI（本文件起）。
 * AppModel 创建音频 isolate；UI 仅消费状态与发命令，不触 RT 路径。
 */
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'core/debug/debug_trace.dart';
import 'core/design.dart';
import 'core/presets.dart';
import 'core/state.dart';
import 'core/theme.dart';
import 'platform/adapters.dart';
import 'engine/debug_log.dart';
import 'features/debug/debug_hud.dart';
import 'features/shell.dart';
import 'features/widgets.dart';
import 'l10n/gen/app_localizations.dart';

void main(List<String> args) {
  // 调试总线：--debug / --debug-log=<path> 时才产生结构化 JSONL 事件流。
  DebugTrace.instance.initFromArgs(args);
  DebugTrace.instance.event('lifecycle', 'app.start', data: {'args': args});
  // 全局异常落文件（%TEMP%\auradsp_debug.log），与音频 isolate 共用；
  // 同时进入结构化调试流（若开启）。
  FlutterError.onError = (d) {
    dbgLog('FLUTTER ERROR: ${d.exception}\n${d.stack}');
    DebugTrace.instance.log('error', 'FLUTTER: ${d.exception}');
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    dbgLog('PLATFORM ERROR: $e\n$st');
    DebugTrace.instance.log('error', 'PLATFORM: $e');
    return false;
  };
  runZonedGuarded(() => runApp(const AuraApp()), (e, st) {
    dbgLog('ZONE ERROR: $e\n$st');
    DebugTrace.instance.log('error', 'ZONE: $e');
  });
}

class AuraApp extends StatefulWidget {
  const AuraApp({super.key});

  @override
  State<AuraApp> createState() => _AuraAppState();
}

class _AuraAppState extends State<AuraApp> with WidgetsBindingObserver {
  AppModel? _model;
  // theme 缓存：themeId 不变则复用 ThemeData 对象——AppModel 高频通知
  // （viz 帧/参数拖动）不应反复重建整棵主题（MaterialApp 重建热点）。
  AuraThemeId? _cachedThemeId;
  ThemeData? _cachedTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PlatformAdapters.instance.window.setVisible(true);
    }
  }

  ThemeData _themeFor(AppModel m) {
    if (_cachedThemeId != m.themeId) {
      _cachedThemeId = m.themeId;
      _cachedTheme = withAuraExtension(
          buildAuraTheme(m.themeId), m.themeId.palette);
    }
    return _cachedTheme!;
  }

  Future<void> _boot() async {
    // 出厂预设/默认基线资产预载：rootBundle 只有异步 API，而 listAll→
    // ensureInitialized 与 apply 全量复写都在同步路径。必须在 AppModel
    // 构造前完成，否则会话恢复/预设读取拿不到资产数据。
    await PresetLibrary.preloadFactoryAssets();
    // 托盘/关窗拦截（非核心路径：失败不阻塞启动，仅不提供托盘）
    final adapters = PlatformAdapters.instance;
    await adapters.window.init();
    if (!mounted) return;
    // 平台端口在组合根注入：core 不 import 具体平台实现（门禁 F11）。
    setState(() => _model ??= AppModel(
          window: adapters.window,
          pluginDirs: adapters.pluginDirs,
          registry: adapters.registry,
          windowsSystem: adapters.windowsSystem,
        ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model?.dispose();
    PlatformAdapters.instance.window.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    if (model == null) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    // 只订阅「外观」计数（主题/语言）。此前监听整份 AppModel：任何参数拖动、
    // 引擎事件、预设载入都会重建 MaterialApp → ShellGate → 六个保活页，
    // 是交互期 CPU 的主要放大器。连接态由 ShellGate 自己订阅 connTick。
    return ValueListenableBuilder<int>(
      valueListenable: model.appearanceTick,
      builder: (_, _, _) {
        return MaterialApp(
          title: 'AuraDSP',
          debugShowCheckedModeBanner: false,
          locale: model.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          onGenerateTitle: (ctx) => l10nOf(ctx).appName,
          theme: _themeFor(model),
          home: ShellGate(model: model),
          builder: (ctx, child) {
            final l = l10nOf(ctx);
            PlatformAdapters.instance.window.applyLocale(
                Localizations.localeOf(ctx).toString(),
                l.trayShow, l.sysAutostart, l.trayQuit);
            // 避免在根层级包裹 TickerMode(enabled: isVisible)：
            // 根层 TickerMode 曾在最小化还原时因事件滞后或丢包导致全局 Ticker 锁死，
            // 引起 AnimatedSwitcher 页面切换与按钮微交互假死。
            // 显存与后台节流已由 chrome 背景光晕与音频可视化监听器精准独立接管。
            // 此处使用透明 Listener 守卫：任何指针落入均自愈拉起可见性。
            final body = child ?? const SizedBox.shrink();
            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                DebugTrace.instance.pointer(e.position.dx, e.position.dy);
                if (!PlatformAdapters.instance.window.isVisible) {
                  PlatformAdapters.instance.window.setVisible(true);
                }
              },
              onPointerHover: (_) {
                if (!PlatformAdapters.instance.window.isVisible) {
                  PlatformAdapters.instance.window.setVisible(true);
                }
              },
              child: Stack(
                children: [
                  body,
                  if (DebugTrace.instance.enabled)
                    const Positioned(
                      right: 12,
                      bottom: 12,
                      child: DebugTraceHud(),
                    ),
                ],
              ),
            );
          },
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
    // 只订阅连接态：参数/事件粗通知不再波及整棵 Shell。
    return ValueListenableBuilder<int>(
      valueListenable: model.connTick,
      builder: (_, _, _) {
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
      },
    );
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
