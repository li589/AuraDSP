import 'dart:collection';
import 'dart:math' as math;

/// 物理重力与双向弹道阻尼峰值引擎
class PeakPhysicsEngine {
  final List<double> _renderedBands = [];
  final List<double> _peaks = [];
  final List<double> _velocities = [];
  final List<int> _holdTimers = [];

  /// 保持时间（帧数，以 60fps 计约 16 帧 = 260ms）
  static const int _defaultHoldFrames = 16;

  /// 只读视图：防止调用方误改引擎内部状态。
  List<double> get renderedBands => UnmodifiableListView(_renderedBands);
  List<double> get peaks => UnmodifiableListView(_peaks);

  /// 重置并对齐频段数
  void _ensureSize(int count) {
    if (_peaks.length != count) {
      _renderedBands
        ..clear()
        ..addAll(List.filled(count, 0.0));
      _peaks
        ..clear()
        ..addAll(List.filled(count, 0.0));
      _velocities
        ..clear()
        ..addAll(List.filled(count, 0.0));
      _holdTimers
        ..clear()
        ..addAll(List.filled(count, 0));
    }
  }

  /// 一键复位所有峰值与平滑频带
  void reset() {
    for (var i = 0; i < _peaks.length; i++) {
      _renderedBands[i] = 0.0;
      _peaks[i] = 0.0;
      _velocities[i] = 0.0;
      _holdTimers[i] = 0;
    }
  }

  /// 依据输入的归一化频段与物理参数更新渲染柱与峰值保持线
  List<double> update(
    List<double> inputBands, {
    int targetBands = 32,
    double sensitivity = 1.0,
    double gravity = 1.8,
    double decay = 0.6,
  }) {
    if (inputBands.isEmpty) return const [];
    _ensureSize(targetBands);

    // 1. 重采样并应用灵敏度缩放
    final target = _resample(inputBands, targetBands, sensitivity);

    // 2. 频谱柱弹道平滑：即时捕捉瞬态，平滑阻尼回落以消除低频高频闪烁
    final falloffBase = math.max(0.012, (1.0 - decay * 0.45) * 0.05);
    final g = (gravity * 0.0022).clamp(0.001, 0.02);

    for (var i = 0; i < targetBands; i++) {
      final t = target[i];

      // 柱身瞬态与衰减弹道
      if (t >= _renderedBands[i]) {
        _renderedBands[i] = t;
      } else {
        // 低频前4带增加平滑系数，消除鼓点瞬变导致的剧烈视觉闪烁
        final bassSmooth = i < 4 ? 0.72 : 1.0;
        final delta = falloffBase * bassSmooth;
        _renderedBands[i] = math.max(t, _renderedBands[i] - delta);
      }
      _renderedBands[i] = _renderedBands[i].clamp(0.0, 1.0);

      // 3. 峰值保持与重力落体物理计算
      if (t >= _peaks[i]) {
        // 瞬间撞击推高峰值并重置滞空倒计时
        _peaks[i] = t;
        _velocities[i] = 0.0;
        _holdTimers[i] = _defaultHoldFrames;
      } else {
        if (_holdTimers[i] > 0) {
          // 悬停滞空阶段
          _holdTimers[i]--;
        } else {
          // 重力自由落体阶段
          _velocities[i] += g;
          _peaks[i] -= _velocities[i];

          // 碰撞检测：落到柱顶时自然平贴，消除无限回弹与悬空不落
          if (_peaks[i] <= _renderedBands[i]) {
            _peaks[i] = _renderedBands[i];
            _velocities[i] = 0.0;
          }
        }
      }
      _peaks[i] = _peaks[i].clamp(0.0, 1.0);
    }

    return UnmodifiableListView(_peaks);
  }

  /// 频段重采样与灵敏度缩放
  List<double> _resample(List<double> src, int targetCount, double sensitivity) {
    if (src.length == targetCount) {
      if ((sensitivity - 1.0).abs() < 1e-4) {
        return [for (final v in src) v.clamp(0.0, 1.0)];
      }
      return [for (final v in src) (v * sensitivity).clamp(0.0, 1.0)];
    }

    final out = List<double>.filled(targetCount, 0.0);
    final ratio = (src.length - 1) / math.max(1, targetCount - 1);

    for (var i = 0; i < targetCount; i++) {
      final srcPos = i * ratio;
      final i0 = srcPos.floor();
      final i1 = math.min(i0 + 1, src.length - 1);
      final frac = srcPos - i0;
      final interpolated = src[i0] * (1.0 - frac) + src[i1] * frac;
      out[i] = (interpolated * sensitivity).clamp(0.0, 1.0);
    }

    return out;
  }
}
