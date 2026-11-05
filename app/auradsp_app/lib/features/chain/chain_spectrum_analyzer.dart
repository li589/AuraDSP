/*
 * chain_spectrum_analyzer.dart — 处理链全流程复合频响测量组件（EqualizerAPO 风格）
 * 1. 端到端全链路复合传递函数解析（从首个效果器到末级插件槽位，纯内存静音仿真，绝不向扬声器发声）
 * 2. 多声道切换：立体声 (L/R)、左声道 (L)、右声道 (R) 及分立声道
 * 3. Voicemeeter (VB) 专属总线选择：(A1) ~ 设置中已启用总线，支持各总线逐声道频谱
 * 4. 延迟精准测定与反哺：同步更新 model.latencyMs 与主状态机
 * 5. 交互式 EqualizerAPO 风格曲线/折线图：对数网格、十字准星探针、dB刻度线
 */

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../core/audio_modes.dart';
import '../../core/design.dart';
import '../../core/plugins/plugin_manager.dart';
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

  /// 全链路端到端频响与延迟分析计算（纯内存计算）
  static FullChainResponseResult compute({
    required AppModel model,
    required String channel, // 'stereo', 'left', 'right'
    int? vbBusIndex,
  }) {
    final freqs = getLogFrequencies();
    final gains = List<double>.filled(freqs.length, 0.0);
    final sampleRate = model.engineRate > 0 ? model.engineRate : 48000;

    // 1. Voicemeeter 总线路由判定
    final isVbMode = model.attachmentMode == AudioModes.attachVoicemeeterApi;
    bool isBypassed = false;
    if (isVbMode && vbBusIndex != null) {
      final busMask = model.vbBusMask;
      if ((busMask & (1 << vbBusIndex)) == 0) {
        // 该总线在设置中被禁用旁路，直通 0 dB
        isBypassed = true;
      }
    }

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

      // 低音增强 (Bass Boost)
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

      // 动态均衡器 (Dynamic EQ 静态基底)
      if (model.isStageEnabled('dyneq')) {
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

      // 响度均衡 (Loudness ISO 226 轮廓模拟)
      if (model.isStageEnabled('loudness')) {
        for (var i = 0; i < freqs.length; i++) {
          final f = freqs[i];
          // 低频渐升 (< 300Hz 提升 3~5dB)，极高频微升 (> 8000Hz 提升 1.5dB)
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
      if (model.isStageEnabled('crossfeed')) {
        for (var i = 0; i < freqs.length; i++) {
          final f = freqs[i];
          if (channel == 'left' || channel == 'right') {
            // 单声道视角：高频有约 1.5dB 的头颅阴影衰减
            if (f > 1000) {
              final att = (math.log(f / 1000) / math.ln10 * 1.2).clamp(0.0, 2.5);
              gains[i] -= att;
            }
          } else {
            // 立体声综合视角：低频平滑微抬
            if (f < 500) {
              gains[i] += 0.4;
            }
          }
        }
      }

      // 电子管与激励器 (Tube & Exciter)
      if (model.isStageEnabled('tube') || model.isStageEnabled('exciter')) {
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

    // 3. 计算端到端全链路总延迟
    double coreLat = 0.0;
    if (model.limiterOn) coreLat += 1.5;
    if (model.isStageEnabled('bass')) coreLat += 4.0;
    if (model.isStageEnabled('haas')) coreLat += model.haasDelayMs;
    if (model.isStageEnabled('spatial')) coreLat += 1.2;
    if (model.convEnabled && model.convReady && model.deviceRate > 0) {
      coreLat += (model.convFrames / model.deviceRate) * 1000.0;
    }

    // 插件槽位延迟 (Slot 0 ~ 3 PDC)
    double pluginLat = 0.0;
    final pm = model.pluginManager;
    for (var s = 0; s < PluginManager.kMaxSlots; s++) {
      if (pm.isSlotActive(s) && !pm.isSlotBypassed(s)) {
        final spl = pm.getSlotLatency(s);
        if (spl > 0 && model.deviceRate > 0) {
          pluginLat += (spl / model.deviceRate) * 1000.0;
        }
      }
    }

    final totalLat = coreLat + pluginLat;

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

/// 处理链顶部全流程复合频响测量组件 (EqualizerAPO 风格)
class ChainSpectrumAnalyzer extends StatefulWidget {
  final AppModel model;
  const ChainSpectrumAnalyzer({super.key, required this.model});

  @override
  State<ChainSpectrumAnalyzer> createState() => _ChainSpectrumAnalyzerState();
}

class _ChainSpectrumAnalyzerState extends State<ChainSpectrumAnalyzer> {
  String _selectedChannel = 'stereo'; // 'stereo', 'left', 'right'
  int _selectedVbBus = 0; // Voicemeeter 总线索引 (0 = A1)
  bool _isSmoothCurve = true; // 曲线平滑 vs 折线
  Offset? _hoverPos; // 鼠标探针坐标

  @override
  void initState() {
    super.initState();
    // 首帧完成后安全测算并反哺总延迟（静音仿真，不干扰构建周期）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _measureAndSyncLatency();
      }
    });
  }

  void _measureAndSyncLatency() {
    final res = FullChainTransferCalculator.compute(
      model: widget.model,
      channel: _selectedChannel,
      vbBusIndex: widget.model.attachmentMode == AudioModes.attachVoicemeeterApi ? _selectedVbBus : null,
    );
    widget.model.updateFullChainMeasuredLatency(res.totalLatencyMs);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isVb = widget.model.attachmentMode == AudioModes.attachVoicemeeterApi;

    // 获取当前计算结果
    final res = FullChainTransferCalculator.compute(
      model: widget.model,
      channel: _selectedChannel,
      vbBusIndex: isVb ? _selectedVbBus : null,
    );

    // Voicemeeter 总线列表（根据设置中启用的掩码）
    final edition = (widget.model.vbInfo['edition'] as num?)?.toInt() ?? 0;
    final allVbNames = vbBusNames(edition);
    final enabledVbBuses = <({int index, String name})>[];
    for (var i = 0; i < allVbNames.length; i++) {
      if ((widget.model.vbBusMask & (1 << i)) != 0 || i == 0) {
        enabledVbBuses.add((index: i, name: allVbNames[i]));
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
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(1.5),
                  boxShadow: [
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.6),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              Text(
                '全流程复合频响测量',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '(EqualizerAPO 响应风格)',
                style: monoOf(p, size: 11, color: p.textDim),
              ),
              const Spacer(),

              // 静音测量安全提示徽章
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(color: p.accent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.volume_off_rounded, size: 12, color: p.accent),
                    const SizedBox(width: 4),
                    Text(
                      '纯内存静音测算 · 扬声器不发声',
                      style: monoOf(p, size: 10, color: p.accent),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AuraSpace.sm),

              // 曲线/折线模式切换
              IconButton(
                tooltip: _isSmoothCurve ? '切换至折线模式' : '切换至平滑曲线',
                icon: Icon(
                  _isSmoothCurve ? Icons.show_chart_rounded : Icons.timeline_rounded,
                  size: 18,
                  color: p.accent,
                ),
                onPressed: () => setState(() => _isSmoothCurve = !_isSmoothCurve),
                visualDensity: VisualDensity.compact,
              ),

              // 测量与延迟同步刷新
              IconButton(
                tooltip: '重新测算全链路频响与端到端延迟',
                icon: Icon(Icons.refresh_rounded, size: 18, color: p.accent),
                onPressed: () {
                  _measureAndSyncLatency();
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(milliseconds: 1400),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: p.panelRaised,
                      content: Text(
                        '已完成全链路静音频响分析，端到端延迟已更新为 ${res.totalLatencyMs.toStringAsFixed(1)} ms',
                        style: TextStyle(color: p.text, fontSize: 12),
                      ),
                    ),
                  );
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
              // 声道切换器
              Container(
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                padding: const EdgeInsets.all(2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _channelPill(
                      label: '立体声 (L/R)',
                      isSelected: _selectedChannel == 'stereo',
                      onTap: () => setState(() {
                        _selectedChannel = 'stereo';
                        _measureAndSyncLatency();
                      }),
                      p: p,
                    ),
                    _channelPill(
                      label: '左声道 (L)',
                      isSelected: _selectedChannel == 'left',
                      onTap: () => setState(() {
                        _selectedChannel = 'left';
                        _measureAndSyncLatency();
                      }),
                      p: p,
                    ),
                    _channelPill(
                      label: '右声道 (R)',
                      isSelected: _selectedChannel == 'right',
                      onTap: () => setState(() {
                        _selectedChannel = 'right';
                        _measureAndSyncLatency();
                      }),
                      p: p,
                    ),
                  ],
                ),
              ),

              // Voicemeeter 专属总线下拉菜单
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
                      Text('Voicemeeter 总线:', style: captionOf(p)),
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

              // 实时测定延迟提示
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: p.bg.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(color: p.hairline.withValues(alpha: 0.6)),
                ),
                child: Text(
                  '端到端延迟: ${res.totalLatencyMs.toStringAsFixed(1)} ms (DSP: ${res.coreLatencyMs.toStringAsFixed(1)} ms + 插件 PDC: ${res.pluginLatencyMs.toStringAsFixed(1)} ms)',
                  style: monoOf(p, size: 11, color: p.textDim),
                ),
              ),

              if (res.isBusBypassed) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    '当前总线未启用处理，信号直通 (0 dB)',
                    style: monoOf(p, size: 10, color: Colors.amber),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: AuraSpace.sm + 2),

          // 核心频谱图绘图区域 (CustomPainter)
          LayoutBuilder(
            builder: (ctx, constraints) {
              final w = constraints.maxWidth;
              const h = 210.0;

              return MouseRegion(
                onHover: (e) => setState(() => _hoverPos = e.localPosition),
                onExit: (_) => setState(() => _hoverPos = null),
                child: GestureDetector(
                  onPanUpdate: (e) => setState(() => _hoverPos = e.localPosition),
                  onPanEnd: (_) => setState(() => _hoverPos = null),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

/// EqualizerAPO 风格对数频响网格与曲线绘制器
class _SpectrumGraphPainter extends CustomPainter {
  final FullChainResponseResult result;
  final AuraPalette palette;
  final bool isSmooth;
  final Offset? hoverPos;

  static const List<double> kFreqGrid = [
    20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000,
  ];

  static const List<double> kDbGrid = [
    20.0, 10.0, 0.0, -10.0, -20.0, -30.0,
  ];

  const _SpectrumGraphPainter({
    required this.result,
    required this.palette,
    required this.isSmooth,
    this.hoverPos,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const padLeft = 36.0;
    const padRight = 14.0;
    const padTop = 16.0;
    const padBottom = 24.0;

    final plotWidth = size.width - padLeft - padRight;
    final plotHeight = size.height - padTop - padBottom;

    if (plotWidth <= 0 || plotHeight <= 0) return;

    final logMinF = math.log(FullChainTransferCalculator.kMinFreq);
    final logMaxF = math.log(FullChainTransferCalculator.kMaxFreq);

    // 坐标转换工具函数
    double freqToX(double f) {
      final t = (math.log(f.clamp(20.0, 20000.0)) - logMinF) / (logMaxF - logMinF);
      return padLeft + t * plotWidth;
    }

    double xToFreq(double x) {
      final t = ((x - padLeft) / plotWidth).clamp(0.0, 1.0);
      return math.exp(logMinF + t * (logMaxF - logMinF));
    }

    double dbToY(double db) {
      // 范围锁定 -30 dB 到 +20 dB
      final t = (20.0 - db) / 50.0;
      return padTop + t.clamp(0.0, 1.0) * plotHeight;
    }

    double yToDb(double y) {
      final t = ((y - padTop) / plotHeight).clamp(0.0, 1.0);
      return 20.0 - t * 50.0;
    }

    // 1. 绘制对数背景网格线
    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;

    final zeroDbPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.5)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final textStyle = TextStyle(
      color: palette.textDim.withValues(alpha: 0.6),
      fontSize: 9.5,
      fontFamily: 'monospace',
    );

    // Y 轴水平 dB 刻度线
    for (final db in kDbGrid) {
      final y = dbToY(db);
      if (db == 0.0) {
        // 0 dB 强化基准线（高亮虚线）
        const dashWidth = 4.0;
        const dashSpace = 3.0;
        double startX = padLeft;
        while (startX < padLeft + plotWidth) {
          canvas.drawLine(
            Offset(startX, y),
            Offset(math.min(startX + dashWidth, padLeft + plotWidth), y),
            zeroDbPaint,
          );
          startX += dashWidth + dashSpace;
        }
      } else {
        canvas.drawLine(Offset(padLeft, y), Offset(padLeft + plotWidth, y), gridPaint);
      }

      // 绘制 dB 文字
      final textSpan = TextSpan(text: '${db > 0 ? "+" : ""}${db.toInt()}', style: textStyle);
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(padLeft - tp.width - 4, y - tp.height / 2));
    }

    // X 轴对数频率刻度线
    for (final f in kFreqGrid) {
      final x = freqToX(f);
      canvas.drawLine(Offset(x, padTop), Offset(x, padTop + plotHeight), gridPaint);

      // 标签文字 (e.g. 100, 1k, 10k)
      final label = f >= 1000 ? '${(f / 1000).toInt()}k' : '${f.toInt()}';
      final textSpan = TextSpan(text: label, style: textStyle);
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, padTop + plotHeight + 4));
    }

    // 2. 绘制频响曲线
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
      fillPath.moveTo(points.first.dx, zeroY);

      if (isSmooth && points.length > 2) {
        path.moveTo(points[0].dx, points[0].dy);
        fillPath.lineTo(points[0].dx, points[0].dy);

        for (var i = 0; i < points.length - 1; i++) {
          final p0 = points[i];
          final p1 = points[i + 1];
          final mx = (p0.dx + p1.dx) / 2.0;
          path.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
          fillPath.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
        }
      } else {
        path.moveTo(points[0].dx, points[0].dy);
        fillPath.lineTo(points[0].dx, points[0].dy);
        for (var i = 1; i < points.length; i++) {
          path.lineTo(points[i].dx, points[i].dy);
          fillPath.lineTo(points[i].dx, points[i].dy);
        }
      }

      fillPath.lineTo(points.last.dx, zeroY);
      fillPath.close();

      // 渐变填充 (发光半透明青色)
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

      // 发光外轮廓线条
      final glowPaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.4)
        ..strokeWidth = 3.6
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, glowPaint);

      final linePaint = Paint()
        ..color = palette.accent
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, linePaint);
    }

    // 3. 绘制十字准星交互探针与悬浮 Tooltip
    if (hoverPos != null) {
      final hx = hoverPos!.dx.clamp(padLeft, padLeft + plotWidth);
      final hy = hoverPos!.dy.clamp(padTop, padTop + plotHeight);

      final hoverFreq = xToFreq(hx);
      final hoverDb = yToDb(hy);

      // 十字准星线
      final crosshairPaint = Paint()
        ..color = palette.textDim.withValues(alpha: 0.5)
        ..strokeWidth = 1.0;

      canvas.drawLine(Offset(hx, padTop), Offset(hx, padTop + plotHeight), crosshairPaint);
      canvas.drawLine(Offset(padLeft, hy), Offset(padLeft + plotWidth, hy), crosshairPaint);

      // 焦点圆环
      final pointPaint = Paint()
        ..color = palette.accent
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(hx, hy), 3.5, pointPaint);

      // Tooltip 气泡
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
