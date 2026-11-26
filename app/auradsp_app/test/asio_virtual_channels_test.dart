// asio_virtual_channels_test.dart — 虚拟 ASIO 声道宽度口径回归
// （真机 2026-11-21：设 7.1 被自动调回 2.0，可视化/电平与实际处理宽度
//  一起塌成 2；VAIO 模式不受影响）。
//
// 根因两条，本组各钉一处：
//   1) 虚拟形态下 App 自身引擎不参与处理（DAW 进程内实例才是处理者），
//      而 displayChannelCount 的自动档只看 App 引擎镜像（常年 2）——
//      宽度必须取自驱动档位 / DAW 协商值。
//   2) 驱动遥测块跨 DAW 会话驻留，块里留着上次会话的 dawCh。只要块在
//      就采信会把档位改动钉死在残留值上，因此只有 DAW 活跃时才认
//      dawCh，其余用档位镜像。
import 'dart:io';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/platform/port/registry.dart';
import 'package:auradsp_app/ui/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRegistry implements RegistryPort {
  final List<({String keyPath, String valueName, int value})> dwordWrites = [];

  @override
  bool get available => true;

  @override
  bool keyExists(String keyPath) => true;

  @override
  String? readString(String keyPath, String valueName) => null;

  @override
  List<String> readStringValues(
    String keyPath, {
    String? valueName,
    bool recursive = true,
  }) => const [];

  @override
  bool writeString(String keyPath, String valueName, String value) => true;

  @override
  int? readDword(String keyPath, String valueName) => null;

  @override
  bool writeDword(String keyPath, String valueName, int value) {
    dwordWrites.add((keyPath: keyPath, valueName: valueName, value: value));
    return true;
  }

  @override
  bool deleteValue(String keyPath, String valueName) => true;
}

/// 虚拟 ASIO 形态的模型：ASIO 范式 + 虚拟子形态 + asio 链。
AppModel _virtualAsio({RegistryPort? registry}) {
  final m = AppModel(testing: true, registry: registry);
  m.config.modeCategory = AudioModes.categoryAsio;
  m.config.asioFlavor = AudioModes.asioVirtual;
  m.config.pipelineInput = AudioModes.inputAsioDriver;
  m.config.pipelineOutput = AudioModes.outputAsioClient;
  m.audioMode = 'asio';
  // App 自身引擎镜像：虚拟形态下不参与处理，恒为 2。
  m.channelsCount = 2;
  m.channelsCountMode = 0;
  return m;
}

Widget _app(AppModel model) => MaterialApp(
  theme: withAuraExtension(ThemeData.dark(), auraDark),
  locale: model.locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(body: SettingsPage(model: model)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('asio_virtual_channels_');
    ConfigManager.baseDirOverride = tempDir!.path;
  });
  tearDown(() {
    ConfigManager.baseDirOverride = null;
    try {
      tempDir?.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('虚拟 ASIO：显示宽度取驱动档位（自动档）', () {
    test('档位 7.1 → 显示 8，不再跟随 App 引擎镜像的 2', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.asioDriverChannels = 8;
      expect(m.displayChannelCount, 8);
    });

    test('档位 5.1 / 4.0 同口径', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.asioDriverChannels = 6;
      expect(m.displayChannelCount, 6);
      m.asioDriverChannels = 4;
      expect(m.displayChannelCount, 4);
    });

    test('档位 2 → 显示 2（能力上限真实生效，不是硬抬 8）', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.asioDriverChannels = 2;
      expect(m.displayChannelCount, 2);
    });

    test('refreshDisplayChannelCount 把档位宽度推入 vizChannelCount', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.asioDriverChannels = 8;
      m.refreshDisplayChannelCount();
      expect(m.vizChannelCount.value, 8);
    });
  });

  group('虚拟 ASIO：手动档位受档位能力钳制', () {
    test('手动 7.1 + 档位 7.1 → 8', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.channelsCountMode = 1;
      m.channelsCount = 8;
      m.asioDriverChannels = 8;
      expect(m.displayChannelCount, 8);
    });

    test('手动 7.1 + 档位 2 → 钳到 2（驱动只报 2 时不能假装 8）', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.channelsCountMode = 1;
      m.channelsCount = 8;
      m.asioDriverChannels = 2;
      expect(m.displayChannelCount, 2);
    });
  });

  group('虚拟 ASIO：DAW 协商值只在活跃时采信', () {
    test('DAW 活跃 → 用协商宽度', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.asioDriverChannels = 8;
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawCh': 6};
      expect(m.displayChannelCount, 6);
    });

    test('残留遥测（DAW 已离场）→ 回落档位，不被旧 dawCh 钉死', () {
      final m = _virtualAsio();
      addTearDown(m.dispose);
      m.asioDriverChannels = 8;
      m.asioActive = false;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 0, 'dawCh': 2};
      expect(m.displayChannelCount, 8);
    });
  });

  group('H5：虚拟驱动档位统一参数派发', () {
    test('驱动档位 8 只写一次注册表并派发一次 typed channels.count', () {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(registry.dwordWrites, [
        (
          keyPath: r'HKCU\SOFTWARE\AuraDSP\AsioDriver',
          valueName: 'Channels',
          value: 8,
        ),
      ]);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
      final sent = m.sentParamsForTesting.lastWhere(
        (m) => m['id'] == 'channels.count',
      );
      expect(sent['isFloat'], isFalse);
      expect(m.asioDriverChannels, 8);
      expect(m.channelsCount, 8);
      expect(m.config.channelsCount, 8);
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);
    });

    test('工作声道 setter 保持一次注册表写入和一次 channels.count 派发', () {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);

      m.setChannelsCount(8);

      expect(registry.dwordWrites.map((write) => write.value), [8]);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
      expect(m.asioDriverChannels, 8);
      expect(m.channelsCount, 8);
      expect(m.config.channelsCount, 8);
      expect(m.displayChannelCount, 8);
    });

    test('活跃旧 dawCh=2 不钉死请求 8，匹配新遥测后才接受后续协商', () {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawCh': 2};
      expect(m.displayChannelCount, 2);

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);

      // 请求后到达的旧实例回声仍然不能覆盖新档位。
      m.handleMessageForTesting({
        'evt': 'asiostatus',
        'running': true,
        'dawSeen': 1,
        'dawActive': 1,
        'dawFrames': 10,
        'dawCh': 2,
      });
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);

      // 新档位的首次匹配遥测确认请求已生效。
      m.handleMessageForTesting({
        'evt': 'asiostatus',
        'running': true,
        'dawSeen': 1,
        'dawActive': 1,
        'dawFrames': 11,
        'dawCh': 8,
      });
      expect(m.displayChannelCount, 8);

      // 确认后的实际协商值重新成为真源。
      m.handleMessageForTesting({
        'evt': 'asiostatus',
        'running': true,
        'dawSeen': 1,
        'dawActive': 1,
        'dawFrames': 12,
        'dawCh': 6,
      });
      expect(m.displayChannelCount, 6);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
    });

    test('新请求代际不被上一请求的迟到匹配遥测确认', () {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawCh': 2};

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.displayChannelCount, 4);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8, 4],
      );

      m.handleMessageForTesting({
        'evt': 'asiostatus',
        'running': true,
        'dawSeen': 1,
        'dawActive': 1,
        'dawFrames': 20,
        'dawCh': 8,
      });
      expect(m.displayChannelCount, 4);

      m.handleMessageForTesting({
        'evt': 'asiostatus',
        'running': true,
        'dawSeen': 1,
        'dawActive': 1,
        'dawFrames': 21,
        'dawCh': 4,
      });
      expect(m.displayChannelCount, 4);

      m.handleMessageForTesting({
        'evt': 'asiostatus',
        'running': true,
        'dawSeen': 1,
        'dawActive': 1,
        'dawFrames': 22,
        'dawCh': 6,
      });
      expect(m.displayChannelCount, 6);
      expect(registry.dwordWrites.map((write) => write.value), [8, 4]);
    });

    testWidgets('VM-04：矩阵/离散往返后两个 UI 控件仍同为 8', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      m.setChannelsCountMode(1);
      expect(m.setAsioDriverChannels(8), isTrue);

      await tester.pumpWidget(_app(m));
      await tester.pumpAndSettle();

      final driverDropdown = find.byWidgetPredicate(
        (widget) =>
            widget is AuraDropdown<int> &&
            widget.items.length == 4 &&
            widget.items.every(
              (item) => const {2, 4, 6, 8}.contains(item.value),
            ),
      );
      final countSegments = find.byWidgetPredicate(
        (widget) =>
            widget is AuraSegmented<int> &&
            widget.segments.length == 5 &&
            widget.segments.first.value == 0 &&
            widget.segments.last.value == 8,
      );

      void expectUnifiedWidth() {
        expect(tester.widget<AuraDropdown<int>>(driverDropdown).value, 8);
        expect(tester.widget<AuraSegmented<int>>(countSegments).selected, 8);
        expect(m.asioDriverChannels, 8);
        expect(m.channelsCount, 8);
        expect(m.config.channelsCount, 8);
        expect(m.displayChannelCount, 8);
        expect(m.vizChannelCount.value, 8);
        expect(
          m.sentParamsForTesting
              .where((m) => m['id'] == 'channels.count')
              .map((m) => m['value']),
          [8],
        );
      }

      expectUnifiedWidth();
      final discrete = find.text('离散逐声道');
      await tester.ensureVisible(discrete);
      await tester.tap(discrete);
      await tester.pumpAndSettle();
      expect(m.channelsMode, 1);
      expectUnifiedWidth();

      final matrix = find.text('矩阵下混');
      await tester.ensureVisible(matrix);
      await tester.tap(matrix);
      await tester.pumpAndSettle();
      expect(m.channelsMode, 0);
      expectUnifiedWidth();
      expect(registry.dwordWrites.map((write) => write.value), [8]);
    });
  });

  group('ASIO Client 形态不受影响', () {
    test('Client 形态仍由 isolate 协商供给（状态侧不合成宽度）', () {
      final registry = _FakeRegistry();
      final m = AppModel(testing: true, registry: registry);
      addTearDown(m.dispose);
      m.config.modeCategory = AudioModes.categoryAsio;
      m.config.asioFlavor = AudioModes.asioClient;
      m.audioMode = 'asio';

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(m.asioDriverChannels, 8);
      expect(m.channelsCount, 2);
      expect(m.config.channelsCount, 2);
      expect(
        m.sentParamsForTesting.where((m) => m['id'] == 'channels.count'),
        isEmpty,
      );
      // Client 形态：能力 null → 自动档回落 App 引擎镜像。
      expect(m.displayChannelCount, m.effectiveChannelCount);
    });
  });
}
