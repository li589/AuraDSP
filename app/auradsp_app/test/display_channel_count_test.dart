// display_channel_count_test.dart — 第四十二轮 S3：显示声道数
// 即时合成。主页电平布局/输入门控等显示面只认 vizChannelCount，
// 而它此前仅在音频流动时由 viz 事件更新（静默改设置要等出声）。
// 合成口径：流活跃用流真值；否则手动 = 用户设置（sysapo 按选
// 中端点能力钳制）、自动 + sysapo = 选中端点混音格式、其余 =
// effectiveChannelCount；refresh 经 _notifyUi 收敛推入。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/state.dart';

const _ep71 = '{0.0.0.00000000}.{11111111-2222-3333-4444-555555555555}';
const _ep20 = '{0.0.0.00000000}.{66666666-7777-8888-9999-000000000000}';

AppModel _sysapoModel({required String epId, required int epCh}) {
  final m = AppModel(testing: true);
  m.audioMode = 'sysapo';
  m.config.audioMode = 'sysapo';
  m.apoKnownEndpoints = [
    {'id': epId, 'name': 'Test EP'},
  ];
  m.config.apoTargetEndpoint = epId;
  m.wasapiDevices = [
    AudioDeviceItem(id: epId, name: 'Test EP', isRender: true, ch: epCh),
  ];
  return m;
}

void main() {
  group('第四十二轮 S3：displayChannelCount 合成', () {
    test('手动模式即时反映用户设置（无 viz 事件）', () {
      final m = AppModel(testing: true);
      m.setChannelsCountMode(1);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 8);
      m.setChannelsCount(4);
      expect(m.displayChannelCount, 4);
    });

    test('手动 + sysapo：按选中端点能力钳制（S1 同口径）', () {
      final m = _sysapoModel(epId: _ep20, epCh: 2);
      m.setChannelsCountMode(1);
      m.setChannelsCount(8);
      expect(m.displayChannelCount, 2);
    });

    test('自动 + sysapo：跟随选中端点混音格式（端点改格式即变）', () {
      final m = _sysapoModel(epId: _ep71, epCh: 8);
      m.setChannelsCountMode(0);
      expect(m.displayChannelCount, 8);
      // 模拟设备扫描刷新：同一端点格式变成立体声。
      m.wasapiDevices = [
        const AudioDeviceItem(
            id: _ep71, name: 'Test EP', isRender: true, ch: 2),
      ];
      expect(m.displayChannelCount, 2);
    });

    test('refresh 把合成值推入 vizChannelCount（显示面即时更新）', () {
      final m = _sysapoModel(epId: _ep71, epCh: 8);
      expect(m.vizChannelCount.value, 0);
      m.refreshDisplayChannelCount();
      expect(m.vizChannelCount.value, 8);
    });

    test('流活跃时流真值优先，refresh 不覆盖', () {
      final m = _sysapoModel(epId: _ep71, epCh: 8);
      m.noteStreamChannelCount(6);
      expect(m.displayChannelCount, 6);
      m.refreshDisplayChannelCount();
      expect(m.vizChannelCount.value, 0); // 未被合成值改写
    });

    test('非 sysapo 自动模式回落 effectiveChannelCount', () {
      final m = AppModel(testing: true);
      m.setChannelsCountMode(0);
      m.channelsCount = 6;
      expect(m.displayChannelCount, 6);
    });
  });
}
