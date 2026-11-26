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
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/engine/audio_isolate.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/platform/port/registry.dart';
import 'package:auradsp_app/platform/platform_profile.dart';
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

class _IsoCommands {
  final ReceivePort _port = ReceivePort();
  final List<Map<String, dynamic>> sent = [];
  late final StreamSubscription<dynamic> _subscription;

  _IsoCommands(AppModel model) {
    _subscription = _port.listen((raw) {
      if (raw is Map) sent.add(Map<String, dynamic>.from(raw));
    });
    model.handleMessageForTesting({'evt': 'isoReady', 'port': _port.sendPort});
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> close() async {
    await _subscription.cancel();
    _port.close();
  }

  List<int> get channelCapabilities => [
        for (final command in sent)
          if (command['cmd'] == 'chcap') (command['ch'] as num).toInt(),
      ];

  List<int> get requestSeqs => [
        for (final command in sent)
          if (command['cmd'] == 'asioRequestSeq')
            (command['requestSeq'] as num).toInt(),
      ];
}

Map<String, dynamic> _paramsEvt({
  required int channelsCount,
  int channelsCountMode = 1,
}) =>
    {
      'evt': 'params',
      'bassEnable': 0,
      'bassGain': 0.0,
      'reverbPreset': -1,
      'stereoMix': 0.0,
      'eqEnable': 0,
      'postGain': 0.0,
      'limiterEnable': 1,
      'lpEnable': 0,
      'lpStatus': 0,
      'convEnable': 0,
      'convReady': 0,
      'convFrames': 0,
      'convChannels': 2,
      'convSrcRate': 48000,
      'convPeak': 0.0,
      'tubeEnable': 0,
      'xfeedEnable': 0,
      'stereoBandUsed': 0,
      'convMix': 1.0,
      'shelfEnable': 0,
      'shelfFreq': 0.0,
      'shelfGain': 0.0,
      'channelsCount': channelsCount,
      'channelsCountMode': channelsCountMode,
    };

Map<String, dynamic> _vizEvt(int channelCount) => {
      'evt': 'viz',
      'backend': 'asio',
      'ts': DateTime.now().millisecondsSinceEpoch,
      'spectrum': List<double>.filled(32, 0.0),
      'eqIn': List<double>.filled(32, 0.0),
      'l': -90.0,
      'r': -90.0,
      'chCount': channelCount,
      'chLevels': List<double>.filled(channelCount, -120.0),
      'stageCh': List<double>.filled(kVizStageTelemetry * channelCount, -120.0),
    };

Map<String, dynamic> _asioStatusEvt({
  required int dawCh,
  int? requestSeq,
  int version = 4,
  bool running = true,
  bool? driverRunning,
  int writerPid = 100,
  int frames = 100,
}) =>
    {
      'evt': 'asiostatus',
      'version': version,
      'writerPid': writerPid,
      'requestSeq': ?requestSeq,
      'running': running,
      'driverRunning': driverRunning ?? running,
      'dawSeen': 1,
      'dawActive': running ? 1 : 0,
      'dawFrames': frames,
      'dawCh': dawCh,
    };

Map<String, dynamic> _readyEvt() => {
      'evt': 'ready',
      'abi': 1,
      'version': 'test',
      'deviceRate': 48000,
      'deviceCh': 2,
      'bufferFrames': 512,
      'latencyMs': 0.0,
    };

class _ScriptedTelemetryWords {
  _ScriptedTelemetryWords(this.words);

  final Map<int, List<int>> words;
  final Map<int, int> _reads = {};

  int read(int index) {
    final values = words[index];
    if (values == null || values.isEmpty) {
      throw StateError('unexpected telemetry word read at $index');
    }
    final readIndex = _reads[index] ?? 0;
    _reads[index] = readIndex + 1;
    return values[readIndex];
  }
}

AsioTelemetrySnapshot? _readScriptedSnapshot(_ScriptedTelemetryWords words) =>
    AsioTelemetrySnapshot.tryRead(
      readU32: words.read,
      readI32: words.read,
      readF32: (_) => 0,
      readEndpointId: () => '',
    );

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

  group('ASIO telemetry coherent snapshot', () {
    test('旧 running=1 + 新 token 的跨代读取被拒绝', () {
      final words = _ScriptedTelemetryWords({
        0: [0x54444141, 0x54444141],
        1: [4, 4],
        2: [100, 100],
        3: [1, 1],
        4: [10, 10],
        5: [48000, 48000],
        6: [2, 2],
        7: [512, 512],
        8: [100, 100],
        9: [0, 0],
        12: [7, 7],
        14: [48000, 48000],
        16: [0, 0],
        17: [0, 0],
        146: [41, 42],
      });

      expect(_readScriptedSnapshot(words), isNull);
    });

    test('writerPid 交叉的遥测快照被拒绝', () {
      final words = _ScriptedTelemetryWords({
        0: [0x54444141, 0x54444141],
        1: [4, 4],
        2: [100, 200],
        3: [1, 1],
        4: [10, 10],
        5: [48000, 48000],
        6: [2, 2],
        7: [512, 512],
        8: [100, 100],
        9: [0, 0],
        12: [7, 7],
        14: [48000, 48000],
        16: [0, 0],
        17: [0, 0],
        146: [42, 42],
      });

      expect(_readScriptedSnapshot(words), isNull);
    });

    test('稳定 v4 快照保留 token、writerPid 与 stopped 状态', () {
      final words = _ScriptedTelemetryWords({
        0: [0x54444141, 0x54444141],
        1: [4, 4],
        2: [100, 100],
        3: [0, 0],
        4: [10, 10],
        5: [48000, 48000],
        6: [2, 2],
        7: [512, 512],
        8: [100, 100],
        9: [0, 0],
        12: [7, 7],
        14: [48000, 48000],
        16: [0, 0],
        17: [0, 0],
        146: [42, 42],
      });

      final snapshot = _readScriptedSnapshot(words);
      expect(snapshot, isNotNull);
      expect(snapshot!.version, 4);
      expect(snapshot.writerPid, 100);
      expect(snapshot.requestSeq, 42);
      expect(snapshot.running, isFalse);
      expect(snapshot.dawCh, 2);
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

    test('未确认请求 8 压过活跃旧 2ch 流与迟到 viz', () {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};
      m.noteStreamChannelCount(2);
      m.vizChannelCount.value = 2;
      expect(m.displayChannelCount, 2);

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);

      // 旧实例仍在持续供帧时，迟到 2ch viz 不得把显示钉回 2。
      m.handleMessageForTesting(_vizEvt(2));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
    });

    test('每次虚拟档位请求都发布单调递增的 requestSeq', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();

      final seqs = commands.requestSeqs;
      expect(seqs, hasLength(3));
      expect(seqs.first, greaterThan(0));
      expect(seqs[1], seqs[0] + 1);
      expect(seqs[2], seqs[1] + 1);
      expect(registry.dwordWrites.map((write) => write.value), [8, 4, 8]);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8, 4, 8],
      );
    });

    test('迟到同宽旧 token 不确认，后续旧 2ch 也不覆盖请求 8', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 200, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final oldToken = commands.requestSeqs[0];
      final newToken = commands.requestSeqs[1];

      m.handleMessageForTesting(
          _asioStatusEvt(dawCh: 8, requestSeq: oldToken, frames: 201));
      expect(m.displayChannelCount, 8);
      m.handleMessageForTesting(
          _asioStatusEvt(dawCh: 2, requestSeq: oldToken, frames: 202));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);
      expect(newToken, greaterThan(oldToken));
    });

    test('旧宽度 + 旧 token 的重启回退仍不能确认请求 8', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final oldToken = commands.requestSeqs.first;

      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        running: false,
        frames: 101,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        frames: 1,
      ));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);
    });

    test('匹配的新 token 无需重启/回退证据即可确认请求', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final newToken = commands.requestSeqs.last;

      // 没有 stop，也没有 processedFrames 回退；精确 token 才是确认依据。
      m.handleMessageForTesting(
          _asioStatusEvt(dawCh: 8, requestSeq: newToken, frames: 101));
      // 确认后，后续真实协商宽度重新成为真源。
      m.handleMessageForTesting(
          _asioStatusEvt(dawCh: 2, requestSeq: newToken, frames: 102));
      expect(m.displayChannelCount, 2);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [4, 8],
      );
    });

    test('旧 running=1 + 新 token 不确认，停启 epoch 后才接受 dawCh', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      await commands.flush();
      final oldToken = commands.requestSeqs.last;
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        writerPid: 100,
        frames: 100,
      ));
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final newToken = commands.requestSeqs.last;

      // 同一 writer 在旧泵仍 running 时暴露新 token：几何可能仍属旧实例。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: newToken,
        writerPid: 100,
        frames: 101,
      ));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);

      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: newToken,
        writerPid: 100,
        running: false,
        frames: 102,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 6,
        requestSeq: newToken,
        writerPid: 100,
        frames: 1,
      ));
      expect(m.displayChannelCount, 6);
      expect(m.vizChannelCount.value, 6);
    });

    test('迟到旧 token 的同 writer 不充当新 writerPid', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final oldToken = commands.requestSeqs.first;
      final newToken = commands.requestSeqs.last;

      // 请求发生后才迟到的旧 token 仍证明该 writer 早已存在。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        writerPid: 100,
        frames: 101,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: newToken,
        writerPid: 100,
        frames: 102,
      ));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);

      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: newToken,
        writerPid: 100,
        running: false,
        frames: 103,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 6,
        requestSeq: newToken,
        writerPid: 100,
        frames: 1,
      ));
      expect(m.displayChannelCount, 6);
    });

    test('新 writerPid 可确认 token，重叠旧 writer 不污染已确认几何', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      await commands.flush();
      final oldToken = commands.requestSeqs.last;
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        writerPid: 100,
        frames: 100,
      ));
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final token = commands.requestSeqs.last;

      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: token,
        writerPid: 100,
        frames: 101,
      ));
      expect(m.displayChannelCount, 8);
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 6,
        requestSeq: token,
        writerPid: 200,
        frames: 1,
      ));
      expect(m.displayChannelCount, 6);

      // 旧 writer 再次出现在共享块里也不能把已确认的新几何拖回 2ch。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: token,
        writerPid: 100,
        frames: 102,
      ));
      expect(m.displayChannelCount, 6);
      expect(m.vizChannelCount.value, 6);
    });

    test('重叠 writer 跨请求保留身份，迟到旧 token 不改写当前历史', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 100, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      await commands.flush();
      final firstToken = commands.requestSeqs.last;
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: firstToken,
        writerPid: 100,
        frames: 100,
      ));
      expect(m.displayChannelCount, 2);

      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final secondToken = commands.requestSeqs.last;
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 6,
        requestSeq: secondToken,
        writerPid: 200,
        frames: 1,
      ));
      expect(m.displayChannelCount, 6);

      // T1 的迟到事件只能登记 writer 身份，不能替换 T2 的当前历史。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: firstToken,
        writerPid: 100,
        frames: 101,
      ));
      expect(m.displayChannelCount, 6);

      expect(m.setAsioDriverChannels(4), isTrue);
      await commands.flush();
      final thirdToken = commands.requestSeqs.last;

      // writer200 在 T3 前已存在；仅有 running 上升不足以构成新 epoch。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: thirdToken,
        writerPid: 200,
        frames: 102,
      ));
      expect(m.displayChannelCount, 4);
      expect(m.vizChannelCount.value, 4);

      // 精确 token 配合当前请求内观察到的 stopped→started 仍可确认。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: thirdToken,
        writerPid: 200,
        running: false,
        frames: 103,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 6,
        requestSeq: thirdToken,
        writerPid: 200,
        frames: 1,
      ));
      expect(m.displayChannelCount, 6);
      expect(m.vizChannelCount.value, 6);
    });

    test('断线时请求在 isoReady 重放，且先于 asiomode', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);

      expect(m.setAsioDriverChannels(8), isTrue);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      await commands.flush();

      expect(commands.requestSeqs, hasLength(1));
      final token = commands.requestSeqs.single;
      expect(token, greaterThan(0));
      expect(registry.dwordWrites.map((write) => write.value), [8]);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );

      m.handleMessageForTesting(_readyEvt());
      await commands.flush();
      final tokenIndex = commands.sent.indexOf(
          commands.sent.firstWhere((m) => m['cmd'] == 'asioRequestSeq'));
      final modeIndex = commands.sent
          .indexOf(commands.sent.firstWhere((m) => m['cmd'] == 'asiomode'));
      expect(tokenIndex, lessThan(modeIndex));
    });

    test('手动 isolate 重启重放同一未确认 token，不重复档位派发', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      final first = _IsoCommands(m);
      addTearDown(first.close);

      expect(m.setAsioDriverChannels(8), isTrue);
      await first.flush();
      final token = first.requestSeqs.single;
      expect(token, greaterThan(0));

      final restarted = _IsoCommands(m);
      addTearDown(restarted.close);
      await restarted.flush();
      expect(restarted.requestSeqs, [token]);

      m.handleMessageForTesting(_readyEvt());
      await restarted.flush();
      final commands = restarted.sent.map((m) => m['cmd']).toList();
      expect(commands.indexOf('asioRequestSeq'),
          lessThan(commands.indexOf('asiomode')));
      expect(registry.dwordWrites.map((write) => write.value), [8]);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
    });

    test('同实例 stop/start 保留旧 token，帧回退不再误确认', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 300, 'dawCh': 2};

      expect(m.setAsioDriverChannels(4), isTrue);
      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final oldToken = commands.requestSeqs.first;

      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        running: false,
        frames: 301,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: oldToken,
        frames: 1,
      ));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);
    });

    test('新实例匹配 token 且协商 6ch 时确认并同步 8→6 能力', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 300, 'dawCh': 2};
      m.noteStreamChannelCount(2);
      m.vizChannelCount.value = 2;

      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final newToken = commands.requestSeqs.single;
      m.handleMessageForTesting(_vizEvt(2));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);

      // token 虽已匹配，泵尚未 running 时不得采信块里残留的旧 dawCh。
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 2,
        requestSeq: newToken,
        running: false,
        frames: 301,
      ));
      expect(m.displayChannelCount, 8);
      m.handleMessageForTesting(_asioStatusEvt(
        dawCh: 6,
        requestSeq: newToken,
        frames: 1,
      ));
      await commands.flush();

      expect(m.displayChannelCount, 6);
      expect(m.vizChannelCount.value, 6);
      expect(
        commands.channelCapabilities,
        PlatformProfile.isWindows ? [8, 6] : isEmpty,
      );
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
    });

    test('旧 telemetry v3 无 token，重启回退不能确认请求', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 400, 'dawCh': 2};

      expect(m.setAsioDriverChannels(8), isTrue);
      m.handleMessageForTesting(_asioStatusEvt(
        version: 3,
        dawCh: 2,
        running: false,
        frames: 401,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        version: 3,
        dawCh: 2,
        frames: 1,
      ));
      expect(m.displayChannelCount, 8);
    });

    test('旧 telemetry v3 即使夹带匹配 token 也必须忽略', () async {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      final commands = _IsoCommands(m);
      addTearDown(commands.close);
      addTearDown(m.dispose);
      m.asioActive = true;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 1, 'dawFrames': 500, 'dawCh': 2};

      expect(m.setAsioDriverChannels(8), isTrue);
      await commands.flush();
      final newToken = commands.requestSeqs.single;
      m.handleMessageForTesting(_asioStatusEvt(
        version: 3,
        dawCh: 2,
        requestSeq: newToken,
        running: false,
        frames: 501,
      ));
      m.handleMessageForTesting(_asioStatusEvt(
        version: 3,
        dawCh: 2,
        requestSeq: newToken,
        frames: 1,
      ));
      expect(m.displayChannelCount, 8);
      expect(m.vizChannelCount.value, 8);
    });

    test('virtual→Client→driver4→virtual 不复活旧请求', () {
      final registry = _FakeRegistry();
      final m = _virtualAsio(registry: registry);
      addTearDown(m.dispose);
      m.asioActive = false;
      m.asioInfo = {'dawSeen': 1, 'dawActive': 0, 'dawCh': 2};

      expect(m.setAsioDriverChannels(8), isTrue);
      expect(m.displayChannelCount, 8);

      m.setAsioFlavor(AudioModes.asioClient);
      expect(m.setAsioDriverChannels(4), isTrue);
      m.setAsioFlavor(AudioModes.asioVirtual);

      expect(m.asioDriverChannels, 4);
      expect(m.displayChannelCount, 4);
      expect(m.vizChannelCount.value, 4);
      expect(
        m.sentParamsForTesting
            .where((m) => m['id'] == 'channels.count')
            .map((m) => m['value']),
        [8],
      );
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

      // 引擎基线仍是 2ch/fixed；未确认的驱动档位 8 必须压过旧回读。
      m.handleMessageForTesting(_paramsEvt(channelsCount: 2));
      expect(m.channelsCount, 8);
      expect(m.config.channelsCount, 8);

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
