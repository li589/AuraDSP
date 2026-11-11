// 第五轮 S2：本地输出端点失效恢复口径（纯函数）契约测试。
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/engine/audio_out/out_recovery.dart';

void main() {
  group('out_recovery（第五轮 S2）', () {
    test('分类：WASAPI 失效 HRESULT 命中、其余不命中', () {
      expect(
        isDeviceInvalidatedError(StateError(
            'WASAPI GetCurrentPadding failed hr=0x88890004 '
            '(endpoint: 扬声器 (AuraVAIO Virtual Audio Device))')),
        isTrue,
      );
      // 被占（DEVICE_IN_USE）不是失效：走既有 400 轮口径，不命中。
      expect(
        isDeviceInvalidatedError(
            StateError('WASAPI Start failed hr=0x8889000a')),
        isFalse,
      );
      // Linux 后端文案不含 HRESULT 形态，天然不命中。
      expect(
        isDeviceInvalidatedError(StateError('pulse: stream died')),
        isFalse,
      );
      expect(isDeviceInvalidatedError('random string'), isFalse);
    });

    test('退避表：500/1000/2000/4000 封顶', () {
      expect(outReinitBackoffMs(1), 500);
      expect(outReinitBackoffMs(2), 1000);
      expect(outReinitBackoffMs(3), 2000);
      expect(outReinitBackoffMs(4), 4000);
      expect(outReinitBackoffMs(5), 4000);
      expect(outReinitBackoffMs(99), 4000);
      expect(outReinitBackoffMs(0), 500);
    });

    test('恢复窗口为 30s（超窗回落死亡计数）', () {
      expect(kOutReinitWindowMs, 30000);
    });
  });
}
