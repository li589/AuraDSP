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
        ['driver/apo_config.exe', 'out/Release/apo_config.exe'],
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

    test('APO 工具链零 Python 依赖（2026-11-09 §2.3 方案 A）', () {
      // 真机实证：目标机无 Python 时旧链路（python apo_config.py）
      // 必然失败。钉死 tools 实现不得再以 python 为执行体，且
      // state 定位只认原生 apo_config.exe。
      expect(tools, isNot(contains("'python'")));
      expect(tools, isNot(contains('apo_config.py')));
      expect(state, contains('driver/apo_config.exe'));
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

  group('V-01 检测状态机（F2）', () {
    test('isolate ready 后自动触发一次 VAIO 检测', () {
      final events =
          _read('app/auradsp_app/lib/core/state/state_events.dart');
      final i = events.indexOf("case 'ready':");
      expect(i, greaterThanOrEqualTo(0));
      final window = events.substring(i, i + 6000);
      expect(window, contains('PlatformProfile.supportsBridges'));
      expect(window, contains('refreshVaioDetect()'));
    });

    test('驱动行三态：未检测不显示为未安装', () {
      final hw = _read(
          'app/auradsp_app/lib/features/settings/panels/hardware_drivers.dart');
      expect(hw, contains('det.isNotEmpty'));
      expect(hw, contains('l.setVaioUnknown'));
      expect(hw, contains('if (detected && !found)'));
    });

    test('setVaioUnknown 三语齐全', () {
      for (final lang in const ['zh', 'en', 'ja']) {
        final arb = _read('app/auradsp_app/lib/l10n/app_$lang.arb');
        expect(arb, contains('"setVaioUnknown"'), reason: 'app_$lang.arb');
      }
    });
  });

  group('V-03 接线与静默点（F3）', () {
    final sections =
        _read('app/auradsp_app/lib/features/settings/panels/sections.dart');
    final coreState = _read('app/auradsp_app/lib/core/state.dart');

    test('APO 面板刷新 = 端点 detect + 状态查询合并', () {
      expect(sections, contains('model.refreshVaioDetect();'));
      expect(sections, contains('model.checkApoStatus();'));
    });

    test('VB 内部 token 语义化，不直接外显', () {
      expect(sections, contains('_vbNoteText'));
      expect(sections, contains('l.setVbNotEnabled'));
      expect(sections, contains('no-voicemeeter-remote-dll'));
    });

    test('APO 模式语义说明在面板内明示', () {
      expect(sections, contains('l.apoModeHint'));
    });

    test('静默失败清零：状态查询与 ASIO 注册缺脚本均置错', () {
      expect(state, contains('APO 状态查询失败（脚本无有效输出）'));
      expect(state, contains('未找到 ASIO 注册脚本'));
      expect(state, contains("lastApoError = '未找到 apo_config.exe 驱动管理工具'"));
      // 初始化后台探测保持静默，不攒陈旧报错
      expect(coreState, contains('checkApoStatus(silent: true)'));
    });

    test('新词条三语齐全', () {
      for (final lang in const ['zh', 'en', 'ja']) {
        final arb = _read('app/auradsp_app/lib/l10n/app_$lang.arb');
        expect(arb, contains('"setVbNotEnabled"'), reason: lang);
        expect(arb, contains('"apoModeHint"'), reason: lang);
      }
    });
  });

  group('V-04 设备卡信息架构（F5）', () {
    final hw = _read(
        'app/auradsp_app/lib/features/settings/panels/hardware_drivers.dart');
    final ioOut = _read(
        'app/auradsp_app/lib/features/settings/panels/hardware_io_output.dart');
    final sections =
        _read('app/auradsp_app/lib/features/settings/panels/sections.dart');
    final profile =
        _read('app/auradsp_app/lib/platform/platform_profile.dart');

    test('驱动层恒显示自有驱动状态 + OS 版本，且不含设置控件', () {
      expect(hw, contains('PlatformProfile.osVersion'));
      expect(profile, contains('get osVersion'));
      final start = hw.indexOf('class _DriverLayer');
      final end = hw.indexOf('class _AsioClientDriverRow');
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final layer = hw.substring(start, end);
      // 状态行齐全，且 ASIO Client 设置行已下沉（R4）
      expect(layer, contains('_VaioDriverRow'));
      expect(layer, contains('_VirtualAsioDriverCard'));
      expect(layer, contains('_WasapiDriverRow'));
      expect(layer, isNot(contains('_AsioClientDriverRow(')));
      // 旧的按输入/输出组合裁剪行已消除（R3/R5）
      expect(layer, isNot(contains('pipelineInput ==')));
      expect(layer, isNot(contains('pipelineOutput ==')));
    });

    test('ASIO Client 设置行落在输出层（R5）', () {
      expect(ioOut, contains('_AsioClientDriverRow(model: model)'));
    });

    test('驱动层在范式分支之前组合渲染（R6）', () {
      final di = sections.indexOf('_DriverLayer(model: model)');
      final bi = sections.indexOf('categoryAttachment');
      expect(di, greaterThanOrEqualTo(0));
      expect(bi, greaterThan(di));
      expect(sections, isNot(contains('_PipelineThreeLayerCard')));
    });

    test('注册按钮同行右对齐（R1）', () {
      expect(hw, contains('WrapAlignment.end'));
    });

    test('驱动块版式统一（2026-11-10 用户裁定）：三块与 Linux 面共用 _DriverBlock', () {
      // Windows 三块一律 _DriverBlock（文字左、按钮同行右）
      for (final cls in [
        'class _VaioDriverRow',
        'class _VirtualAsioDriverCard',
        'class _WasapiDriverRow',
      ]) {
        final s = hw.indexOf(cls);
        final e = hw.indexOf('\nclass ', s + 1);
        expect(s, greaterThanOrEqualTo(0), reason: cls);
        expect(hw.substring(s, e < 0 ? hw.length : e),
            contains('return _DriverBlock('),
            reason: cls);
      }
      // ASIO 检测/注销不再有卡底独占行：卡内除 _DriverBlock 的
      // WrapAlignment.end 外不得再出现对齐 Wrap
      final as = hw.indexOf('class _VirtualAsioDriverCard');
      final ae = hw.indexOf('\nclass ', as + 1);
      final card = hw.substring(as, ae < 0 ? hw.length : ae);
      expect(card, isNot(contains('Wrap(')));
      // 按钮顺序（2026-11-10 用户裁定）：注册/注销在左、检测在右；
      // 源码中检测项必须出现在两类动作文案之后。
      final checkIdx = card.indexOf('l.asioStatusCheck');
      expect(checkIdx, greaterThan(card.indexOf('l.setAsioRegisterUac')));
      expect(checkIdx,
          greaterThan(card.indexOf('l.asioDriverActionUnregister')));
      // 统一组件本体在位
      expect(hw, contains('class _DriverBlock extends StatelessWidget'));
      // Linux 设备面同口径：层标题 + 引擎块 + OS 行收尾
      final lp = sections.indexOf('class _LinuxDevicePanel');
      final le = sections.indexOf('Future<void> _editAlsaDevice', lp);
      final linux = sections.substring(lp, le);
      expect(linux, contains('l.driverLayerTitle'));
      expect(linux, contains('_DriverBlock('));
      expect(linux, contains('_InfoRow(l.osVersionLabel'));
      expect(linux.lastIndexOf('_InfoRow(l.osVersionLabel'),
          greaterThan(linux.lastIndexOf('_DriverBlock(')));
    });
  });

  group('V-02 刷新链守卫（F0）', () {
    test('refreshAudioDevices 有埋点且工具缺失显式置错', () {
      expect(state, contains("dbgLog('devices.refresh: start', sync: true)"));
      expect(state, contains('端点探测工具不可用'));
    });

    test('inspectAudioDevices 带超时', () {
      expect(tools, contains('.timeout(const Duration(seconds: 10))'));
    });

    test('刷新链全部埋点保持 sync 形（细审 R-D L9：防节流形静默退化）', () {
      // devices.refresh 全段（state_audio_modes.dart）
      for (final lit in [
        r"dbgLog('devices.refresh: start', sync: true)",
        r"dbgLog('devices.refresh: apo_inspect unavailable', sync: true)",
        r"dbgLog('devices.refresh: inspect exit=${res.exitCode}', sync: true)",
        r"dbgLog('devices.refresh: done n=${items.length}', sync: true)",
        r"dbgLog('devices.refresh: notified', sync: true)",
        r"dbgLog('devices.refresh: no endpoints parsed', sync: true)",
        r"dbgLog('devices.refresh: empty stdout', sync: true)",
        r"dbgLog('devices.refresh: inspect failed', sync: true)",
        r"dbgLog('devices.refresh: error $e', sync: true)",
      ]) {
        expect(state, contains(lit), reason: '缺埋点 $lit');
      }
      // detect 双路 state 发送端（state_vb_asio.dart）
      final vbAsio =
          _read('app/auradsp_app/lib/core/state/state_vb_asio.dart');
      expect(vbAsio,
          contains(r"dbgLog('ui.refreshVaioDetect: send', sync: true)"));
      expect(vbAsio,
          contains(r"dbgLog('ui.refreshAsioDrivers: send', sync: true)"));
      // detect 双路 isolate FFI 前后（audio_isolate.dart）
      final iso = _read('app/auradsp_app/lib/engine/audio_isolate.dart');
      for (final lit in [
        r"dbgLog('vaiodetect: detect begin', sync: true)",
        r"dbgLog('vaiodetect: detect done', sync: true)",
        r"dbgLog('asiodetect: detect begin', sync: true)",
        r"dbgLog('asiodetect: detect done', sync: true)",
      ]) {
        expect(iso, contains(lit), reason: '缺埋点 $lit');
      }
    });
  });

  group('通知组件化接线（④）', () {
    Directory libDir() {
      for (final base in const ['', '../', '../../']) {
        final d = Directory('${base}app/auradsp_app/lib');
        if (d.existsSync()) return d;
      }
      throw StateError('找不到 lib 目录（cwd=${Directory.current.path}）');
    }

    test('全仓 showSnackBar 只许出现在 NoticeHost', () {
      final offenders = <String>[];
      for (final entity in libDir().listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Windows 路径分隔符是反斜杠，先归一再比对白名单，
        // 否则 NoticeHost 自身会被误判为违规（Windows 专属误报）。
        final path = entity.path.replaceAll('\\', '/');
        if (path.endsWith('features/notice_host.dart')) continue;
        if (entity.readAsStringSync().contains('showSnackBar(')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '通知必须经 AppModel.postNotice → NoticeHost 呈现');
    });

    test('PDC 真值同步接线（F2/③）', () {
      final isolate = _read('app/auradsp_app/lib/engine/audio_isolate.dart');
      expect('pluginGetPdcWrap'.allMatches(isolate).length,
          greaterThanOrEqualTo(2));
      expect(isolate, contains("'pluginPdcSync'"));
      final events = _read('app/auradsp_app/lib/core/state/state_events.dart');
      expect(events, contains("case 'pluginPdcSync':"));
      expect(events, contains('NoticeLevel.warning'));
      final slots =
          _read('app/auradsp_app/lib/core/plugins/plugin_manager_slots.dart');
      expect(slots, contains('syncPdcFromEngine'));
    });

    test('NoticeHost 消费通用队列 + main 挂载点已换', () {
      final host = _read('app/auradsp_app/lib/features/notice_host.dart');
      expect(host, contains('takeNotice()'));
      expect(host, contains('hasPendingNotice'));
      final coreState = _read('app/auradsp_app/lib/core/state.dart');
      expect(coreState, contains('void postNotice('));
      final main = _read('app/auradsp_app/lib/main.dart');
      expect(main, contains('NoticeHost(model: model)'));
      expect(main, isNot(contains('EventBanner(')));
    });
  });
}
