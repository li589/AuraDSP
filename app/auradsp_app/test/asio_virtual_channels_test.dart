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
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 虚拟 ASIO 形态的模型：ASIO 范式 + 虚拟子形态 + asio 链。
AppModel _virtualAsio() {
  final m = AppModel(testing: true);
  m.config.modeCategory = AudioModes.categoryAsio;
  m.config.asioFlavor = AudioModes.asioVirtual;
  m.config.pipelineInput = AudioModes.inputAsioDriver;
  m.audioMode = 'asio';
  // App 自身引擎镜像：虚拟形态下不参与处理，恒为 2。
  m.channelsCount = 2;
  m.channelsCountMode = 0;
  return m;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('ASIO Client 形态不受影响', () {
    test('Client 形态仍由 isolate 协商供给（状态侧不合成宽度）', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);
      m.config.modeCategory = AudioModes.categoryAsio;
      m.config.asioFlavor = AudioModes.asioClient;
      m.audioMode = 'asio';
      m.asioDriverChannels = 8;
      // Client 形态：能力 null → 自动档回落 App 引擎镜像。
      expect(m.displayChannelCount, m.effectiveChannelCount);
    });
  });
}
