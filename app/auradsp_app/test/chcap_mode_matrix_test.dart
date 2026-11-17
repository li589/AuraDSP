// chcap_mode_matrix_test.dart — 第四十五轮 S2/S3：分模式声道
// 能力矩阵（状态侧唯一权威 _capabilityChForMode，经显示钳制面
// displayChannelCount 观测——与 isolate 生效口径同源）。
//
// 背景：r44 把桥 viz 流几何喂进钳制器形成棘轮死锁（VAIO 切
// 7.1 回 2.0、5.1 后回不去）。r45 能力只认设备事实：
// sysapo=选中端点 / vb=协商 / capture 链=min{入，出} /
// vaio 链=min{8, 输出端点} / asio 与 auto 不由状态侧钳。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/platform/platform_profile.dart';

const _in20 = '{0.0.1.00000000}.{aaaaaaa1-0000-0000-0000-000000000001}';
const _out20 = '{0.0.0.00000000}.{bbbbbbb2-0000-0000-0000-000000000002}';
const _out71 = '{0.0.0.00000000}.{ccccccc3-0000-0000-0000-000000000003}';

AppModel _vaioModel({String outName = '', int outCh = 0}) {
  final m = AppModel(testing: true);
  m.audioMode = 'vaio';
  m.config.audioMode = 'vaio';
  m.config.modeCategory = 'pipeline';
  m.config.pipelineInput = 'vaio';
  m.config.pipelineOutput = 'vaio';
  m.config.vaioOutputEndpoint = outName;
  m.wasapiDevices = outName.isEmpty
      ? const []
      : [
          AudioDeviceItem(
              id: _out71, name: outName, isRender: true, ch: outCh),
        ];
  m.setChannelsCountMode(1);
  return m;
}

void main() {
  if (!PlatformProfile.isWindows) {
    test('non-windows: capability matrix is windows-scoped', () {
      expect(PlatformProfile.isWindows, isFalse);
    });
    return;
  }
  group('第四十五轮 S2：分模式声道能力矩阵', () {
    test('VAIO 未选输出端点：本体 8，不钳（症状 1 回归）', () {
      final m = _vaioModel();
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 8);
    });

    test('VAIO 输出端点双声道：按输出 min 钳到 2', () {
      final m = _vaioModel(outName: 'Stereo Speakers', outCh: 2);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 2);
    });

    test('VAIO 输出端点 7.1：设 8 得 8、设 6 得 6（症状 3 回归）', () {
      final m = _vaioModel(outName: '7.1 Speakers', outCh: 8);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 8);
      m.setChannelsCount(6);
      expect(m.displayChannelCount, 6);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 8);
    });

    test('capture 链（WASAPI 入+出）：取两设备 min', () {
      final m = AppModel(testing: true);
      m.audioMode = 'vaio'; // 管线合成模式 id（链由 in/out 决定）
      m.config.audioMode = 'vaio';
      m.config.modeCategory = 'pipeline';
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineOutput = 'wasapi';
      m.config.pipelineInputDevice = _in20;
      m.config.pipelineOutputDevice = _out71;
      m.wasapiDevices = const [
        AudioDeviceItem(id: _in20, name: 'In', isRender: false, ch: 2),
        AudioDeviceItem(id: _out71, name: 'Out', isRender: true, ch: 8),
      ];
      m.setChannelsCountMode(1);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 2); // 入侧 2 为低
      // 入换 8、出换 6：低侧轮到输出。
      m.config.pipelineOutputDevice = _out20;
      m.wasapiDevices = const [
        AudioDeviceItem(id: _in20, name: 'In', isRender: false, ch: 8),
        AudioDeviceItem(id: _out20, name: 'Out', isRender: true, ch: 6),
      ];
      expect(m.displayChannelCount, 6);
    });

    test('VB：未协商不钳（8），协商 6 后钳到 6（S3）', () {
      final m = AppModel(testing: true);
      m.audioMode = 'vbcallback';
      m.config.audioMode = 'vbcallback';
      m.config.modeCategory = 'attachment';
      m.setChannelsCountMode(1);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 8);
      m.vbNegotiatedCh = 6;
      expect(m.displayChannelCount, 6);
      m.vbNegotiatedCh = 8;
      expect(m.displayChannelCount, 8);
    });

    test('ASIO 链：状态侧不钳（isolate 预置为真源）', () {
      final m = AppModel(testing: true);
      m.audioMode = 'asio';
      m.config.audioMode = 'asio';
      m.config.modeCategory = 'pipeline';
      m.config.pipelineInput = 'wasapi';
      m.config.pipelineOutput = 'asio_client';
      m.setChannelsCountMode(1);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 8);
    });
  });
}
