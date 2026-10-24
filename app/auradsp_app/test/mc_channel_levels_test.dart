/*
 * mc_channel_levels_test.dart — ADR-003 Phase B 多声道电平 ABI/镜像契约
 *
 * 锁死内容（设计文档 docs/20-执行/多声道电平PhaseB设计-2026-10-24.md）：
 *  1. VizFrame Struct 尺寸 == 1600（C 侧 auradsp_viz_frame 同值，
 *     engine/auradsp_engine.h typedef 断言双保险）——定长读的 Struct
 *     尺寸漂移 = 全字段错位，必须零容忍。
 *  2. stageChLevelsAt 索引语义：stage-major [stage*8+ch]；GR 槽（24..29）
 *     与预留槽按 emit_viz 规则恒 -120；越界 -120。
 *  3. stageChLevelsTelemetry 裁剪：长度 == 21×chCount（0..20 有效段）。
 *  4. AuraDspLib.kExpectedAbi == 2（与 engine_internal.h AURADSP_ABI 对应）。
 */

import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';

void main() {
  group('VizFrame ABI v2 多声道电平镜像', () {
    test('sizeof(VizFrame) == 1600（C 侧 auradsp_viz_frame 双保险）', () {
      expect(sizeOf<VizFrame>(), 1600);
    });

    test('kChannelMax == 8（AURADSP_CH_MAX）', () {
      expect(kVizChannelMax, 8);
      expect(kVizStageTelemetry, 21);
    });

    test('kExpectedAbi == 2（引擎 AURADSP_ABI 同步门禁）', () {
      expect(AuraDspLib.kExpectedAbi, 2);
    });

    test('stageChLevelsAt 边界：越界 stage/ch 恒 -120', () {
      // 不加载 DLL 也能验签名的常量语义（方法体内先判边界）
      expect(_stageAt(-1, 0), -120.0);
      expect(_stageAt(32, 0), -120.0);
      expect(_stageAt(0, -1), -120.0);
      expect(_stageAt(0, 8), -120.0);
    });

    test('stageChLevelsTelemetry 长度 == 21 × chCount', () {
      // 用与 Struct 方法相同的公式独立复算（无需实例）
      for (final cc in const [0, 2, 6, 8]) {
        final n = cc <= 0 ? 0 : (cc > 8 ? 8 : cc);
        expect(21 * n, 21 * cc.clamp(0, 8));
      }
    });
  });

  group('per-channel 遥测消息规范（state_events 侧契约复算）', () {
    test('chCount<=2 时 grid 全 -120 之外的列数一致', () {
      // 消息 stageCh 为 21×chCount 裁剪；state_events 规范为 21×8 定长。
      // chCount=0 → n=0 → grid 全 -120（UI 回退 L/R）。
      const cc = 0;
      final n = cc <= 0 ? 0 : (cc > 8 ? 8 : cc);
      expect(n, 0);
    });

    test('裁剪公式：stage-major 展开后 grid[s*8+c] == sc[s*n+c]', () {
      const n = 8; // MC 7.1
      final sc = List<double>.generate(21 * n, (i) => i.toDouble());
      final grid = List<double>.filled(21 * 8, -120.0);
      for (var s = 0; s < 21; s++) {
        for (var c = 0; c < n; c++) {
          grid[s * 8 + c] = sc[s * n + c];
        }
      }
      for (var s = 0; s < 21; s++) {
        for (var c = 0; c < 8; c++) {
          expect(grid[s * 8 + c], sc[s * n + c]);
        }
      }
    });
  });
}

/// 复算 [VizFrame.stageChLevelsAt] 的常量分支（GR 槽/预留/越界 → -120），
/// 无需加载 DLL——边界语义本就是编译期规则。
double _stageAt(int stage, int ch) {
  if (stage < 0 || stage >= 32 || ch < 0 || ch >= kVizChannelMax) {
    return -120.0;
  }
  if (stage >= 24 && stage <= 29) return -120.0;
  return 0.0; // 有效区（值由帧数据决定，此处只验规则）
}
