// about_page_test.dart — 关于页与左栏形态标签契约（2026-11-09）。
//
// 源码不变式 + 版本一致性：
//   - kAppVersion 必须与 pubspec.yaml 的 version 主版本一致（防漂移）；
//   - 设置页第 5 分类《关于》接线（case 4 / buildAboutTab / catAbout）；
//   - 关于页外链经 ShellOpenPort.openUrl，参考项目五条地址齐全；
//   - 左栏底部单行「ABI v… · formLabel」，旧两行文案不得回归。
import 'dart:io';

import 'package:auradsp_app/core/app_info.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String relPath) {
  for (final base in const ['', '../', '../../']) {
    final f = File('$base$relPath');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $relPath（cwd=${Directory.current.path}）');
}

void main() {
  group('关于页（2026-11-09）', () {
    test('kAppVersion 与 pubspec version 一致', () {
      final pubspec = _read('app/auradsp_app/pubspec.yaml');
      final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull);
      expect(m!.group(1), kAppVersion);
    });

    test('设置页关于分类接线', () {
      final page = _read('app/auradsp_app/lib/features/settings_page.dart');
      expect(page, contains('settings_about_tab.dart'));
      expect(page, contains('buildAboutTab(context, model)'));
      expect(page, contains('l.catAbout'));
      final tab =
          _read('app/auradsp_app/lib/features/settings/settings_about_tab.dart');
      expect(tab, contains('kAppVersion'));
      expect(tab, contains('PlatformProfile.formLabel'));
      expect(tab, contains('openUrl'));
    });

    test('参考核心项目五条地址齐全', () {
      final tab =
          _read('app/auradsp_app/lib/features/settings/settings_about_tab.dart');
      for (final url in const [
        'https://github.com/james34602/JamesDSPManager',
        'https://github.com/Audio4Linux/JDSP4Linux',
        'https://github.com/free-audio/clap',
        'https://github.com/steinbergmedia/vst3sdk',
        'https://github.com/Xaymar/vst2sdk',
      ]) {
        expect(tab, contains(url), reason: url);
      }
      expect(tab, contains('/blob/main/LICENSE'));
    });

    test('ShellOpenPort.openUrl 三端齐全', () {
      final port = _read('app/auradsp_app/lib/platform/port/shell_open.dart');
      expect(port, contains('Future<bool> openUrl(String url);'));
      final desktop =
          _read('app/auradsp_app/lib/platform/shell/shell_open_desktop.dart');
      expect(desktop, contains('Future<bool> openUrl(String url)'));
      final nulls = _read('app/auradsp_app/lib/core/ports/null_ports.dart');
      expect(nulls, contains('Future<bool> openUrl(String url) async => false'));
    });

    test('_CatBar 图标表与分类数对齐（防 RangeError 回归）', () {
      final sections =
          _read('app/auradsp_app/lib/features/settings/panels/sections.dart');
      final m = RegExp(r'static const _icons = \[([^\]]*)\]').firstMatch(sections);
      expect(m, isNotNull);
      final count = 'Icons.'.allMatches(m!.group(1)!).length;
      expect(count, greaterThanOrEqualTo(5),
          reason: '_CatBar._icons 必须覆盖全部分类（含关于=4）');
    });

    test('左栏底部单行形态标签，旧两行不回归', () {
      final shell = _read('app/auradsp_app/lib/features/shell.dart');
      expect(shell, contains('PlatformProfile.formLabel'));
      expect(shell, isNot(contains('ENGINES · DESKTOP')));
      expect(shell, isNot(contains('deviceRate')));
      final profile =
          _read('app/auradsp_app/lib/platform/platform_profile.dart');
      expect(profile, contains('get formLabel'));
      expect(profile, contains("'Macbook'"));
      expect(profile, contains("'Android'"));
    });
  });
}
