// part of state.dart —— P6 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// EQ 网格/频点/曲线/预设 + 引擎实测响应探测。
///
/// 原 AppModel 类 static 成员（eqFreqs7/10/15/31、eqGridFor、
/// eqOpModeForFilter、eqPeakingDb、eqTargetGains、eqResponsePoints、
/// _eqCurveMinIntervalMs、composeEqOutputSpectrum）按方案改本文件顶层
/// 声明——均为无实例状态的纯函数/常量；外部调用点（测试）相应由
/// AppModel.xxx 改为裸名。extension 方法体逐字保留自 AppModel 类体
/// （notifyListeners() 按 P2 约定改调 _notifyUi()）。

// 多段图形均衡器（Phase 3）
const List<double> eqFreqs7 = [50, 150, 400, 1000, 3000, 8000, 16000];
const List<double> eqFreqs10 = [
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];
const List<double> eqFreqs15 = [
  25,
  40,
  63,
  100,
  160,
  250,
  400,
  630,
  1000,
  1600,
  2500,
  4000,
  6300,
  10000,
  16000,
];
const List<double> eqFreqs31 = [
  20,
  25,
  31.5,
  40,
  50,
  63,
  80,
  100,
  125,
  160,
  200,
  250,
  315,
  400,
  500,
  630,
  800,
  1000,
  1250,
  1600,
  2000,
  2500,
  3150,
  4000,
  5000,
  6300,
  8000,
  10000,
  12500,
  16000,
  20000,
];

/// C4：按当前采样率裁掉超过 Nyquist 的频带。
///
/// 出厂网格是硬编码常量，顶端到 20 kHz，与采样率无关。原先在
/// `_pushEqCurve` 里逐点 `math.min(f, nyquist)` 钳位 —— 这会让**多条
/// 频带塌缩到同一个频率**：24 kHz（Nyquist 12k）下 31 段网格的
/// 12500/16000/20000 三条全部变成 12000，连同 6300 以上的一串，
/// 最终 31 个点塌成大量重复。引擎拿到这条退化坐标轴后，
/// vendor 的 makima 在等距零点上求差分，插值结果毫无意义。
///
/// 正确做法是**按频率裁掉整条频带**，让网格始终严格升序无重复；
/// 增益随频带一起丢弃（`setEqBandsCount` 的重映射已按频率对齐，
/// 低频段行为不受影响）。
///
/// Nyquist 上限取 fs/2 并留一点点余量：恰好等于 Nyquist 的频点
/// 在最小相位 IR 设计里仍属边界，稳妥起见一并裁掉。
List<double> eqGridFor(int count, int sampleRate) {
  final List<double> base = switch (count) {
    7 => eqFreqs7,
    10 => eqFreqs10,
    31 => eqFreqs31,
    _ => eqFreqs15,
  };
  if (sampleRate <= 0) return List<double>.from(base);
  final double nyq = sampleRate / 2.0;
  if (nyq >= 20000.0) return List<double>.from(base);
  final cut = base.where((f) => f < nyq * 0.995).toList();
  /* 极端采样率下（如 8 kHz，Nyquist 4k）可能一条不剩。
   * 此时退回该网格的最低频点，保住「至少一个锚点」——
   * 空网格会让引擎拒绝整条曲线（build_eq_axis 要求 >=2 点），
   * 那比一条退化但可用的曲线更糟。 */
  if (cut.isEmpty) return <double>[base.first];
  return cut;
}

/// UI 架构选项 → vendor `operatingMode`。
///
/// 0 = 最小相位 FIR（默认，与探针同路）；
/// 1 = 6 阶 IIR（`operatingMode=2`）；
/// 2 = 12 阶 IIR（`operatingMode=5`）。
/// 未知值回退到 FIR，保证可听、可测。
int eqOpModeForFilter(int filter) => switch (filter) {
  1 => 2,
  2 => 5,
  _ => 0,
};

/// 单座 RBJ 峰值钟形在频率 f 处的幅度（dB）。
///
/// Q 的语义与教科书参数均衡器一致：Q 越大钟形越窄。
/// 增益为 0 时恒返回 0（此时 Q 无声学意义，也不该影响目标曲线）。
double eqPeakingDb({
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
  final magSq =
      (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm);
  if (magSq <= 0) return 0.0;
  return 10.0 * math.log(magSq) / math.ln10;
}

/// 把“各频点峰值增益 + 各点 Q”合成为引擎目标曲线。
///
/// 对目标轴上每个频点，把全部钟形按 dB 相加（级联参量均衡的幅度叠加律）。
/// 返回值与 [targetFreqs] 等长，可直接序列化为 `eq.curve` 的增益列。
List<double> eqTargetGains({
  required List<double> targetFreqs,
  required List<double> centers,
  required List<double> peakGains,
  required List<double> qs,
  required int sampleRate,
}) {
  final n = math.min(centers.length, math.min(peakGains.length, qs.length));
  return List<double>.generate(targetFreqs.length, (i) {
    var total = 0.0;
    for (var b = 0; b < n; b++) {
      total += eqPeakingDb(
        f: targetFreqs[i],
        center: centers[b],
        gainDb: peakGains[b],
        q: qs[b],
        sampleRate: sampleRate,
      );
    }
    return total;
  });
}

// A3: eq.curve 合并下发。拖滑块约 60Hz 触发，而引擎侧
// MultimodalEqualizerAxisInterpolation（makima + 最小相位 IR + FFT 卷积刷新）
// 实测约 760µs，且运行在驱动 WASAPI 的音频 isolate 上，会挤掉渲染回调造成爆音。
// 这里合并为 ≤20Hz 并保证尾部补发；UI 的 notifyListeners 仍即时，不影响手感。
const int _eqCurveMinIntervalMs = 50;

/* ---- C2：UI 曲线消费引擎实测响应 ----
 *
 * UI 原本在 log-f 上做 smoothstep 插值，而引擎走 makima + 最小相位 IR +
 * FFT 卷积 —— 最小相位化会引入过冲与频带间相互影响，两者本就不等
 * （实测最大偏差 2.61 dB）。这里让 UI 改画引擎的实测值。
 *
 * 探针一次约 29 ms，因此：
 *   - **绝不放进音频 isolate**（会挤掉渲染回调，P-006 的爆音成因）；
 *   - 只在拖拽**停下**后防抖触发，不逐帧调；
 *   - 按曲线字符串缓存，重复请求直接命中；
 *   - 失败时保留上一帧，绝不让 UI 变瞎。
 */
const int eqResponsePoints = 129;

/// 合成「均衡器输出频谱」：把引擎下发的 EQ 输入谱叠加实测响应。
///
/// EQ 位于 libjamesdsp 的单体链内部（processFloatMultiplexd 一次跑完全链），
/// 拿不到它的输出 tap。但 EQ 是 LTI 系统，逐频点有严格的
/// **|Y(f)| = |X(f)| · |H_eq(f)|**（这是线性系统幅度谱的乘法定理，
/// 与相位无关），而 |H_eq| 正好就是 [eqResponseDb] 测到的东西。
/// 于是输出谱 = 输入谱(dBFS) + 响应(dB)，是精确值而非近似。
///
/// [bypassed] 为 true 时 H_eq ≡ 0（EQ 被旁路，链内不生效），
/// 此时输出谱就等于输入谱——与 [_SpectrumEQPainter] 对曲线的处理一致。
/// [responseCurve] 是 [respDb] 的来源签名，[expectedCurve] 是当前待显示曲线；
/// 两者不一致说明响应尚未追上曲线，此时同样退化为输入谱，而不是用旧响应合成。
List<double> composeEqOutputSpectrum(
  List<double> eqIn,
  List<double>? respDb, {
  bool bypassed = false,
  String? responseCurve,
  String? expectedCurve,
  double? responseFMax,
}) {
  final out = List<double>.filled(VizBands.count, 0);
  final n = eqIn.length < VizBands.count ? eqIn.length : VizBands.count;
  final responseCurrent =
      expectedCurve == null || responseCurve == expectedCurve;
  final flat =
      bypassed || respDb == null || respDb.length < 2 || !responseCurrent;
  for (var b = 0; b < n; b++) {
    if (flat) {
      out[b] = eqIn[b].clamp(0.0, 1.0);
      continue;
    }
    final hz = VizBands.centerHz(b);
    final db =
        VizBands.toDb(eqIn[b].clamp(0.0, 1.0)) +
        VizBands.responseDbAt(respDb, hz, responseFMax: responseFMax);
    out[b] = VizBands.fromDb(db);
  }
  return out;
}

extension EqState on AppModel {

  // ---- 采样率网格重建 ----

  /// C4：按当前采样率重建 EQ 频率网格，增益按**频率**重新映射。
  ///
  /// 裁掉高频带时不能简单截断 gains —— 那样低频段的增益会整体错位。
  /// 这里对每个新频点取旧网格中最接近的旧频点上的增益，
  /// 于是 Nyquist 以内的部分行为完全不变，只有越界的频带连同其增益一起消失。
  void _rebuildEqGridForSampleRate({bool notify = true}) {
    final target = eqGridFor(eqBandsCount, engineRate);
    if (target.isEmpty) return;
    if (target.length == eqFrequencies.length) {
      var same = true;
      for (var i = 0; i < target.length; i++) {
        if ((target[i] - eqFrequencies[i]).abs() > 1e-9) {
          same = false;
          break;
        }
      }
      if (same) return; // 无变化，不必重推曲线
    }
    final oldFreqs = eqFrequencies;
    final oldGains = eqGains;
    final oldQs = eqQs;
    final newGains = <double>[];
    final newQs = <double>[];
    for (final f in target) {
      if (oldFreqs.isEmpty || oldGains.isEmpty) {
        newGains.add(0.0);
        newQs.add(eqQ);
        continue;
      }
      var bi = 0;
      var best = double.infinity;
      for (var i = 0; i < oldFreqs.length; i++) {
        final d = (oldFreqs[i] - f).abs();
        if (d < best) {
          best = d;
          bi = i;
        }
      }
      newGains.add(oldGains[bi]);
      newQs.add(bi < oldQs.length ? oldQs[bi] : eqQ);
    }
    eqFrequencies = target;
    eqGains = newGains;
    eqQs = newQs;
    _pushEqCurve();
    if (notify) _notifyUi();
  }

  // ---- EQ 参数与预设 ----

  void setEqBandsCount(int count) {
    if (count == eqBandsCount) return;
    eqBandsCount = count;
    /* C4：网格按采样率裁剪，避免高频带在 Nyquist 处塌缩成重复点 */
    final newFreqs = eqGridFor(count, engineRate);
    final oldFreqs = eqFrequencies;
    final oldGains = eqGains;
    final oldQs = eqQs;
    final newGains = <double>[];
    final newQs = <double>[];
    for (final f in newFreqs) {
      if (oldFreqs.isEmpty || oldGains.isEmpty) {
        newGains.add(0.0);
        newQs.add(eqQ);
        continue;
      }
      if (f <= oldFreqs.first) {
        newGains.add(oldGains.first);
        newQs.add(oldQs.isNotEmpty ? oldQs.first : eqQ);
      } else if (f >= oldFreqs.last) {
        newGains.add(oldGains.last);
        newQs.add(oldQs.isNotEmpty ? oldQs.last : eqQ);
      } else {
        var idx = 0;
        while (idx < oldFreqs.length - 1 && oldFreqs[idx + 1] < f) {
          idx++;
        }
        final logF0 = math.log(oldFreqs[idx]);
        final logF1 = math.log(oldFreqs[idx + 1]);
        final logTarget = math.log(f);
        final ratio = (logTarget - logF0) / (logF1 - logF0);
        newGains.add(
          oldGains[idx] + ratio * (oldGains[idx + 1] - oldGains[idx]),
        );
        // Q 是频带属性，不做对数插值：取最近频带的 Q，保持钟形宽度语义。
        var bi = 0;
        var best = double.infinity;
        for (var i = 0; i < oldFreqs.length; i++) {
          final d = (oldFreqs[i] - f).abs();
          if (d < best) {
            best = d;
            bi = i;
          }
        }
        newQs.add(bi < oldQs.length ? oldQs[bi] : eqQ);
      }
    }
    eqFrequencies = List.from(newFreqs);
    eqGains = newGains;
    eqQs = newQs;
    _pushEqCurve();
  }

  void setEqBandGain(int index, double gain) {
    if (index >= 0 && index < eqGains.length) {
      eqGains[index] = gain.clamp(-18.0, 18.0);
      eqPresetName = 'custom';
      _pushEqCurve();
    }
  }

  /// 设置单个频点的 Q（0.3~10.0）。
  ///
  /// Q 会进入目标曲线合成（见 [_pushEqCurve]），因此必然改变曲线签名、
  /// 触发引擎重建与响应重测——与增益同一待遇。
  void setEqBandQ(int index, double q) {
    if (index < 0 || index >= eqQs.length) return;
    eqQs[index] = q.clamp(0.3, 10.0);
    eqPresetName = 'custom';
    _pushEqCurve();
  }

  void setEqQ(double q) {
    // 旧版全局 Q：只更新缺省值（新频带补齐与旧预设兼容用），不再重推曲线。
    // 各频点的实际 Q 一律走 [eqQs] + [setEqBandQ]。
    eqQ = q.clamp(0.3, 10.0);
    _notifyUi();
  }

  void setEqFilter(int filter) {
    // 架构选择目前只属于 UI/预设状态，尚未映射到引擎工作模式。
    eqFilter = filter;
    _notifyUi();
  }

  /// 按**频率**应用一条 EQ 曲线（C4）。
  ///
  /// 预设里存的是「频点 + 增益」配对，而载入时的网格由当前采样率与段数决定，
  /// 两者不一定一致。若按下标灌入，低采样率裁掉高频带后整条曲线会错位。
  /// 这里对当前网格的每个频点，取预设中最接近的那个频点上的增益 ——
  /// 于是采样率/段数只影响取样密度，曲线形状不变。
  ///
  /// 预设频点与当前网格无交集时（例如预设来自更高采样率、而当前网格低到
  /// 只能覆盖极低频）则整体取预设的第一个增益，至少不丢整条曲线。
  void applyEqCurve(List<double> freqs, List<double> gains) {
    if (freqs.isEmpty || gains.isEmpty) return;
    if (freqs.length != gains.length) {
      applyEqGains(gains);
      return;
    }
    final out = List<double>.filled(eqFrequencies.length, 0.0);
    for (var i = 0; i < eqFrequencies.length; i++) {
      final f = eqFrequencies[i];
      var bi = 0;
      var best = double.infinity;
      for (var k = 0; k < freqs.length; k++) {
        final d = (freqs[k] - f).abs();
        if (d < best) {
          best = d;
          bi = k;
        }
      }
      out[i] = gains[bi].clamp(-18.0, 18.0);
    }
    for (var i = 0; i < eqGains.length; i++) {
      eqGains[i] = i < out.length ? out[i] : 0.0;
    }
    _pushEqCurve();
  }

  /// 按**频率**应用一条 Q 曲线（与 [applyEqCurve] 同构）。
  ///
  /// 预设/会话里的 `qs` 与当前网格不对齐时，按最近频点重映射；
  /// 长度对不上频率表时按下标截断对齐；缺省用 [eqQ] 补齐。
  void applyEqQs(List<double>? freqs, List<double> qs) {
    if (qs.isEmpty) return;
    final aligned = List<double>.filled(eqFrequencies.length, eqQ);
    if (freqs != null && freqs.length == qs.length && freqs.isNotEmpty) {
      for (var i = 0; i < eqFrequencies.length; i++) {
        final f = eqFrequencies[i];
        var bi = 0;
        var best = double.infinity;
        for (var k = 0; k < freqs.length; k++) {
          final d = (freqs[k] - f).abs();
          if (d < best) {
            best = d;
            bi = k;
          }
        }
        aligned[i] = qs[bi].clamp(0.3, 10.0);
      }
    } else {
      for (var i = 0; i < aligned.length && i < qs.length; i++) {
        aligned[i] = qs[i].clamp(0.3, 10.0);
      }
    }
    eqQs = aligned;
    _pushEqCurve();
  }

  /// 用同一个 Q 填满全部频点（兼容只有标量 `q` 的旧预设/会话）。
  void fillEqQ(double q) {
    eqQ = q.clamp(0.3, 10.0);
    eqQs = List<double>.filled(eqFrequencies.length, eqQ);
    _pushEqCurve();
  }

  /// 整表写入 EQ 增益并重推曲线。
  /// 必须走本方法而不能直接 `eqGains[i] = v`：eqGains 是裸 `List<double>`，
  /// 直接赋值不会触发 _pushEqCurve()，引擎会继续用上一条曲线
  /// （预设恢复 EQ 时就是这么丢增益的）。
  void applyEqGains(List<double> gains) {
    for (var i = 0; i < gains.length && i < eqGains.length; i++) {
      eqGains[i] = gains[i].clamp(-18.0, 18.0);
    }
    _pushEqCurve();
  }

  void setEqInterp(int interp) {
    // 插值选择目前只属于 UI/预设状态，尚未映射到引擎工作模式。
    eqInterp = interp;
    _notifyUi();
  }

  void toggleEqBypass() {
    eqBypass = !eqBypass;
    setInt('eq.enable', (eqOn && !eqBypass) ? 1 : 0);
    _notifyUi();
  }

  void flattenEq() {
    eqGains = List.filled(eqFrequencies.length, 0.0);
    eqPresetName = 'flat';
    _pushEqCurve();
  }

  void applyEqPreset(String style) {
    eqPresetName = style;
    final newGains = List.filled(eqFrequencies.length, 0.0);
    for (var i = 0; i < eqFrequencies.length; i++) {
      final f = eqFrequencies[i];
      final logF = math.log(f) / math.ln10; // log10
      var g = 0.0;
      switch (style) {
        case 'pop':
          if (logF <= 2.2) {
            g = 3.0 * (1.0 - (logF - 1.3) / 0.9);
          } else if (logF <= 3.2) {
            g = -1.0;
          } else {
            g = 3.0 * ((logF - 3.2) / 1.1);
          }
        case 'rock':
          if (logF <= 2.0) {
            g = 4.5;
          } else if (logF <= 3.0) {
            g = -2.0;
          } else if (logF <= 3.6) {
            g = 1.0;
          } else {
            g = 4.0;
          }
        case 'jazz':
          if (logF <= 2.3) {
            g = 2.5;
          } else if (logF <= 3.3) {
            g = 1.5;
          } else {
            g = -1.0;
          }
        case 'classical':
          if (logF >= 3.0 && logF <= 3.8) {
            g = 1.5;
          } else {
            g = 0.5;
          }
        case 'vocal':
          if (logF <= 2.0) {
            g = -3.5;
          } else if (logF >= 2.8 && logF <= 3.6) {
            g = 4.0;
          } else {
            g = 0.0;
          }
        case 'smile':
          final x = (logF - 2.8) / 1.5;
          g = (x * x) * 8.0 - 3.0;
        case 'bass_boost':
          if (logF <= 2.3) {
            g = 6.0 * (1.0 - (logF - 1.3) / 1.0);
          } else {
            g = 0.0;
          }
        case 'treble_boost':
          if (logF >= 3.3) {
            g = 5.0 * ((logF - 3.3) / 1.0);
          } else {
            g = 0.0;
          }
        case 'flat':
        default:
          g = 0.0;
      }
      newGains[i] = g.clamp(-18.0, 18.0);
    }
    eqGains = newGains;
    _pushEqCurve();
  }

  // ---- 曲线节流下发 ----

  void _pushEqCurve() {
    // C3：锚点与频点都必须落在 Nyquist 以内。引擎原先只按 f<=96000 校验，
    // 低采样率（如 32k，Nyquist=16k）下硬编码的 20000 锚点会变成越界点。
    final nyquist = math.min(20000.0, engineRate / 2.0);
    // 先列出要序列化的目标频率轴（含 20Hz 起点与 Nyquist 终点），
    // 再按各频点峰值增益 + Q 合成该轴上的目标增益（见 [eqTargetGains]）。
    final axis = <double>[];
    if (eqFrequencies.isNotEmpty && eqFrequencies.first > 20) {
      axis.add(20.0);
    }
    for (var i = 0; i < eqFrequencies.length; i++) {
      axis.add(math.min(eqFrequencies[i], nyquist));
    }
    if (eqFrequencies.isNotEmpty && eqFrequencies.last < nyquist) {
      axis.add(nyquist);
    }
    final target = eqTargetGains(
      targetFreqs: axis,
      centers: eqFrequencies,
      peakGains: eqGains,
      qs: eqQs,
      sampleRate: engineRate,
    );
    final buffer = StringBuffer(
      'eqm:$eqInterp:${eqOpModeForFilter(eqFilter)};',
    );
    for (var i = 0; i < axis.length; i++) {
      buffer.write(
        '${axis[i].toStringAsFixed(1)}:${target[i].toStringAsFixed(1)}',
      );
      if (i < axis.length - 1) buffer.write(';');
    }
    final curve = buffer.toString();
    // 内容完全相同时不再重推：Q 在平直频带上本就无声学意义，
    // 重推只会白白触发一次 EQ 卷积重建。
    if (curve == _pendingEqCurve || curve == eqResponseCurve) {
      _notifyUi();
      return;
    }
    _pendingEqCurve = curve;
    _flushEqCurve();
    _scheduleEqResponse();
    _notifyUi();
  }

  /// 带尾部补发的节流。
  ///
  /// 注意：不能在每次调用时取消并重建定时器——持续拖拽下定时器会被无限推迟，
  /// 曲线将永不更新。这里只在没有定时器在跑时补一个，保证每周期必发一次。
  void _flushEqCurve() {
    final pending = _pendingEqCurve;
    if (pending == null) return;
    final elapsed = DateTime.now()
        .difference(_lastEqCurveSentAt)
        .inMilliseconds;
    if (elapsed >= _eqCurveMinIntervalMs) {
      _eqCurveTimer?.cancel();
      _eqCurveTimer = null;
      _pendingEqCurve = null;
      _lastEqCurveSentAt = DateTime.now();
      setStringParam('eq.curve', pending);
    } else {
      _eqCurveTimer ??= Timer(
        Duration(milliseconds: _eqCurveMinIntervalMs - elapsed),
        _flushEqCurve,
      );
    }
  }

  // ---- 引擎响应探测 ----

  /// 当前应显示的 EQ 曲线签名：待下发的新曲线优先，已测得的旧曲线次之。
  ///
  /// 响应探针有约 220ms 防抖，曲线变化后响应必然滞后。用该签名调用合成或绘制，
  /// 才能在响应追上之前退化，而不是用旧响应合成出一条已不存在的输出谱。
  String? get currentEqCurveSignature => _pendingEqCurve ?? eqResponseCurve;

  /// 用模型当前状态合成 EQ 输出谱：全局关闭或旁路时退化为输入谱，
  /// 响应签名过期时同样退化为输入谱。
  List<double> eqOutputSpectrum() {
    return composeEqOutputSpectrum(
      eqInSpectrum.value,
      eqResponseDb,
      bypassed: !isEqActive,
      responseCurve: eqResponseCurve,
      expectedCurve: currentEqCurveSignature,
      responseFMax: eqResponseFMax,
    );
  }

  AuraDspLib? get _probeLib {
    _ffiLib ??= () {
      try {
        return AuraDspLib.load();
      } catch (_) {
        return null; // DLL 缺失：UI 退回近似曲线，不崩
      }
    }();
    return _ffiLib;
  }

  void _scheduleEqResponse() {
    _eqResponseTimer?.cancel();
    _eqResponseTimer = Timer(const Duration(milliseconds: 220), () {
      _eqResponseTimer = null;
      final c = _pendingEqCurve;
      if (c == null || c == eqResponseCurve) return; // 缓存命中，无需重算
      final lib = _probeLib;
      if (lib == null) return;
      List<double>? db;
      try {
        db = lib.measureEqResponse(c, engineRate, nPoints: eqResponsePoints);
      } catch (_) {
        return; // 探针异常：保留上一帧曲线
      }
      if (db == null) return;
      eqResponseDb = db;
      eqResponseCurve = c;
      eqResponseFMax = AuraDspLib.responseFMax(sampleRate: engineRate);
      _notifyUi();
    });
  }
}
