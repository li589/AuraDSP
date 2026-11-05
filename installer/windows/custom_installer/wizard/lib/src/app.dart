import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'args.dart';
import 'aurora_background.dart';
import 'engine/install_engine.dart';
import 'engine/models.dart';
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
  InstallManifest? _uninstallManifest;
  String? _manifestError;

  final List<ProgressEvent> _events = [];
  double _fraction = 0;
  bool _running = false;
  EngineResult? _result;
  bool _keepData = true;
  bool _launchApp = true;
  bool _openSound = false;

  @override
  void initState() {
    super.initState();
    _options = InstallOptions(installDir: defaultInstallDir(false));
    if (widget.args.mode == SetupMode.uninstall) {
      _page = _Page.uninstallConfirm;
      _loadUninstallManifest();
    } else {
      _page = _Page.welcome;
      _restoreResumeOptions();
    }
    if (widget.args.silent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startSilent());
    }
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
      if (_uninstallManifest != null) _runUninstall();
    } else {
      _options.closeRunningApps = true;
      _runInstall();
    }
  }

  InstallEngine get _engine => InstallEngine(args: widget.args, wizard: widget.wizard);

  Future<void> _maybeElevateThenInstall() async {
    final needsAdmin = _options.allUsers || _options.vaio;
    if (needsAdmin && !isElevated()) {
      final session = widget.args.sessionDir ?? Directory.systemTemp.path;
      final stateFile = File(p.join(session, 'resume_options.json'));
      await stateFile.writeAsString(jsonEncode(_options.toJson()));
      final self = Platform.resolvedExecutable;
      final params = StringBuffer('--resume-options "${stateFile.path}"');
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
      if (relaunchElevated(self, params.toString())) {
        await windowManager.close();
        return;
      }
      // 提权被拒绝：以降级方式继续（VAIO 步会给警告）。
    }
    _runInstall();
  }

  Future<void> _runInstall() async {
    setState(() {
      _page = _Page.progress;
      _running = true;
      _events.clear();
      _fraction = 0;
    });
    final r = await _engine.install(_options, (e) {
      if (!mounted) return;
      setState(() {
        _events.add(e);
        if (e.fraction != null && e.fraction! > _fraction) _fraction = e.fraction!;
      });
    });
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
    final r = await _engine.uninstall(m, keepData: _keepData, sink: (e) {
      if (!mounted) return;
      setState(() {
        _events.add(e);
        if (e.fraction != null && e.fraction! > _fraction) _fraction = e.fraction!;
      });
    });
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
    // 会话目录自清理：起一个延迟删除的 cmd（向导自身文件在其中，需等进程退出）。
    final session = widget.args.sessionDir;
    if (session != null) {
      try {
        await Process.start(
          'cmd',
          ['/c', 'ping -n 3 127.0.0.1 >nul & rmdir /s /q "$session"'],
          mode: ProcessStartMode.detached,
          runInShell: true,
        );
      } catch (_) {}
    }
    await windowManager.close();
  }

  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.welcomeTitle,
            style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        Text(l.welcomeBody, style: const TextStyle(color: Aurora.textDim, height: 1.55)),
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
              onPressed: _licenseAccepted
                  ? () {
                      _options.closeRunningApps = true;
                      _maybeElevateThenInstall();
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Text(l.quickInstall),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _licenseAccepted
                  ? () => setState(() => _page = _Page.options)
                  : null,
              child: Text(l.customInstall),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionsPage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final needsAdmin = _options.allUsers || _options.vaio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.optionsTitle,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 18),
        Text(l.installDirLabel, style: const TextStyle(color: Aurora.textDim, fontSize: 12.5)),
        const SizedBox(height: 6),
        TextFormField(
          initialValue: _options.installDir,
          onChanged: (v) => _options.installDir = v.trim(),
          style: const TextStyle(fontSize: 13.5),
          decoration: const InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Aurora.panel,
            border: OutlineInputBorder(borderSide: BorderSide(color: Aurora.hairline)),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _checkRow(l.allUsers, _options.allUsers, (v) {
                  _options.allUsers = v;
                  _options.installDir = defaultInstallDir(v);
                }),
                _checkRow(l.compAsio, _options.asio, (v) => _options.asio = v),
                _checkRow(l.compVaio, _options.vaio, (v) => _options.vaio = v),
                _checkRow(l.compDdc, _options.ddcPresets, (v) => _options.ddcPresets = v),
                const Divider(height: 22),
                _checkRow(l.scDesktop, _options.desktopShortcut,
                    (v) => _options.desktopShortcut = v),
                _checkRow(l.scStartMenu, _options.startMenuShortcut,
                    (v) => _options.startMenuShortcut = v),
                _checkRow(l.scAutostart, _options.autostart, (v) => _options.autostart = v),
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
                onPressed: () => setState(() => _page = _Page.welcome), child: Text(l.back)),
            const Spacer(),
            FilledButton(
              onPressed: () {
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
          child: LinearProgressIndicator(
            value: _running ? (_fraction <= 0 ? null : _fraction) : 1,
            minHeight: 10,
            backgroundColor: Aurora.panelRaised,
            valueColor: const AlwaysStoppedAnimation(Aurora.accent),
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
    final warnings = _result?.warnings ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const AnimatedCheck(),
        const SizedBox(height: 18),
        Text(isUninstall ? l.uninstalledTitle : l.finishTitle,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
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
        if (!isUninstall) ...[
          _checkRow(l.launchApp, _launchApp, (v) => _launchApp = v),
          _checkRow(l.openSound, _openSound, (v) => _openSound = v),
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
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: m == null || _running ? null : _runUninstall,
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
