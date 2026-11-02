/*
 * plugins_32bit_ui_test.dart — 32 位插件 UI 一致性（2026-11-03）。
 *
 * 与 Windows 对等（b886f9a 的 Win 侧修复 + 本轮 Linux 放开）：
 * Win/Linux 均有 plugin_host_x86 位桥，32 位插件在列表里不灰显
 * （Opacity 1.0）、显示「32-bit」角标；真正不支持的条目（损坏的
 * 64 位插件）仍灰显 0.55。其它平台 32 位仍按不支持灰显。
 */
import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/plugins/plugin_manager.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/plugins_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: PluginsPage(model: model)),
    );

double _itemOpacity(WidgetTester tester, String name) {
  final op = tester.widget<Opacity>(find
      .ancestor(of: find.text(name), matching: find.byType(Opacity))
      .first);
  return op.opacity;
}

void main() {
  testWidgets('32-bit plugin renders supported with badge on Win/Linux',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 与 plugin_manager_test 同口径：缓存写入重定向到临时目录，
    // 不污染真实用户配置。
    final tempDir =
        Directory.systemTemp.createTempSync('auradsp_plugin_ui_test');
    ConfigManager.baseDirOverride = tempDir.path;
    addTearDown(() => ConfigManager.baseDirOverride = null);

    final model = AppModel(testing: true);
    model.pluginManager.onPluginScanned(
      2,
      jsonEncode([
        {
          'id': 'x86-1',
          'name': 'Legacy 32bit FX',
          'vendor': 'LegacyCo',
          'version': '2.0',
          'format': 'CLAP',
          'path': '/plugins/Legacy.clap',
          'isCompatible': false,
          'is64Bit': false,
          'errorMessage': '32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本',
        },
        {
          'id': 'corrupt-1',
          'name': 'Corrupt FX',
          'vendor': 'CorruptCo',
          'version': '1.0',
          'format': 'VST3',
          'path': '/plugins/Corrupt.vst3',
          'isCompatible': false,
          'is64Bit': true,
          'errorMessage': '损坏的插件二进制',
        },
      ]),
    );

    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final bridgePlatform = Platform.isWindows || Platform.isLinux;
    if (bridgePlatform) {
      // 32 位：不灰显 + 角标在位（与 Windows 显示一致）。
      expect(_itemOpacity(tester, 'Legacy 32bit FX'), 1.0);
      expect(find.text('32-bit'), findsOneWidget);
    } else {
      expect(_itemOpacity(tester, 'Legacy 32bit FX'), 0.55);
      expect(find.text('32-bit'), findsNothing);
    }
    // 损坏的 64 位插件在任何平台都灰显（不支持判定未被放宽）。
    expect(_itemOpacity(tester, 'Corrupt FX'), 0.55);
  });
}
