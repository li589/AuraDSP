import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/args.dart';
import 'src/engine/models.dart';

Future<void> main(List<String> argv) async {
  WidgetsFlutterBinding.ensureInitialized();
  final args = SetupArgs.parse(argv);

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(920, 600),
    center: true,
    title: 'AuraDSP Setup',
    windowButtonVisibility: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(SetupApp(args: args, wizard: _loadWizardManifest()));
}

/// 读向导运行时根目录的 wizard_manifest.json（pack.py 写入 ZIP-W）。
/// 开发直跑（无清单）时用占位版本，保证 UI 可预览。
WizardManifest _loadWizardManifest() {
  try {
    final f = File(p.join(p.dirname(Platform.resolvedExecutable), 'wizard_manifest.json'));
    if (f.existsSync()) {
      return WizardManifest.fromJson(
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    }
  } catch (_) {}
  return const WizardManifest(version: '0.1.0', fullVersion: '0.1.0.1', payloadSha256: '');
}
