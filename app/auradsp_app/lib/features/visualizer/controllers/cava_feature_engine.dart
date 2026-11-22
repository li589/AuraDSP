import 'dart:math' as math;

/// CAVA 标准音频可视化特征引擎 (Dart 高性能实现)
///
/// 算法对齐：karlstav/cava (MIT License)
/// 核心特性：
/// 1. 可变对数分频 (16 ~ 128 频段)
/// 2. ISO 226 感知等响度补偿曲线加权 (pow(f, 0.85))
/// 3. 二次物理重力下坠 + 0.77 积分降噪平滑滤波
/// 4. 实时动态自适应灵敏度 (Autosens AGC)，防止爆顶或沉寂
/// 5. 帧渲染零内存分配约定 (预分配原地复用缓冲)
class CavaFeatureEngine {
  int _barCount = 32;
  double _noiseReduction = 0.77;
  bool _autosens = true;
  double _sens = 1.0;
  final double _framerate = 60.0;

  // 预分配复用缓冲
  final List<double> _cavaOut = [];
  final List<double> _cavaMem = [];
  final List<double> _cavaPeak = [];
  final List<double> _cavaFall = [];
  final List<double> _prevOut = [];
  final List<double> _cutoffs = [];
  final List<double> _eqWeights = [];
  final List<double> _resampled = [];

  List<double> get processedBands => _cavaOut;
  double get currentSensitivity => _sens;
  int get barCount => _barCount;

  CavaFeatureEngine({
    int barCount = 32,
    double noiseReduction = 0.77,
    bool autosens = true,
  }) {
    configure(
      barCount: barCount,
      noiseReduction: noiseReduction,
      autosens: autosens,
    );
  }

  /// 配置引擎参数与对数频带边界
  void configure({
    int? barCount,
    double? noiseReduction,
    bool? autosens,
    int lowCutOff = 50,
    int highCutOff = 12000,
  }) {
    if (barCount != null && barCount != _barCount) {
      _barCount = barCount.clamp(16, 128);
    }
    if (noiseReduction != null) {
      _noiseReduction = noiseReduction.clamp(0.0, 1.0);
    }
    if (autosens != null) {
      _autosens = autosens;
    }

    _ensureBuffers(_barCount);
    _computeLogBands(lowCutOff, highCutOff);
  }

  void _ensureBuffers(int count) {
    if (_cavaOut.length == count) return;
    _cavaOut
      ..clear()
      ..addAll(List.filled(count, 0.0));
    _cavaMem
      ..clear()
      ..addAll(List.filled(count, 0.0));
    _cavaPeak
      ..clear()
      ..addAll(List.filled(count, 0.0));
    _cavaFall
      ..clear()
      ..addAll(List.filled(count, 0.0));
    _prevOut
      ..clear()
      ..addAll(List.filled(count, 0.0));
    _cutoffs
      ..clear()
      ..addAll(List.filled(count + 1, 0.0));
    _eqWeights
      ..clear()
      ..addAll(List.filled(count, 0.0));
    _resampled
      ..clear()
      ..addAll(List.filled(count, 0.0));
  }

  void _computeLogBands(int lowCut, int highCut) {
    final n = _barCount;
    final freqConst = math.log(lowCut / highCut) /
        math.ln10 /
        (1.0 / (n + 1.0) - 1.0);

    for (var i = 0; i < n + 1; i++) {
      final coef = -freqConst + ((i + 1.0) / (n + 1.0)) * freqConst;
      _cutoffs[i] = highCut * math.pow(10.0, coef).toDouble();
    }

    // 计算感知等响加权 (pow(f, 0.85) 补偿人耳高频衰减)
    for (var i = 0; i < n; i++) {
      final f = _cutoffs[i + 1];
      _eqWeights[i] = (math.pow(f, 0.85) / 1200.0).clamp(0.5, 2.2);
    }
  }

  /// 重置物理状态
  void reset() {
    for (var i = 0; i < _barCount; i++) {
      _cavaOut[i] = 0.0;
      _cavaMem[i] = 0.0;
      _cavaPeak[i] = 0.0;
      _cavaFall[i] = 0.0;
      _prevOut[i] = 0.0;
    }
    _sens = 1.0;
  }

  /// 核心处理帧：将原始输入频带转换为 CAVA 高保真物理特征
  List<double> process(
    List<double> rawBands, {
    double manualSensitivity = 1.0,
  }) {
    if (rawBands.isEmpty) return const [];
    _ensureBuffers(_barCount);

    // 1. 将输入频带重采样到目标频段数 (写入 _resampled 零分配)
    _resampleInto(rawBands, _barCount);

    var overshoot = false;
    var silence = true;

    final framerateMod = 60.0 / _framerate;
    final nr = _noiseReduction > 0.05 ? _noiseReduction : 0.05;
    final gravityMod = math.pow(framerateMod, 2.5) * 2.0 / nr;
    final integralMod = math.pow(framerateMod, 0.1);

    for (var i = 0; i < _barCount; i++) {
      // 2. 感知等响度加权
      var val = _resampled[i] * _eqWeights[i] * manualSensitivity;
      if (val > 1e-4) silence = false;

      // 3. 灵敏度增益
      if (_autosens) {
        val *= _sens;
      }

      // 4. 重力物理跌落 (Falloff)
      if (val < _prevOut[i] && _noiseReduction > 0.1) {
        final fallen =
            _cavaPeak[i] * (1.0 - (_cavaFall[i] * _cavaFall[i] * gravityMod));
        val = math.max(0.0, fallen);
        _cavaFall[i] += 0.028;
      } else {
        _cavaPeak[i] = val;
        _cavaFall[i] = 0.0;
      }
      _prevOut[i] = val;

      // 5. 积分降噪平滑滤波 (Integral Smoothing，保增益归一)
      val = _cavaMem[i] * (_noiseReduction / integralMod) +
          val * (1.0 - _noiseReduction);
      _cavaMem[i] = val;

      // 6. 溢出检测 (Autosens 驱动)
      if (val > 1.0) {
        overshoot = true;
        val = 1.0;
      } else if (val < 0.0) {
        val = 0.0;
      }

      _cavaOut[i] = val;
    }

    // 7. CAVA 自动灵敏度 AGC 调节循环
    if (_autosens) {
      if (overshoot) {
        _sens *= (1.0 - 0.02 * framerateMod);
        if (_sens < 0.1) _sens = 0.1;
      } else if (!silence) {
        _sens *= (1.0 + 0.001 * framerateMod);
        if (_sens > 50.0) _sens = 50.0;
      }
    }

    return _cavaOut;
  }

  void _resampleInto(List<double> src, int targetCount) {
    if (src.length == targetCount) {
      for (var i = 0; i < targetCount; i++) {
        _resampled[i] = src[i];
      }
      return;
    }

    final ratio = (src.length - 1) / math.max(1, targetCount - 1);
    for (var i = 0; i < targetCount; i++) {
      final srcPos = i * ratio;
      final i0 = srcPos.floor();
      final i1 = math.min(i0 + 1, src.length - 1);
      final frac = srcPos - i0;
      _resampled[i] = src[i0] * (1.0 - frac) + src[i1] * frac;
    }
  }
}
