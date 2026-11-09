// 安装版布局工具定位契约（2026-11-09，V-01/V-03 修复 F1）。
//
// 真机报告的共同根因：app 按源码树相对路径找脚本/工具，安装版是
// 扁平 driver/ 布局 → 全部落空。本测试以源码不变式钉住收口口径：
//   1. 四组工具（VAIO 安装脚本 / ASIO 注册脚本 / APO 配置脚本 /
//      端点探测 exe）一律随包定位（findInstalledFile）优先、
//      源码树（findRepoFile）兜底；
//   2. 随包定位以可执行文件目录为基准（Platform.resolvedExecutable），
//      不依赖 Directory.current；
//   3. 命令按脚本类型分支：随包 VAIO 脚本不传 -Config，随包 ASIO
//      脚本走 -Unregister 开关口径；
//   4. refreshAudioDevices 全程守卫且工具缺失显式报错（F0/V-02）。
import 'dart:io';

import 'package:auradsp_app/core/ports/null_ports.dart';
import 'package:auradsp_app/platform/system/windows_system_tools.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String relPath) {
  for (final base in const ['', '../', '../../']) {
    final f = File('$base$relPath');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $relPath（cwd=${Directory.current.path}）');
}

void main() {
  final state = _read('app/auradsp_app/lib/core/state/state_audio_modes.dart');
  final tools =
      _read('app/auradsp_app/lib/platform/system/windows_system_tools.dart');
  final port = _read('app/auradsp_app/lib/platform/port/windows_system.dart');

  group('随包定位优先于源码树', () {
    test('四组工具的随包候选先于源码树候选出现', () {
      final pairs = <List<String>>[
        ['driver/install_vaio.ps1', '01_vaio_driver/install_driver.ps1'],
        ['driver/register_asio.ps1', '04_asio_driver/register_driver.ps1'],
        ['driver/apo_config.py', '03_system_apo/apo_config.py'],
        [
          'driver/apo_inspect.exe',
          'windows-drivers/out/Release/apo_inspect.exe'
        ],
      ];
      for (final p in pairs) {
        final bi = state.indexOf(p[0]);
        final ri = state.indexOf(p[1]);
        expect(bi, greaterThanOrEqualTo(0), reason: '缺随包候选 ${p[0]}');
        expect(ri, greaterThanOrEqualTo(0), reason: '缺源码树候选 ${p[1]}');
        expect(bi, lessThan(ri), reason: '${p[0]} 必须先于 ${p[1]} 被查找');
      }
      expect(state, contains('findInstalledFile'));
    });

    test('port 声明 findInstalledFile，实现以可执行文件目录为基准', () {
      expect(port, contains('findInstalledFile'));
      expect(tools, contains('findInstalledFile'));
      expect(tools, contains('Platform.resolvedExecutable'));
    });

    test('非 Windows 实现恒返回 null（定位不泄漏到其它平台）', () {
      expect(const NullWindowsSystem().findInstalledFile(const ['x']), isNull);
      if (!Platform.isWindows) {
        expect(
            const WindowsSystemTools().findInstalledFile(const ['x']), isNull);
      }
    });
  });

  group('命令按脚本类型分支', () {
    test('vaioDriver 带 bundled 分支且 -Config 只在非随包口径拼接', () {
      expect(tools, contains('bool bundled = false'));
      // 提权分支：bundled 时尾巴为空串而非 -Config
      expect(tools, contains("bundled ? '' : \", '-Config', 'Release'\""));
      // 非提权分支：-Config 受 !bundled 守卫
      expect(tools, contains("if (!bundled) ...['-Config', 'Release']"));
    });

    test('随包 ASIO 走 -Unregister 开关口径', () {
      expect(tools, contains("'-Unregister'"));
      expect(tools, contains("if (!register) '-Unregister'"));
    });
  });

  group('V-02 刷新链守卫（F0）', () {
    test('refreshAudioDevices 有埋点且工具缺失显式置错', () {
      expect(state, contains("dbgLog('devices.refresh: start')"));
      expect(state, contains('端点探测工具不可用'));
    });

    test('inspectAudioDevices 带超时', () {
      expect(tools, contains('.timeout(const Duration(seconds: 10))'));
    });
  });
}
