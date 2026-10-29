import 'dart:math' as math;

/// 物理重力与微回弹峰值保持引擎
class PeakPhysicsEngine {
  final List<double> _peaks = [];
  final List<double> _velocities = [];
  final List<int> _holdTimers = [];

  /// 保持时间（帧数，以 60fps 计约 18 帧 = 300ms）
  static const int _defaultHoldFrames = 18;

  /// 重置并对齐频段数
  void _ensureSize(int count) {
    if (_peaks.length != count) {
      _peaks.clear();
      _velocities.clear();
      _holdTimers.clear();
      _peaks.addAll(List.filled(count, 0.0));
      _velocities.addAll(List.filled(count, 0.0));
      _holdTimers.addAll(List.filled(count, 0));
    }
  }

  /// 一键复位所有峰值保持线
  void reset() {
    for (var i = 0; i < _peaks.length; i++) {
      _peaks[i] = 0.0;
      _velocities[i] = 0.0;
      _holdTimers[i] = 0;
    }
  }

  /// 依据输入的归一化频段与物理参数更新峰值
  List<double> update(
    List<double> inputBands, {
    int targetBands = 32,
    double sensitivity = 1.0,
    double gravity = 1.8,
    double decay = 0.6,
  }) {
    if (inputBands.isEmpty) return const [];
    _ensureSize(targetBands);

    // 重采样至目标频段数（32 或 64）
    final current = _resample(inputBands, targetBands, sensitivity);

    // 物理步进：g 为每帧加速度增量
    final g = (gravity * 0.0016).clamp(0.0004, 0.015);
    final damping = (1.0 - decay * 0.15).clamp(0.85, 0.98);

    for (var i = 0; i < targetBands; i++) {
      final val = current[i];
      if (val >= _peaks[i]) {
        // 瞬间撞击推高峰值并重置滞空倒计时
        _peaks[i] = val;
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
          _velocities[i] *= damping;

          // 碰撞检测：下落穿透当前频谱柱时触发微回弹
          if (_peaks[i] < val) {
            _peaks[i] = val;
            _velocities[i] = -_velocities[i] * 0.25; // 25% 能量反弹
          }
        }
      }
      _peaks[i] = _peaks[i].clamp(0.0, 1.0);
    }

    return _peaks;
  }

  /// 频段重采样与灵敏度缩放
  List<double> _resample(List<double> src, int targetCount, double sensitivity) {
    if (src.length == targetCount) {
      if ((sensitivity - 1.0).abs() < 1e-4) return src;
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

