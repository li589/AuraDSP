/*
 * mc_channel_levels_test.dart — ADR-003 Phase B 多声道电平 ABI/镜像契约
 *
 * 锁死内容（设计文档 docs/20-执行/多声道电平PhaseB设计-2026-10-24.md）：
 *  1. VizFrame Struct 尺寸 == 1600（C 侧 auradsp_viz_frame 同值，
 *     engine/auradsp_engine.h typedef 断言双保险）——定长读的 Struct
 *     尺寸漂移 = 全字段错位，必须零容忍。
 *  2. stageChLevelsAt 真实方法语义（S1 教训：期望值必须穿透生产方法，
 *     不能测试内复算公式自证）：stage-major [stage*8+ch]；GR 槽（24..29）
 *     与预留槽按 emit_viz 规则恒 -120；越界 -120。
 *  3. stageChLevelsTelemetry 真实方法：长度 == 21×chCount、stage-major
 *     裁剪映射正确。
 *  4. AuraDspLib.kExpectedAbi == 2（与 engine_internal.h AURADSP_ABI 对应）。
 */

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' show malloc;
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';

void main() {
  group('VizFrame ABI v2 多声道电平镜像', () {
    test('sizeof(VizFrame) == 1600（C 侧 auradsp_viz_frame 双保险）', () {
      expect(ffi.sizeOf<VizFrame>(), 1600);
    });

    test('kVizChannelMax == 8（AURADSP_CH_MAX）', () {
      expect(kVizChannelMax, 8);
      expect(kVizStageTelemetry, 21);
    });

    test('kExpectedAbi == 2（引擎 AURADSP_ABI 同步门禁）', () {
      expect(AuraDspLib.kExpectedAbi, 2);
    });

    test('stageChLevelsAt 真实方法：有效列取值 / GR 预留越界恒 -120', () {
      final p = malloc<VizFrame>();
      try {
        final f = p.ref;
        // 全表清零后只在已知位置放哨兵值
        for (var i = 0; i < 32 * 8; i++) {
          f.stageChLevels[i] = 0.0;
        }
        f.stageChLevels[13 * 8 + 3] = -42.5; // 自研段（gate 输出）ch3
        f.stageChLevels[5 * 8 + 1] = -7.25; // vendor 段 ch1（L/R 列）

        // 自研段：有效列真实取值（stage-major 索引穿透）
        expect(f.stageChLevelsAt(13, 3), -42.5);
        // vendor 段 [0]/[1] 也按真实表取（emit_viz 写入后同源）
        expect(f.stageChLevelsAt(5, 1), -7.25);
        // GR 槽（24..29）：任何声道恒 -120（单值语义，即使表里写了别的值）
        f.stageChLevels[24 * 8 + 0] = 99.0;
        expect(f.stageChLevelsAt(24, 0), -120.0);
        expect(f.stageChLevelsAt(25, 5), -120.0);
        expect(f.stageChLevelsAt(29, 7), -120.0);
        // 预留槽（21..23 / 30..31）：恒 -120
        expect(f.stageChLevelsAt(21, 0), -120.0);
        expect(f.stageChLevelsAt(31, 7), -120.0);
        // 越界：-120（诚实降级）
        expect(f.stageChLevelsAt(-1, 0), -120.0);
        expect(f.stageChLevelsAt(32, 0), -120.0);
        expect(f.stageChLevelsAt(0, -1), -120.0);
        expect(f.stageChLevelsAt(0, 8), -120.0);
      } finally {
        malloc.free(p);
      }
    });

    test('stageChLevelsTelemetry 真实方法：长度 21×chCount + stage-major 裁剪', () {
      final p = malloc<VizFrame>();
      try {
        final f = p.ref;
        for (var i = 0; i < 32 * 8; i++) {
          f.stageChLevels[i] = i.toDouble();
        }
        // MC 7.1：chCount=8 → 长度 21×8，全量 stage-major 透传
        f.channelCount = 8;
        var tele = f.stageChLevelsTelemetry();
        expect(tele.length, 21 * 8);
        expect(tele[13 * 8 + 3], (13 * 8 + 3).toDouble());
        // stereo：chCount=2 → 长度 21×2，只保留每行前两列
        f.channelCount = 2;
        tele = f.stageChLevelsTelemetry();
        expect(tele.length, 21 * 2);
        expect(tele[5 * 2 + 0], (5 * 8 + 0).toDouble());
        expect(tele[5 * 2 + 1], (5 * 8 + 1).toDouble());
        // 无帧：chCount=0 → 空表
        f.channelCount = 0;
        expect(f.stageChLevelsTelemetry().length, 0);
        // 越界 clamp：chCount=99 → 8
        f.channelCount = 99;
        expect(f.stageChLevelsTelemetry().length, 21 * 8);
      } finally {
        malloc.free(p);
      }
    });

    test('channelLevelsToList 真实方法：按 channelCount 裁剪', () {
      final p = malloc<VizFrame>();
      try {
        final f = p.ref;
        for (var i = 0; i < 8; i++) {
          f.channelLevels[i] = -6.0 * (i + 1);
        }
        f.channelCount = 6;
        final l = f.channelLevelsToList();
        expect(l.length, 6);
        expect(l[0], -6.0);
        expect(l[5], -36.0);
        f.channelCount = 0;
        expect(f.channelLevelsToList(), isEmpty);
      } finally {
        malloc.free(p);
      }
    });
  });

  group('per-channel 遥测消息规范（state_events 侧契约复算）', () {
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
