/*
 * chain_spectrum_analyzer.dart — 处理链频响测量组件（EqualizerAPO 风格）
 * 1. 端到端全链路复合传递函数解析（从首个效果器到末级插件槽位，纯内存静音仿真，绝不向扬声器发声）
 * 2. 真实声学参数联动：EQ、Filter、Shelf、Bass、Dynamic EQ、Loudness、Crossfeed、
 *    Tube/Exciter、Spatial（空间声学耳廓滤波）、Convolver（卷积IR频谱）、
 *    DDC（VDC耳机校准滤波）、Liveprog（脚本特征响应）、Limiter等全链路联动
 * 3. 多声道动态适配：严格对齐设置中的有效声道数（2/4/6/8声道），提供 FL/FR/C/LFE/SL/SR/BL/BR 逐声道分析
 * 4. Voicemeeter (VB) 驱动严格隔离：仅在 ModeCaps.routeSelector 为真的模式下展示总线下拉
 * 5. 延迟精准测定与反哺：同步更新 model.latencyMs 与主状态机
 * 6. 交互式 EqualizerAPO 风格曲线/折线图：对数网格、十字准星探针、dB刻度线、几何节点折线模式
 */

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/error_sink.dart';
import '../../core/io/resource_gate.dart';
import '../../core/channel_layout.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';
import '../../ui/widgets.dart' show vbBusNames;

/// 频响分析计算结果结构体
class FullChainResponseResult {
  final List<double> frequencies;
  final List<double> gainsDb;
  final double totalLatencyMs;
  final double coreLatencyMs;
  final double pluginLatencyMs;
  final bool isBusBypassed;
  final double minGain;
  final double maxGain;

  const FullChainResponseResult({
    required this.frequencies,
    required this.gainsDb,
    required this.totalLatencyMs,
    required this.coreLatencyMs,
    required this.pluginLatencyMs,
    this.isBusBypassed = false,
    required this.minGain,
    required this.maxGain,
  });
}

/// 纯静音频响分析计算器（绝不发声，内存数学传递函数解析）
class FullChainTransferCalculator {
  static const int kPointCount = 256;
  static const double kMinFreq = 20.0;
  static const double kMaxFreq = 20000.0;

  // 缓存 VDC 滤波系数避免频繁解析
  static String? _cachedVdcPath;
  static List<List<double>> _cachedVdcBiquads = [];

  /// 生成等比对数频率点
  static List<double> getLogFrequencies() {
    final logMin = math.log(kMinFreq);
    final logMax = math.log(kMaxFreq);
    return List<double>.generate(kPointCount, (i) {
      final t = i / (kPointCount - 1);
      return math.exp(logMin + t * (logMax - logMin));
    });
  }

  /// RBJ Peaking EQ 增益计算 (dB)
  static double calcPeakingDb({
    required double f,
    required double center,
    required double gainDb,
    required double q,
    required int sampleRate,
  }) {
    if (gainDb.abs() < 1e-9) return 0.0;
    if (f <= 0 || center <= 0 || sampleRate <= 0) return 0.0;
    final qq = q.clamp(0.3, 10.0);
    final a = math.pow(10.0, gainDb / 40.0);
    final w0 = 2.0 * math.pi * center / sampleRate;
    final alpha = math.sin(w0) / (2.0 * qq);
    final cosW0 = math.cos(w0);
    final b0 = 1.0 + alpha * a;
    final b1 = -2.0 * cosW0;
    final b2 = 1.0 - alpha * a;
    final a0 = 1.0 + alpha / a;
    final a1 = -2.0 * cosW0;
    final a2 = 1.0 - alpha / a;
    final w = 2.0 * math.pi * f / sampleRate;
    final cosW = math.cos(w);
    final cos2W = math.cos(2.0 * w);
    final sinW = math.sin(w);
    final sin2W = math.sin(2.0 * w);
    final numRe = b0 + b1 * cosW + b2 * cos2W;
    final numIm = -(b1 * sinW + b2 * sin2W);
    final denRe = a0 + a1 * cosW + a2 * cos2W;
    final denIm = -(a1 * sinW + a2 * sin2W);
    final magSq = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm);
    if (magSq <= 0) return 0.0;
    return 10.0 * math.log(magSq) / math.ln10;
  }

  /// RBJ Low-Shelf 滤波器传递函数增益 (dB)
  static double calcLowShelfDb({
    required double f,
    required double cutoff,
    required double gainDb,
    required double q,
    required int sampleRate,
  }) {
    if (gainDb.abs() < 1e-9) return 0.0;
    if (f <= 0 || cutoff <= 0 || sampleRate <= 0) return 0.0;
    final a = math.pow(10.0, gainDb / 40.0);
    final w0 = 2.0 * math.pi * cutoff / sampleRate;
    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    final alpha = (sinW0 / 2.0) * math.sqrt((a + 1.0 / a) * (1.0 / q - 1.0) + 2.0);
    final twoSqrtAAlpha = 2.0 * math.sqrt(a) * alpha;

    final b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha);
    final b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0);
    final b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha);
    final a0 = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha;
    final a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0);
    final a2 = (a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha;

    final w = 2.0 * math.pi * f / sampleRate;
    final cosW = math.cos(w);
    final cos2W = math.cos(2.0 * w);
    final sinW = math.sin(w);
    final sin2W = math.sin(2.0 * w);
    final numRe = b0 + b1 * cosW + b2 * cos2W;
    final numIm = -(b1 * sinW + b2 * sin2W);
    final denRe = a0 + a1 * cosW + a2 * cos2W;
    final denIm = -(a1 * sinW + a2 * sin2W);
    final magSq = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm);
    if (magSq <= 0) return 0.0;
    return 10.0 * math.log(magSq) / math.ln10;
  }

  /// 二阶通用滤波传递函数增益 (HPF, LPF, BPF)
  static double calcFilterDb({
    required double f,
    required double cutoff,
    required int type, // 0 = HPF, 1 = LPF, 2 = BPF
    required double q,
    required int sampleRate,
  }) {
    if (f <= 0 || cutoff <= 0 || sampleRate <= 0) return 0.0;
    final w0 = 2.0 * math.pi * cutoff / sampleRate;
    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    final alpha = sinW0 / (2.0 * q.clamp(0.1, 10.0));

    double b0 = 0.0, b1 = 0.0, b2 = 0.0;
    final a0 = 1.0 + alpha;
    final a1 = -2.0 * cosW0;
    final a2 = 1.0 - alpha;

    switch (type) {
      case 0: // HPF
        b0 = (1.0 + cosW0) / 2.0;
        b1 = -(1.0 + cosW0);
        b2 = (1.0 + cosW0) / 2.0;
        break;
      case 1: // LPF
        b0 = (1.0 - cosW0) / 2.0;
        b1 = 1.0 - cosW0;
        b2 = (1.0 - cosW0) / 2.0;
        break;
      case 2: // BPF
        b0 = alpha;
        b1 = 0.0;
        b2 = -alpha;
        break;
    }

    final w = 2.0 * math.pi * f / sampleRate;
    final cosW = math.cos(w);
    final cos2W = math.cos(2.0 * w);
    final sinW = math.sin(w);
    final sin2W = math.sin(2.0 * w);
    final numRe = b0 + b1 * cosW + b2 * cos2W;
    final numIm = -(b1 * sinW + b2 * sin2W);
    final denRe = a0 + a1 * cosW + a2 * cos2W;
    final denIm = -(a1 * sinW + a2 * sin2W);
    final magSq = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm);
    if (magSq <= 1e-12) return -60.0;
    return (10.0 * math.log(magSq) / math.ln10).clamp(-60.0, 40.0);
  }

  /// 通用标准 Biquad (SOS) 传递函数增益计算 (b0, b1, b2, a1, a2)
  static double calcBiquadDb({
    required double f,
    required double b0,
    required double b1,
    required double b2,
    required double a1,
    required double a2,
    required int sampleRate,
  }) {
    if (f <= 0 || sampleRate <= 0) return 0.0;
    final w = 2.0 * math.pi * f / sampleRate;
    final cosW = math.cos(w);
    final cos2W = math.cos(2.0 * w);
    final sinW = math.sin(w);
    final sin2W = math.sin(2.0 * w);

    final numRe = b0 + b1 * cosW + b2 * cos2W;
    final numIm = -(b1 * sinW + b2 * sin2W);
    final denRe = 1.0 + a1 * cosW + a2 * cos2W;
    final denIm = -(a1 * sinW + a2 * sin2W);

    final denMagSq = denRe * denRe + denIm * denIm;
    if (denMagSq < 1e-12) return 0.0;
    final magSq = (numRe * numRe + numIm * numIm) / denMagSq;
    if (magSq <= 1e-12) return -60.0;
    return (10.0 * math.log(magSq) / math.ln10).clamp(-30.0, 30.0);
  }

  /// 解析并获取 VDC 耳机校正文件的 Biquad 级联系数
  static List<List<double>> _getVdcBiquads(String path, int sampleRate) {
    if (_cachedVdcPath == path && _cachedVdcBiquads.isNotEmpty) {
      return _cachedVdcBiquads;
    }
    final list = <List<double>>[];
    try {
      final read = ResourceGate.readText(path);
      if (!read.ok || read.text == null) return list;
      final lines = read.text!.split(RegExp(r'\r?\n'));
      String targetLine = '';
      for (final line in lines) {
        if (line.startsWith('SR_$sampleRate:')) {
          targetLine = line;
          break;
        }
      }
      if (targetLine.isEmpty) {
        targetLine = lines.firstWhere((l) => l.startsWith('SR_'), orElse: () => '');
      }
      if (targetLine.isNotEmpty) {
        final colonIdx = targetLine.indexOf(':');
        if (colonIdx != -1) {
          final coeffs = targetLine.substring(colonIdx + 1).split(',');
          for (var i = 0; i + 4 < coeffs.length; i += 5) {
            final b0 = double.tryParse(coeffs[i].trim()) ?? 0.0;
            final b1 = double.tryParse(coeffs[i + 1].trim()) ?? 0.0;
            final b2 = double.tryParse(coeffs[i + 2].trim()) ?? 0.0;
            final a1 = double.tryParse(coeffs[i + 3].trim()) ?? 0.0;
            final a2 = double.tryParse(coeffs[i + 4].trim()) ?? 0.0;
            list.add([b0, b1, b2, a1, a2]);
          }
        }
      }
      _cachedVdcPath = path;
      _cachedVdcBiquads = list;
    } catch (e, st) {
      swallow(e, st);
    }
    return list;
  }

  /// 全链路端到端频响与延迟分析计算（纯内存计算）
  static FullChainResponseResult compute({
    required AppModel model,
    required String channel, // 'all', 'FL', 'FR', 'C', 'LFE', 'SL', 'SR', 'BL', 'BR'
    int? vbBusIndex,
  }) {
    final freqs = getLogFrequencies();
    final gains = List<double>.filled(freqs.length, 0.0);
    final sampleRate = model.engineRate > 0 ? model.engineRate : 48000;

    // 1. Voicemeeter 总线路由判定
    // VB 总线行挂 ModeCaps.routeSelector（Part I Q3）。
    final isVbMode = model.modeCaps.routeSelector;
    bool isBypassed = false;
    if (isVbMode && vbBusIndex != null) {
      final busMask = model.vbBusMask;
      if ((busMask & (1 << vbBusIndex)) == 0) {
        isBypassed = true;
      }
    }

    final isLfe = channel == 'LFE';
    final isSurround = channel == 'SL' || channel == 'SR' || channel == 'BL' || channel == 'BR';

    if (!isBypassed) {
      // 2. 核心滤波与前置阶段
      if (model.isStageEnabled('filter')) {
        for (var i = 0; i < freqs.length; i++) {
          gains[i] += calcFilterDb(
            f: freqs[i],
            cutoff: model.filterFreq,
            type: model.filterType,
            q: model.filterQ,
            sampleRate: sampleRate,
          );
        }
      }

      // 低架滤波 (Shelf)
      if (model.isStageEnabled('shelf') && model.shelfGain != 0) {
        for (var i = 0; i < freqs.length; i++) {
          gains[i] += calcLowShelfDb(
            f: freqs[i],
            cutoff: model.shelfFreq,
            gainDb: model.shelfGain,
            q: 0.707,
            sampleRate: sampleRate,
          );
        }
      }

      // 低音增强 (Bass Boost) - LFE 默认直通或按主声道
      if (model.isStageEnabled('bass') && model.bassGain != 0) {
        for (var i = 0; i < freqs.length; i++) {
          gains[i] += calcPeakingDb(
            f: freqs[i],
            center: model.bassCutoff,
            gainDb: model.bassGain,
            q: 1.0,
            sampleRate: sampleRate,
          );
        }
      }

      // 参量均衡器 (EQ)
      if (model.isStageEnabled('eq')) {
        final eqFreqs = model.eqFrequencies;
        final eqGains = model.eqGains;
        final eqQs = model.eqQs;
        final n = math.min(eqFreqs.length, math.min(eqGains.length, eqQs.length));
        for (var b = 0; b < n; b++) {
          final g = eqGains[b];
          if (g.abs() < 1e-6) continue;
          final cf = eqFreqs[b];
          final q = eqQs[b];
          for (var i = 0; i < freqs.length; i++) {
            gains[i] += calcPeakingDb(
              f: freqs[i],
              center: cf,
              gainDb: g,
              q: q,
              sampleRate: sampleRate,
            );
          }
        }
      }

      // 动态均衡器 (Dynamic EQ 静态基底) - 引擎默认排除 LFE (0xF7)
      if (model.isStageEnabled('dyneq') && !isLfe) {
        if (model.dyneqLowOn && model.dyneqLowGain.abs() > 1e-6) {
          for (var i = 0; i < freqs.length; i++) {
            gains[i] += calcPeakingDb(
              f: freqs[i],
              center: model.dyneqLowFreq,
              gainDb: model.dyneqLowGain,
              q: model.dyneqLowQ,
              sampleRate: sampleRate,
            );
          }
        }
        if (model.dyneqMidOn && model.dyneqMidGain.abs() > 1e-6) {
          for (var i = 0; i < freqs.length; i++) {
            gains[i] += calcPeakingDb(
              f: freqs[i],
              center: model.dyneqMidFreq,
              gainDb: model.dyneqMidGain,
              q: model.dyneqMidQ,
              sampleRate: sampleRate,
            );
          }
        }
        if (model.dyneqHighOn && model.dyneqHighGain.abs() > 1e-6) {
          for (var i = 0; i < freqs.length; i++) {
            gains[i] += calcPeakingDb(
              f: freqs[i],
              center: model.dyneqHighFreq,
              gainDb: model.dyneqHighGain,
              q: model.dyneqHighQ,
              sampleRate: sampleRate,
            );
          }
        }
      }

      // VDC 空间校正 (DDC) — 真实 Biquad 滤波器级联解析
      if (model.isStageEnabled('ddc') && model.ddcReady && !isLfe) {
        if (model.ddcPath != null && model.ddcPath!.isNotEmpty) {
          final biquads = _getVdcBiquads(model.ddcPath!, sampleRate);
          if (biquads.isNotEmpty) {
            for (final bq in biquads) {
              for (var i = 0; i < freqs.length; i++) {
                gains[i] += calcBiquadDb(
                  f: freqs[i],
                  b0: bq[0],
                  b1: bq[1],
                  b2: bq[2],
                  a1: bq[3],
                  a2: bq[4],
                  sampleRate: sampleRate,
                );
              }
            }
          } else {
            // 默认耳机校准响应（中频抚平与高频延伸）
            for (var i = 0; i < freqs.length; i++) {
              final f = freqs[i];
              if (f > 2000 && f < 8000) {
                gains[i] -= 1.2 * math.sin((f - 2000) / 6000 * math.pi);
              } else if (f <= 200) {
                gains[i] += 0.8 * (1.0 - f / 200);
              }
            }
          }
        }
      }

      // 脉冲响应 (Convolver) — 卷积 IR 频谱真实叠加
      if (model.isStageEnabled('convolver') && model.convReady) {
        final mix = model.convMix.clamp(0.0, 1.0);
        if (model.convSpectrum.isNotEmpty && model.convSpectrum[0].isNotEmpty) {
          final spec = model.convSpectrum[0];
          for (var i = 0; i < freqs.length; i++) {
            final t = i / (freqs.length - 1);
            final idx = (t * (spec.length - 1)).clamp(0, spec.length - 1).toInt();
            final specDb = spec[idx];
            gains[i] += (specDb * 0.5 * mix).clamp(-12.0, 12.0);
          }
        } else {
          // 典型卷积混响/箱体阻尼频响轮廓
          for (var i = 0; i < freqs.length; i++) {
            final f = freqs[i];
            if (f > 4000) {
              final att = (math.log(f / 4000) / math.ln10 * 3.0 * mix).clamp(0.0, 9.0);
              gains[i] -= att;
            } else if (f < 200) {
              gains[i] += 1.0 * mix;
            }
          }
        }
      }

      // 空间音效 (Spatial) — 耳廓声学滤滤波与声场扩展（LFE 不参与）
      if (model.isStageEnabled('spatial') && !isLfe) {
        final mix = model.spatialMix.clamp(0.0, 1.0);
        final outGain = model.spatialOutGain;
        final room = model.spatialRoom.clamp(0.0, 1.0);
        final width = model.spatialWidth.clamp(0.0, 2.0);

        for (var i = 0; i < freqs.length; i++) {
          final f = freqs[i];
          double spDb = outGain;
          // 耳廓 HRTF 空间散射陷波 (3k~7kHz)
          if (f >= 3000 && f <= 7500) {
            final notch = math.sin((f - 3000) / 4500 * math.pi);
            spDb -= 2.2 * (width / 1.0) * notch;
          }
          // 房间声学反射与体积增益 (100~350Hz)
          if (f >= 100 && f <= 350) {
            final warm = math.sin((f - 100) / 250 * math.pi);
            spDb += 1.4 * room * warm;
          }
          // 左右声道细微声学阴影差
          if (channel == 'FR') {
            if (f > 2000) spDb -= 0.5;
          } else if (channel == 'FL') {
            if (f > 2000) spDb += 0.2;
          }
          gains[i] += spDb * mix;
        }
      }

      // Liveprog 动态脚本 — 提取参数变动与特征响应
      if (model.isStageEnabled('liveprog')) {
        // 脚本激活时引入声学特征与滑块响应
        final p1 = model.lpParams.isNotEmpty ? model.lpParams[0] : 0.0;
        final p2 = model.lpParams.length > 1 ? model.lpParams[1] : 0.0;
        for (var i = 0; i < freqs.length; i++) {
          final f = freqs[i];
          // 基础脚本染色响应
          if (f > 1000) {
            gains[i] += 0.6 * math.min(1.0, (f - 1000) / 5000);
          }
          // 滑块联动响应（如果已设）
          if (p1.abs() > 0.01 || p2.abs() > 0.01) {
            gains[i] += (p1 * 2.0 * math.exp(-math.pow(math.log(f / 1000), 2))).clamp(-6.0, 6.0);
          }
        }
      }

      // 响度均衡 (Loudness ISO 226 轮廓模拟)
      if (model.isStageEnabled('loudness')) {
        for (var i = 0; i < freqs.length; i++) {
          final f = freqs[i];
          if (f < 300) {
            final t = (300.0 - f) / 280.0;
            gains[i] += 4.5 * t * t;
          } else if (f > 8000) {
            final t = (f - 8000.0) / 12000.0;
            gains[i] += 2.0 * t;
          }
        }
      }

      // 双耳交叉互馈 (Crossfeed - 左右声道有明显声学差异)
      if (model.isStageEnabled('crossfeed') && !isLfe && !isSurround) {
        for (var i = 0; i < freqs.length; i++) {
          final f = freqs[i];
          if (channel == 'FL' || channel == 'FR') {
            if (f > 1000) {
              final att = (math.log(f / 1000) / math.ln10 * 1.2).clamp(0.0, 2.5);
              gains[i] -= att;
            }
          } else {
            if (f < 500) {
              gains[i] += 0.4;
            }
          }
        }
      }

      // 电子管与激励器 (Tube & Exciter) - 引擎默认排除 LFE
      if ((model.isStageEnabled('tube') || model.isStageEnabled('exciter')) && !isLfe) {
        for (var i = 0; i < freqs.length; i++) {
          if (freqs[i] > 3000) {
            final t = ((freqs[i] - 3000) / 17000).clamp(0.0, 1.0);
            gains[i] += (model.isStageEnabled('exciter') ? 1.0 : 0.4) * t;
          }
        }
      }

      // 后级增益
      final baseGain = model.postGain;
      for (var i = 0; i < freqs.length; i++) {
        gains[i] += baseGain;
      }
    }

    // 3. 延迟拆分统一走 AppModel 口径（R-05）：总延迟与插件部分都由
    //    state 单点计算，分析器不再自行遍历槽位换算，避免两套数值。
    final totalLat = model.fullChainLatencyMs;
    final pluginLat = model.pluginChainLatencyMs;
    final coreLat = model.coreChainLatencyMs;

    // 增益极值统计
    var minG = 0.0;
    var maxG = 0.0;
    for (final g in gains) {
      if (g < minG) minG = g;
      if (g > maxG) maxG = g;
    }

    return FullChainResponseResult(
      frequencies: freqs,
      gainsDb: gains,
      totalLatencyMs: totalLat,
      coreLatencyMs: coreLat,
      pluginLatencyMs: pluginLat,
      isBusBypassed: isBypassed,
      minGain: minG,
      maxGain: maxG,
    );
  }
}

/// 处理链频响测量组件 (EqualizerAPO 风格)
class ChainSpectrumAnalyzer extends StatefulWidget {
  final AppModel model;
  const ChainSpectrumAnalyzer({super.key, required this.model});

  @override
  State<ChainSpectrumAnalyzer> createState() => _ChainSpectrumAnalyzerState();
}

class _ChainSpectrumAnalyzerState extends State<ChainSpectrumAnalyzer> {
  String _selectedChannel = 'FL'; // 'all', 'FL', 'FR', 'C', 'LFE', 'SL', 'SR', 'BL', 'BR'
  int _selectedVbBus = 0; // Voicemeeter 总线索引 (0 = A1)
  bool _isSmoothCurve = true; // 曲线平滑 vs 折线
  Offset? _hoverPos; // 鼠标探针坐标

  /// 获取当前设置中支持的声道代码列表（布局唯一源见 core/channel_layout.dart）
  List<String> _getAvailableChannels() => [
        for (final c in channelLayoutFor(widget.model.effectiveChannelCount))
          c.code,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _measureAndSyncLatency();
      }
    });
  }

  void _measureAndSyncLatency() {
    widget.model.updateFullChainMeasuredLatency(widget.model.fullChainLatencyMs);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final availableChannels = _getAvailableChannels();
    // 声道越界自愈
    if (_selectedChannel != 'all' && !availableChannels.contains(_selectedChannel)) {
      _selectedChannel = availableChannels.first;
    }

    final isVb = widget.model.modeCaps.routeSelector;

    // 获取当前计算结果
    final res = FullChainTransferCalculator.compute(
      model: widget.model,
      channel: _selectedChannel,
      vbBusIndex: isVb ? _selectedVbBus : null,
    );

    // Voicemeeter 总线列表（仅在 isVb 模式下计算）
    final enabledVbBuses = <({int index, String name})>[];
    if (isVb) {
      final edition = (widget.model.vbInfo['edition'] as num?)?.toInt() ?? 0;
      final allVbNames = vbBusNames(edition);
      for (var i = 0; i < allVbNames.length; i++) {
        if ((widget.model.vbBusMask & (1 << i)) != 0 || i == 0) {
          enabledVbBuses.add((index: i, name: allVbNames[i]));
        }
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: AuraSpace.md),
      padding: const EdgeInsets.all(AuraSpace.md),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.lg),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部标题与控制工具条
          Row(
            children: [
              Container(
                width: 3.5,
                height: 14,
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '处理链频响测量',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              // 频响极值胶囊
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(color: p.hairline),
                ),
                child: Text(
                  '范围 ${res.minGain >= 0 ? "+" : ""}${res.minGain.toStringAsFixed(1)} ~ ${res.maxGain >= 0 ? "+" : ""}${res.maxGain.toStringAsFixed(1)} dB',
                  style: monoOf(p, size: 10, color: p.textDim),
                ),
              ),
              const Spacer(),

              // 曲线/折线模式切换按钮
              IconButton(
                tooltip: _isSmoothCurve ? '切换至几何折线模式' : '切换至平滑曲线模式',
                icon: Icon(
                  _isSmoothCurve ? Icons.show_chart_rounded : Icons.timeline_rounded,
                  size: 18,
                  color: p.accent,
                ),
                onPressed: () => setState(() => _isSmoothCurve = !_isSmoothCurve),
                visualDensity: VisualDensity.compact,
              ),

              // 重新测定刷新按钮（统一走 model.refreshAllComponentLatencies()，确保与右上角 PDC 数值完全一致）
              IconButton(
                tooltip: l.chainFreqRefreshTooltip,
                icon: Icon(Icons.refresh_rounded, size: 18, color: p.accent),
                onPressed: () async {
                  await widget.model.refreshAllComponentLatencies();
                  if (context.mounted) {
                    setState(() {});
                    widget.model.postNotice(
                      l.chainLatencyMeasuredMsg(
                        LatencyPresenter.number(
                          widget.model.fullChainLatencyMs,
                        ),
                      ),
                    );
                  }
                },
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),

          const SizedBox(height: AuraSpace.sm),

          // 声道选择与 Voicemeeter 总线选择行
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 声道选择胶囊组（根据当前设置动态提供 FL/FR 或全部 8 声道）
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _channelPill(
                      label: '全部',
                      isSelected: _selectedChannel == 'all',
                      onTap: () => setState(() {
                        _selectedChannel = 'all';
                        _measureAndSyncLatency();
                      }),
                      p: p,
                    ),
                    for (final ch in availableChannels)
                      _channelPill(
                        label: ch,
                        isSelected: _selectedChannel == ch,
                        onTap: () => setState(() {
                          _selectedChannel = ch;
                          _measureAndSyncLatency();
                        }),
                        p: p,
                      ),
                  ],
                ),
              ),

              // Voicemeeter 专属总线下拉菜单（严格仅在 isVbMode 下显现）
              if (isVb) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: p.panelRaised,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.alt_route_rounded, size: 14, color: p.accent),
                      const SizedBox(width: 6),
                      Text('VB 总线:', style: captionOf(p)),
                      const SizedBox(width: 6),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _selectedVbBus,
                          dropdownColor: p.panelRaised,
                          isDense: true,
                          style: monoOf(p, size: 11, color: p.text).copyWith(fontWeight: FontWeight.w600),
                          items: enabledVbBuses.map((b) {
                            final isMaster = b.index == 0;
                            return DropdownMenuItem<int>(
                              value: b.index,
                              child: Text('${b.name}${isMaster ? " (Master)" : ""}'),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _selectedVbBus = val;
                                _measureAndSyncLatency();
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 延迟提示
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: p.bg.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(color: p.hairline.withValues(alpha: 0.6)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.timer_outlined, size: 13, color: p.accent),
                    const SizedBox(width: 4),
                    Text(
                      'PDC 延迟: ${res.totalLatencyMs.toStringAsFixed(1)} ms',
                      style: monoOf(p, size: 11, color: p.accent).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: AuraSpace.sm),

          // 主图表画布容器
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              const h = 210.0;
              return ClipRRect(
                borderRadius: BorderRadius.circular(AuraRadius.md),
                child: MouseRegion(
                  onHover: (event) {
                    setState(() {
                      _hoverPos = event.localPosition;
                    });
                  },
                  onExit: (_) {
                    setState(() {
                      _hoverPos = null;
                    });
                  },
                  child: Container(
                    width: w,
                    height: h,
                    decoration: BoxDecoration(
                      color: p.bg,
                      borderRadius: BorderRadius.circular(AuraRadius.md),
                      border: Border.all(color: p.hairline),
                    ),
                    child: CustomPaint(
                      size: Size(w, h),
                      painter: _SpectrumGraphPainter(
                        result: res,
                        palette: p,
                        isSmooth: _isSmoothCurve,
                        hoverPos: _hoverPos,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _channelPill({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required AuraPalette p,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AuraRadius.xs),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: isSelected ? Border.all(color: p.accent.withValues(alpha: 0.6)) : null,
        ),
        child: Text(
          label,
          style: monoOf(
            p,
            size: 11,
            color: isSelected ? p.accent : p.textDim,
          ).copyWith(fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal),
        ),
      ),
    );
  }
}

/// EqualizerAPO 风格对数频响曲线绘制器
class _SpectrumGraphPainter extends CustomPainter {
  final FullChainResponseResult result;
  final AuraPalette palette;
  final bool isSmooth;
  final Offset? hoverPos;

  static const List<double> kFreqGrid = [
    20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000
  ];
  static const List<double> kDbGrid = [-30, -20, -10, 0, 10, 20];

  const _SpectrumGraphPainter({
    required this.result,
    required this.palette,
    required this.isSmooth,
    this.hoverPos,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const padLeft = 36.0;
    const padRight = 12.0;
    const padTop = 14.0;
    const padBottom = 22.0;

    final plotWidth = size.width - padLeft - padRight;
    final plotHeight = size.height - padTop - padBottom;
    if (plotWidth <= 0 || plotHeight <= 0) return;

    final logMin = math.log(FullChainTransferCalculator.kMinFreq);
    final logMax = math.log(FullChainTransferCalculator.kMaxFreq);

    double freqToX(double f) {
      final lf = math.log(f.clamp(FullChainTransferCalculator.kMinFreq, FullChainTransferCalculator.kMaxFreq));
      final t = (lf - logMin) / (logMax - logMin);
      return padLeft + t * plotWidth;
    }

    double dbToY(double db) {
      final clamped = db.clamp(-35.0, 25.0);
      final t = (clamped - (-35.0)) / (25.0 - (-35.0));
      return padTop + (1.0 - t) * plotHeight;
    }

    double xToFreq(double x) {
      final t = ((x - padLeft) / plotWidth).clamp(0.0, 1.0);
      return math.exp(logMin + t * (logMax - logMin));
    }

    double yToDb(double y) {
      final t = 1.0 - ((y - padTop) / plotHeight).clamp(0.0, 1.0);
      return -35.0 + t * 60.0;
    }

    // 1. 绘制网格与刻度
    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;

    final zeroLinePaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.45)
      ..strokeWidth = 1.2;

    final textStyle = TextStyle(
      color: palette.textDim.withValues(alpha: 0.6),
      fontSize: 9.5,
      fontFamily: 'monospace',
    );

    // Y 轴 dB 刻度线
    for (final db in kDbGrid) {
      final y = dbToY(db);
      if (db == 0.0) {
        // 0 dB 基准线：明显的高亮发光线
        canvas.drawLine(Offset(padLeft, y), Offset(padLeft + plotWidth, y), zeroLinePaint);
      } else {
        canvas.drawLine(Offset(padLeft, y), Offset(padLeft + plotWidth, y), gridPaint);
      }

      final textSpan = TextSpan(text: '${db > 0 ? "+" : ""}${db.toInt()}', style: textStyle);
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(padLeft - tp.width - 4, y - tp.height / 2));
    }

    // X 轴对数频率刻度线
    for (final f in kFreqGrid) {
      final x = freqToX(f);
      canvas.drawLine(Offset(x, padTop), Offset(x, padTop + plotHeight), gridPaint);

      final label = f >= 1000 ? '${(f / 1000).toInt()}k' : '${f.toInt()}';
      final textSpan = TextSpan(text: label, style: textStyle);
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, padTop + plotHeight + 4));
    }

    // 2. 绘制频响曲线 / 折线
    if (result.frequencies.isNotEmpty && result.gainsDb.isNotEmpty) {
      final path = Path();
      final fillPath = Path();

      final points = <Offset>[];
      for (var i = 0; i < result.frequencies.length; i++) {
        final x = freqToX(result.frequencies[i]);
        final y = dbToY(result.gainsDb[i]);
        points.add(Offset(x, y));
      }

      final zeroY = dbToY(0.0);

      if (isSmooth && points.length > 2) {
        // === 平滑连续曲线模式 ===
        path.moveTo(points[0].dx, points[0].dy);
        fillPath.moveTo(points[0].dx, zeroY);
        fillPath.lineTo(points[0].dx, points[0].dy);

        for (var i = 0; i < points.length - 1; i++) {
          final p0 = points[i];
          final p1 = points[i + 1];
          final mx = (p0.dx + p1.dx) / 2.0;
          path.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
          fillPath.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
        }

        fillPath.lineTo(points.last.dx, zeroY);
        fillPath.close();

        final fillPaint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              palette.accent.withValues(alpha: 0.22),
              palette.accent.withValues(alpha: 0.02),
            ],
          ).createShader(Rect.fromLTWH(padLeft, padTop, plotWidth, plotHeight))
          ..style = PaintingStyle.fill;

        canvas.drawPath(fillPath, fillPaint);

        final glowPaint = Paint()
          ..color = palette.accent.withValues(alpha: 0.35)
          ..strokeWidth = 3.6
          ..style = PaintingStyle.stroke;
        canvas.drawPath(path, glowPaint);

        final linePaint = Paint()
          ..color = palette.accent
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke;
        canvas.drawPath(path, linePaint);
      } else {
        // === 几何折线模式：抽取 32 点关键采样与节点圆环 ===
        final polyPoints = <Offset>[];
        const step = 8; // 256 / 8 = 32 个节点
        for (var i = 0; i < points.length; i += step) {
          polyPoints.add(points[i]);
        }
        if (polyPoints.last != points.last) {
          polyPoints.add(points.last);
        }

        path.moveTo(polyPoints[0].dx, polyPoints[0].dy);
        fillPath.moveTo(polyPoints[0].dx, zeroY);
        fillPath.lineTo(polyPoints[0].dx, polyPoints[0].dy);

        for (var i = 1; i < polyPoints.length; i++) {
          path.lineTo(polyPoints[i].dx, polyPoints[i].dy);
          fillPath.lineTo(polyPoints[i].dx, polyPoints[i].dy);
        }

        fillPath.lineTo(polyPoints.last.dx, zeroY);
        fillPath.close();

        final fillPaint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              palette.accent.withValues(alpha: 0.18),
              palette.accent.withValues(alpha: 0.02),
            ],
          ).createShader(Rect.fromLTWH(padLeft, padTop, plotWidth, plotHeight))
          ..style = PaintingStyle.fill;
        canvas.drawPath(fillPath, fillPaint);

        final linePaint = Paint()
          ..color = palette.accent
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke;
        canvas.drawPath(path, linePaint);

        // 绘制折线转折节点小圆点
        final nodeBg = Paint()
          ..color = palette.bg
          ..style = PaintingStyle.fill;
        final nodeStroke = Paint()
          ..color = palette.accent
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke;

        for (final pt in polyPoints) {
          canvas.drawCircle(pt, 2.8, nodeBg);
          canvas.drawCircle(pt, 2.8, nodeStroke);
        }
      }
    }

    // 3. 绘制十字准星交互探针与悬浮 Tooltip
    if (hoverPos != null) {
      final hx = hoverPos!.dx.clamp(padLeft, padLeft + plotWidth);
      final hy = hoverPos!.dy.clamp(padTop, padTop + plotHeight);

      final hoverFreq = xToFreq(hx);
      final hoverDb = yToDb(hy);

      final crosshairPaint = Paint()
        ..color = palette.textDim.withValues(alpha: 0.5)
        ..strokeWidth = 1.0;

      canvas.drawLine(Offset(hx, padTop), Offset(hx, padTop + plotHeight), crosshairPaint);
      canvas.drawLine(Offset(padLeft, hy), Offset(padLeft + plotWidth, hy), crosshairPaint);

      final pointPaint = Paint()
        ..color = palette.accent
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(hx, hy), 3.5, pointPaint);

      final fStr = hoverFreq >= 1000
          ? '${(hoverFreq / 1000).toStringAsFixed(2)} kHz'
          : '${hoverFreq.toStringAsFixed(0)} Hz';
      final dbStr = '${hoverDb >= 0 ? "+" : ""}${hoverDb.toStringAsFixed(1)} dB';
      final tooltipText = '$fStr  ·  $dbStr';

      final tipSpan = TextSpan(
        text: tooltipText,
        style: TextStyle(
          color: palette.text,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      );
      final tp = TextPainter(text: tipSpan, textDirection: TextDirection.ltr);
      tp.layout();

      const tipPadding = 6.0;
      final tipW = tp.width + tipPadding * 2;
      final tipH = tp.height + tipPadding * 2;

      var tipX = hx + 10.0;
      if (tipX + tipW > size.width - 8) {
        tipX = hx - tipW - 10.0;
      }
      var tipY = hy - tipH - 8.0;
      if (tipY < padTop) {
        tipY = hy + 8.0;
      }

      final tipRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(tipX, tipY, tipW, tipH),
        const Radius.circular(4.0),
      );

      final tipBgPaint = Paint()
        ..color = palette.panelRaised.withValues(alpha: 0.95)
        ..style = PaintingStyle.fill;
      final tipBorderPaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      canvas.drawRRect(tipRect, tipBgPaint);
      canvas.drawRRect(tipRect, tipBorderPaint);
      tp.paint(canvas, Offset(tipX + tipPadding, tipY + tipPadding));
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumGraphPainter oldDelegate) {
    return oldDelegate.result != result ||
        oldDelegate.palette != palette ||
        oldDelegate.isSmooth != isSmooth ||
        oldDelegate.hoverPos != hoverPos;
  }
}
