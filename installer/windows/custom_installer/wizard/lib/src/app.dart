import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'args.dart';
import 'aurora_background.dart';
import 'engine/cleanup_policy.dart';
import 'engine/driver_notice.dart';
import 'engine/install_engine.dart';
import 'engine/models.dart';
import 'engine/update_policy.dart';
import 'engine/win32.dart';
import 'package:auradsp_setup/l10n/app_localizations.dart';
import 'theme.dart';

enum _Page { welcome, options, progress, finish, error, uninstallConfirm }

class SetupApp extends StatelessWidget {
  const SetupApp({super.key, required this.args, required this.wizard});
  final SetupArgs args;
  final WizardManifest wizard;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AuraDSP Setup',
      theme: Aurora.theme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SetupShell(args: args, wizard: wizard),
    );
  }
}

class SetupShell extends StatefulWidget {
  const SetupShell({super.key, required this.args, required this.wizard});
  final SetupArgs args;
  final WizardManifest wizard;

  @override
  State<SetupShell> createState() => _SetupShellState();
}

class _SetupShellState extends State<SetupShell> {
  late _Page _page;
  late final InstallOptions _options;
  late final TextEditingController _dirController;
  late final FocusNode _dirFocus;
  UpdatePlan? _plan;
  bool _detecting = true;
  late final Future<void> _resumeFuture;
  InstallManifest? _uninstallManifest;
  String? _manifestError;

  final List<ProgressEvent> _events = [];
  double _fraction = 0;
  bool _running = false;
  EngineResult? _result;
  bool _keepData = true;
  bool _launchApp = true;
  bool _openSound = false;
  bool _awaitingElevation = false;
  bool _finishDesktopShortcut = true;
  DateTime _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);

  /// 每次状态变更后同步背景冻结：安装/卸载运行中或等待提权时
  /// 冻结极光步进（重活期间不做全窗渐变重绘，2026-11-12 降载）。
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    auroraFrozen.value = _running || _awaitingElevation;
  }

  @override
  void initState() {
    super.initState();
    _options = InstallOptions(installDir: defaultInstallDir(false));
    _dirController = TextEditingController(text: _options.installDir);
    _dirFocus = FocusNode()..addListener(_onDirFocusLost);
    _finishDesktopShortcut = _options.desktopShortcut;
    _keepData = widget.args.keepData ?? true;
    if (widget.args.mode == SetupMode.uninstall) {
      _resumeFuture = Future<void>.value();
      _page = _Page.uninstallConfirm;
      _detecting = false;
      _loadUninstallManifest();
      if (widget.args.autoUninstall || widget.args.silent) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _uninstallManifest != null) _maybeElevateThenUninstall();
        });
      }
    } else {
      _page = _Page.welcome;
      _resumeFuture = _restoreResumeOptions();
      _detectInstalled();
    }
  }

  @override
  void dispose() {
    _dirFocus.removeListener(_onDirFocusLost);
    _dirFocus.dispose();
    _dirController.dispose();
    super.dispose();
  }

  /// 探测已装实例 → 生成更新计划。提权重启时保留 resume 的用户选择，
  /// 但升级/降级仍锁定为旧目录。
  Future<void> _detectInstalled() async {
    // 提权重启先恢复用户选择，再探测已装实例，避免两者竞态覆盖安装目录。
    await _resumeFuture;
    final installed = await readInstalledInfo();
    final plan = planUpdate(
      newFullVersion: widget.wizard.fullVersion,
      requestedDir: _options.installDir,
      defaultDir: defaultInstallDir(false),
      installed: installed,
    );
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _detecting = false;
      if (widget.args.resumeOptions == null && plan.previous?.manifest != null) {
        _options.applyFrom(plan.previous!.manifest!);
      }
      _options.installDir = (plan.isOverwrite || plan.isBlocked)
          ? plan.installDir
          : normalizeInstallDir(_options.installDir, plan.installDir);
      _dirController.text = _options.installDir;
    });
    if (widget.args.autoStart && !widget.args.silent) {
      // 提权重启后自动继续安装，无需用户再点一次「开始安装」。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeElevateThenInstall();
      });
    } else if (widget.args.silent) {
      _startSilent();
    }
  }

  void _onDirFocusLost() {
    if (!_dirFocus.hasFocus) _commitDir();
  }

  /// 目录末段规范化（自动补 AuraDSP）；覆盖安装/降级锁定旧目录。
  void _commitDir() {
    final plan = _plan;
    final normalized = normalizeInstallDir(
        _dirController.text, defaultInstallDir(_options.allUsers));
    final effective = (plan != null && (plan.isOverwrite || plan.isBlocked))
        ? plan.installDir
        : normalized;
    _options.installDir = effective;
    if (_dirController.text != effective) {
      _dirController.text = effective;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openDriverReadme() async {
    final f = p.join(_options.installDir, kDriverReadmeRel);
    if (!File(f).existsSync()) return;
    await Process.start('notepad', [f], mode: ProcessStartMode.detached);
  }

  void _showSignGuide(BuildContext context) {
    final l = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aurora.panel,
        title: Text(l.signGuideTitle),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Text(l.signGuideBody,
                style: const TextStyle(fontSize: 12.5, height: 1.6)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: Text(l.close)),
        ],
      ),
    );
  }

  void _loadUninstallManifest() {
    final exe = widget.args.setupExe;
    if (exe == null) {
      _manifestError = 'uninstall.exe path unknown';
      return;
    }
    final f = File(p.join(p.dirname(exe), 'install_manifest.json'));
    if (!f.existsSync()) {
      _manifestError = 'install_manifest.json not found next to uninstall.exe';
      return;
    }
    try {
      _uninstallManifest = InstallManifest.decode(f.readAsStringSync());
    } catch (e) {
      _manifestError = '$e';
    }
  }

  Future<void> _restoreResumeOptions() async {
    final path = widget.args.resumeOptions;
    if (path == null) return;
    try {
      final j = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final restored = InstallOptions.fromJson(j);
      setState(() {
        _options.installDir = restored.installDir;
        _options.allUsers = restored.allUsers;
        _options.asio = restored.asio;
        _options.vaio = restored.vaio;
        _options.ddcPresets = restored.ddcPresets;
        _options.desktopShortcut = restored.desktopShortcut;
        _options.startMenuShortcut = restored.startMenuShortcut;
        _options.autostart = restored.autostart;
        _options.closeRunningApps = restored.closeRunningApps;
        _dirController.text = _options.installDir;
        _page = _Page.options;
      });
    } catch (_) {
      // 状态文件损坏则从欢迎页重新开始，不阻断安装。
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  void _startSilent() {
    if (widget.args.mode == SetupMode.uninstall) {
      if (_uninstallManifest != null) _maybeElevateThenUninstall();
    } else {
      _commitDir();
      _options.closeRunningApps = true;
      _runInstall();
    }
  }

  InstallEngine get _engine => InstallEngine(args: widget.args, wizard: widget.wizard);

  /// 提权协议：写状态 → 请求 UAC → 成功则让新进程带 --auto-start /
  /// --auto-uninstall 自动继续；失败则明确让用户选择，不静默降级、不卡住。
  Future<bool> _requestElevation({
    required bool autoStart,
    required bool autoUninstall,
  }) async {
    final session = widget.args.sessionDir ?? Directory.systemTemp.path;
    final stateFile = File(p.join(session, 'resume_options.json'));
    await stateFile.writeAsString(jsonEncode(_options.toJson()));
    final params =
        StringBuffer('--resume-options "${stateFile.path}" --elevated');
    if (autoStart) params.write(' --auto-start');
    if (autoUninstall) {
      params.write(' --auto-uninstall --mode uninstall');
      params.write(_keepData ? ' --keep-data' : ' --no-keep-data');
    }
    if (widget.args.setupExe != null) {
      params.write(' --setup-exe "${widget.args.setupExe}"');
    }
    if (widget.args.payloadOff != null) {
      params.write(' --payload-off ${widget.args.payloadOff}');
    }
    if (widget.args.payloadLen != null) {
      params.write(' --payload-len ${widget.args.payloadLen}');
    }
    if (widget.args.sessionDir != null) {
      params.write(' --session-dir "${widget.args.sessionDir}"');
    }
    return relaunchElevated(Platform.resolvedExecutable, params.toString());
  }

  /// ShellExecute 是同步 FFI：先把「等待授权」层渲染出来再调用，
  /// 否则 UAC 弹窗期间 UI isolate 被阻塞，界面看起来就是卡在进度页。
  Future<void> _showElevationWait() async {
    if (!mounted) return;
    setState(() => _awaitingElevation = true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  Future<void> _exitAfterElevation() async {
    // session 目录要留给提权后的新进程（resume_options.json / payload.zip），
    // 不能走 _closeWindow() 的延迟清理；直接退出进程。
    exit(0);
  }

  Future<String> _elevationDeniedDialog({required bool uninstall}) async {
    final l = AppLocalizations.of(context);
    final v = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Aurora.panel,
        title: Text(l.elevDeniedTitle),
        content:
            Text(uninstall ? l.elevUninstallDeniedBody : l.elevDeniedBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: Text(l.elevCancel)),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('continue'),
              child: Text(l.elevContinue)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop('retry'),
              child: Text(l.elevRetry)),
        ],
      ),
    );
    return v ?? 'cancel';
  }

  Future<void> _maybeElevateThenInstall() async {
    _commitDir();
    final needsAdmin = _options.allUsers || _options.vaio;
    // autoStart 进程仍未提权说明提权失败，直接降级安装，避免 UAC 循环弹窗。
    if (!needsAdmin || isElevated() || widget.args.autoStart) {
      _runInstall();
      return;
    }
    await _showElevationWait();
    final ok = await _requestElevation(autoStart: true, autoUninstall: false);
    if (!mounted) return;
    setState(() => _awaitingElevation = false);
    if (ok) {
      await _exitAfterElevation();
      return;
    }
    if (widget.args.silent) {
      _runInstall();
      return;
    }
    final choice = await _elevationDeniedDialog(uninstall: false);
    if (!mounted) return;
    if (choice == 'retry') {
      _maybeElevateThenInstall();
    } else if (choice == 'continue') {
      _runInstall();
    }
    // cancel：留在选项页，用户可自行调整或重试，不会卡在进度页。
  }

  /// 卸载一律请求管理员权限（清 HKLM / 设备节点 / 证书 / 公共快捷方式），
  /// 与常见软件「设置 → 应用 → 卸载」弹 UAC 的行为一致。
  Future<void> _maybeElevateThenUninstall() async {
    if (_uninstallManifest == null) return;
    // autoUninstall 进程仍未提权 = 提权失败，降级卸载并给出警告，不再循环弹 UAC。
    if (isElevated() || widget.args.autoUninstall) {
      _runUninstall();
      return;
    }
    await _showElevationWait();
    final ok = await _requestElevation(autoStart: false, autoUninstall: true);
    if (!mounted) return;
    setState(() => _awaitingElevation = false);
    if (ok) {
      await _exitAfterElevation();
      return;
    }
    if (widget.args.silent || widget.args.autoUninstall) {
      _runUninstall();
      return;
    }
    final choice = await _elevationDeniedDialog(uninstall: true);
    if (!mounted) return;
    if (choice == 'retry') {
      _maybeElevateThenUninstall();
    } else if (choice == 'continue') {
      _runUninstall();
    }
  }

  /// 进度事件节流：解压约 1600 个文件会产生同样多的事件，逐条 setState
  /// 会让整棵进度页跟着重建（叠加背景动画就是 GPU/内存暴涨的主因）。
  /// 60ms 一次足够平滑；日志只保留最近 120 条，避免列表无限增长。
  void _onProgress(ProgressEvent e) {
    if (!mounted) return;
    final now = DateTime.now();
    final force = e.step == 'done' || e.step == 'restore';
    if (!force && now.difference(_lastProgressPaint).inMilliseconds < 60) {
      return;
    }
    _lastProgressPaint = now;
    setState(() {
      _events.add(e);
      if (_events.length > 120) {
        _events.removeRange(0, _events.length - 120);
      }
      if (e.fraction != null && e.fraction! > _fraction) {
        _fraction = e.fraction!;
      }
    });
  }

  Future<void> _runInstall() async {
    setState(() {
      _page = _Page.progress;
      _running = true;
      _events.clear();
      _fraction = 0;
    });
    final r = await _engine.install(_options, _onProgress, plan: _plan);
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = r;
      _page = r.ok ? _Page.finish : _Page.error;
    });
    if (widget.args.silent) await _closeWindow();
  }

  Future<void> _runUninstall() async {
    final m = _uninstallManifest;
    if (m == null) return;
    setState(() {
      _page = _Page.progress;
      _running = true;
      _events.clear();
      _fraction = 0;
    });
    final r = await _engine.uninstall(m, keepData: _keepData, sink: _onProgress);
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = r;
      _page = r.ok ? _Page.finish : _Page.error;
    });
    if (widget.args.silent) await _closeWindow();
  }

  Future<void> _finishAndClose() async {
    if (_page == _Page.finish && _result?.ok == true) {
      if (widget.args.mode == SetupMode.install) {
        // 完成页的最终决定优先于安装前的默认勾选（可补建或取消）。
        await _engine.setDesktopShortcut(_options.installDir,
            create: _finishDesktopShortcut);
      }
      if (widget.args.mode == SetupMode.install && _launchApp) {
        final exe = p.join(_options.installDir, 'auradsp_app.exe');
        if (File(exe).existsSync()) {
          await Process.start(exe, [], workingDirectory: _options.installDir, mode: ProcessStartMode.detached);
        }
      }
      if (widget.args.mode == SetupMode.install && _openSound) {
        await Process.start('control', ['mmsys.cpl'], mode: ProcessStartMode.detached);
      }
    }
    await _closeWindow();
  }

  Future<void> _closeWindow() async {
    // 退出后清理：隐藏的 PowerShell 脚本（SW_HIDE + -WindowStyle Hidden）。
    // 绝不能用可见 cmd —— 控制台被点选进入 QuickEdit「选择」模式会挂起，
    // 用户就看到一个永远关不掉的黑窗口。脚本顺便重试删除被占用文件。
    final session = widget.args.sessionDir ?? '';
    final leftovers = _result?.leftoverPaths ?? const <String>[];
    if (session.isNotEmpty || leftovers.isNotEmpty) {
      try {
        final script = File(p.join(Directory.systemTemp.path,
            'auradsp-cleanup-$pid.ps1'));
        // Windows PowerShell 5.1 按 ANSI 读取无 BOM 脚本，中文路径会乱码；
        // 手写 BOM + utf8 编码等价于 Python 的 utf-8-sig。
        script.writeAsStringSync(
            '\uFEFF${buildCleanupScript(session: session, leftovers: leftovers)}',
            encoding: utf8);
        spawnHiddenCleanup(script.path);
      } catch (_) {}
    }
    await windowManager.close();
  }

  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: Stack(
        children: [
          AuroraBackground(
            child: Column(
              children: [
                _titleBar(context),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _brandRail(context),
                      Expanded(child: _pageBody(context)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_awaitingElevation)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.62),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SteppedSpinner(),
                      const SizedBox(height: 16),
                      Text(l.awaitingElevation,
                          style: const TextStyle(
                              color: Aurora.text, fontSize: 13.5)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _titleBar(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(l.appTitle,
                      style: const TextStyle(color: Aurora.textDim, fontSize: 12.5)),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: () => windowManager.minimize(),
            icon: const Icon(Icons.remove, size: 16, color: Aurora.textDim),
          ),
          IconButton(
            onPressed: _running ? null : _closeWindow,
            icon: const Icon(Icons.close, size: 16, color: Aurora.textDim),
          ),
        ],
      ),
    );
  }

  Widget _brandRail(BuildContext context) {
    final l = AppLocalizations.of(context);
    final steps = widget.args.mode == SetupMode.uninstall
        ? [l.uninstallTitle, l.progressTitle, l.done]
        : [l.welcomeTitle, l.optionsTitle, l.progressTitle, l.done];
    final active = switch (_page) {
      _Page.welcome => 0,
      _Page.options => 1,
      _Page.uninstallConfirm => 0,
      _Page.progress => widget.args.mode == SetupMode.uninstall ? 1 : 2,
      _Page.finish => 3,
      _Page.error => 2,
    };
    return Container(
      width: 264,
      color: Aurora.panel.withValues(alpha: 0.55),
      padding: const EdgeInsets.fromLTRB(28, 30, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('AuraDSP',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: Aurora.text)),
          const SizedBox(height: 4),
          Text('v${widget.wizard.version}',
              style: const TextStyle(color: Aurora.accent, fontSize: 13)),
          const SizedBox(height: 40),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == active
                          ? Aurora.accent
                          : (i < active ? Aurora.success : Aurora.hairline),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(steps[i],
                      style: TextStyle(
                          color: i == active ? Aurora.text : Aurora.textDim,
                          fontSize: 13.5,
                          fontWeight: i == active ? FontWeight.w600 : FontWeight.normal)),
                ],
              ),
            ),
          const Spacer(),
          const Text('li589/AuraDSP',
              style: TextStyle(color: Aurora.textDim, fontSize: 11.5)),
        ],
      ),
    );
  }

  Widget _pageBody(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.02, 0), end: Offset.zero).animate(anim),
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey(_page),
        padding: const EdgeInsets.fromLTRB(36, 28, 36, 24),
        child: switch (_page) {
          _Page.welcome => _welcomePage(context),
          _Page.options => _optionsPage(context),
          _Page.progress => _progressPage(context),
          _Page.finish => _finishPage(context),
          _Page.error => _errorPage(context),
          _Page.uninstallConfirm => _uninstallPage(context),
        },
      ),
    );
  }

  // ---- pages ----

  bool _licenseAccepted = false;

  Widget _welcomePage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final plan = _plan;
    final blocked = plan?.isBlocked ?? false;
    final isUpdate = plan?.mode == UpdateMode.upgrade;
    final ready = _licenseAccepted && !blocked && !_detecting;
    final banner = _updateBanner(context, plan);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.welcomeTitle,
            style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        Text(l.welcomeBody, style: const TextStyle(color: Aurora.textDim, height: 1.55)),
        const SizedBox(height: 14),
        if (banner != null) banner,
        const Spacer(),
        InkWell(
          onTap: () => setState(() => _licenseAccepted = !_licenseAccepted),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                  value: _licenseAccepted,
                  onChanged: (v) => setState(() => _licenseAccepted = v ?? false)),
              Expanded(
                  child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(l.licenseAgree, style: const TextStyle(fontSize: 12.5)),
              )),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            FilledButton(
              onPressed: ready
                  ? () {
                      _options.closeRunningApps = true;
                      _maybeElevateThenInstall();
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Text(isUpdate ? l.quickUpdate : l.quickInstall),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: ready ? () => setState(() => _page = _Page.options) : null,
              child: Text(l.customInstall),
            ),
          ],
        ),
      ],
    );
  }

  /// 欢迎页更新态横幅：全新安装不显示，降级给出拦截说明。
  Widget? _updateBanner(BuildContext context, UpdatePlan? plan) {
    final l = AppLocalizations.of(context);
    if (plan == null) return null;
    final oldVer = plan.previous?.fullVersion ?? '0.0.0';
    final newVer = widget.wizard.fullVersion;
    final (String text, Color color) = switch (plan.mode) {
      UpdateMode.upgrade => (l.updateDetected(oldVer, newVer), Aurora.accent),
      UpdateMode.repair => (l.updateRepair(newVer), Aurora.accent),
      UpdateMode.downgradeBlocked => (
          '${l.updateDowngrade(oldVer, newVer)}\n${l.blockedHint}',
          Aurora.warning
        ),
      UpdateMode.fresh => ('', Aurora.textDim),
    };
    if (text.isEmpty) return null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(plan.isBlocked ? Icons.error_outline : Icons.system_update_alt,
              size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: color, fontSize: 12.5, height: 1.5))),
        ],
      ),
    );
  }

  Widget _optionsPage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final needsAdmin = _options.allUsers || _options.vaio;
    final locked = (_plan?.isOverwrite ?? false) || (_plan?.isBlocked ?? false);
    final blocked = _plan?.isBlocked ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.optionsTitle,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 18),
        Text(l.installDirLabel, style: const TextStyle(color: Aurora.textDim, fontSize: 12.5)),
        const SizedBox(height: 6),
        TextField(
          controller: _dirController,
          focusNode: _dirFocus,
          readOnly: locked,
          onChanged: (v) => _options.installDir = v.trim(),
          onSubmitted: (_) => _commitDir(),
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Aurora.panel,
            border: const OutlineInputBorder(
                borderSide: BorderSide(color: Aurora.hairline)),
            helperText: locked ? l.updateDirLocked : l.dirAutoAppendHint,
            helperStyle: const TextStyle(color: Aurora.textDim, fontSize: 11),
            suffixIcon: locked
                ? const Icon(Icons.lock_outline, size: 16, color: Aurora.textDim)
                : null,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _checkRow(l.allUsers, _options.allUsers, (v) {
                  _options.allUsers = v;
                  if (!locked) {
                    _options.installDir = defaultInstallDir(v);
                    _dirController.text = _options.installDir;
                  }
                }),
                const Divider(height: 18),
                Text(l.driverGroupTitle,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(l.driverOptionalHint,
                      style: const TextStyle(
                          color: Aurora.textDim, fontSize: 11.5, height: 1.4)),
                ),
                _checkRow(l.compAsio, _options.asio, (v) => _options.asio = v),
                _checkRow(l.compVaio, _options.vaio, (v) => _options.vaio = v),
                if (_options.vaio) _signWarning(context),
                _checkRow(l.compDdc, _options.ddcPresets,
                    (v) => _options.ddcPresets = v),
                const Divider(height: 18),
                _checkRow(l.scDesktop, _options.desktopShortcut,
                    (v) => _options.desktopShortcut = v),
                _checkRow(l.scStartMenu, _options.startMenuShortcut,
                    (v) => _options.startMenuShortcut = v),
                _checkRow(l.scAutostart, _options.autostart,
                    (v) => _options.autostart = v),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(l.manualDriverHint,
                      style: const TextStyle(color: Aurora.textDim, fontSize: 11.5)),
                ),
                if (needsAdmin && !isElevated())
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(children: [
                      const Icon(Icons.shield_outlined, size: 15, color: Aurora.warning),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(l.needsElevation,
                              style: const TextStyle(color: Aurora.warning, fontSize: 12.5))),
                    ]),
                  ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            OutlinedButton(
                onPressed: () => setState(() => _page = _Page.welcome),
                child: Text(l.back)),
            const Spacer(),
            FilledButton(
              onPressed: blocked
                  ? null
                  : () {
                      _options.closeRunningApps = true;
                      _maybeElevateThenInstall();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                child: Text(l.startInstall),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// VAIO 测试签名风险卡片：短提示 + 完整教程弹窗入口。
  Widget _signWarning(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(left: 12, right: 8, bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Aurora.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Aurora.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_amber_outlined, size: 16, color: Aurora.warning),
            const SizedBox(width: 8),
            Expanded(
                child: Text(l.signWarnTitle,
                    style: const TextStyle(
                        color: Aurora.warning,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 6),
          Text(l.signWarnShort,
              style: const TextStyle(
                  color: Aurora.textDim, fontSize: 11.5, height: 1.5)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: () => _showSignGuide(context),
                child: Text(l.signViewGuide)),
          ),
        ],
      ),
    );
  }

  Widget _checkRow(String label, bool value, void Function(bool) onChanged) {
    return InkWell(
      onTap: () => setState(() => onChanged(!value)),
      child: Row(
        children: [
          Checkbox(value: value, onChanged: (v) => setState(() => onChanged(v ?? false))),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
        ],
      ),
    );
  }

  String _stepLabel(BuildContext context, String step) {
    final l = AppLocalizations.of(context);
    return switch (step) {
      'guard' => l.stepGuard,
      'backup' => l.stepBackup,
      'restore' => l.stepRestore,
      'extract' => l.stepExtract,
      'asio' => l.stepAsio,
      'driver' => l.stepDriver,
      'shortcuts' => l.stepShortcuts,
      'registry' => l.stepRegistry,
      'uninstaller' => l.stepUninstaller,
      'cleanup' => l.stepCleanup,
      _ => l.stepDone,
    };
  }

  Widget _progressPage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final last = _events.isEmpty ? null : _events.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.args.mode == SetupMode.uninstall ? l.uninstallProgressTitle : l.progressTitle,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 26),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SteppedProgressBar(
            value: _running ? (_fraction <= 0 ? null : _fraction) : 1,
            height: 10,
          ),
        ),
        const SizedBox(height: 14),
        Text(last == null ? '' : '${_stepLabel(context, last.step)} — ${last.detail}',
            style: const TextStyle(color: Aurora.textDim, fontSize: 12.5)),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Aurora.panel.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Aurora.hairline),
            ),
            padding: const EdgeInsets.all(12),
            child: ListView.builder(
              itemCount: _events.length,
              itemBuilder: (context, i) {
                final e = _events[_events.length - 1 - i];
                return Text('${_stepLabel(context, e.step)}  ${e.detail}',
                    style: const TextStyle(color: Aurora.textDim, fontSize: 11.5, height: 1.5));
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _finishPage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isUninstall = widget.args.mode == SetupMode.uninstall;
    final isUpdate = _plan?.mode == UpdateMode.upgrade;
    final warnings = _result?.warnings ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const AnimatedCheck(),
        const SizedBox(height: 18),
        Text(
            isUninstall
                ? l.uninstalledTitle
                : (isUpdate ? l.finishUpdatedTitle : l.finishTitle),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        if (isUpdate && !isUninstall && _plan?.previous != null) ...[
          const SizedBox(height: 6),
          Text(l.updateFrom(_plan!.previous!.fullVersion, widget.wizard.fullVersion),
              style: const TextStyle(color: Aurora.accent, fontSize: 12.5)),
        ],
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(l.warningsTitle, style: const TextStyle(color: Aurora.warning, fontSize: 13)),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              child: Text(warnings.map((w) => '• $w').join('\n'),
                  style: const TextStyle(color: Aurora.textDim, fontSize: 12.5, height: 1.6)),
            ),
          ),
        ] else
          const Spacer(),
        if (isUninstall) ...[
          Text(l.uninstallCleanNote,
              style: const TextStyle(color: Aurora.textDim, fontSize: 12)),
          if (_result?.keptPaths.isNotEmpty ?? false) ...[
            const SizedBox(height: 8),
            Text(l.uninstallKeptTitle,
                style: const TextStyle(color: Aurora.accent, fontSize: 12)),
            for (final path in _result!.keptPaths)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text(path,
                    style: const TextStyle(
                        color: Aurora.textDim, fontSize: 11.5)),
              ),
          ],
          const SizedBox(height: 8),
        ],
        if (!isUninstall) ...[
          _checkRow(l.finishDesktopShortcut, _finishDesktopShortcut,
              (v) => _finishDesktopShortcut = v),
          _checkRow(l.launchApp, _launchApp, (v) => _launchApp = v),
          _checkRow(l.openSound, _openSound, (v) => _openSound = v),
          if (_options.vaio)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openDriverReadme,
                icon: const Icon(Icons.description_outlined, size: 16),
                label: Text(l.openDriverReadme),
              ),
            ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _finishAndClose,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(l.done),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorPage(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 52, color: Aurora.error),
        const SizedBox(height: 16),
        Text(l.errorTitle, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text(l.errorBody, style: const TextStyle(color: Aurora.textDim)),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Text(_result?.error ?? '',
                style: const TextStyle(color: Aurora.error, fontSize: 12.5, height: 1.6)),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: _closeWindow, child: Text(l.close)),
        ),
      ],
    );
  }

  Widget _uninstallPage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final m = _uninstallManifest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.uninstallTitle,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        Text(l.uninstallBody, style: const TextStyle(color: Aurora.textDim, height: 1.55)),
        const SizedBox(height: 10),
        if (m != null)
          Text('${m.installDir}  •  v${m.version}',
              style: const TextStyle(color: Aurora.textDim, fontSize: 12.5))
        else if (_manifestError != null)
          Text(_manifestError!,
              style: const TextStyle(color: Aurora.error, fontSize: 12.5)),
        const Spacer(),
        _checkRow(l.keepData, _keepData, (v) => _keepData = v),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 8, top: 4),
          child: Text(
            _keepData ? l.keepDataHint : l.uninstallDeleteAllHint,
            style: TextStyle(
                color: _keepData ? Aurora.textDim : Aurora.warning,
                fontSize: 11.5,
                height: 1.5),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: m == null || _running ? null : _maybeElevateThenUninstall,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Text(l.startUninstall),
            ),
          ),
        ),
      ],
    );
  }
}
