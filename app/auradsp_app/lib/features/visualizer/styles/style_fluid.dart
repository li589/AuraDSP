import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';

/// 流体动力学：基于 Stable Fluids（Jos Stam）的二维不可压流场模拟
///
/// 与旧的“多层绸带”绘图不同，这里真正求解速度场：
/// 1. 每个频段在画面底部注入上升浮力（低频居中、高频推向两侧），并叠加
///    随频段能量增强的交替横向剪切，让烟柱自然卷曲；
/// 2. 半拉格朗日平流推进速度场，再以压力泊松迭代（8 次 Jacobi）求出压力，
///    减去压力梯度得到无散（不可压）速度场；
/// 3. 染料浓度场在同一速度场中输运并缓慢耗散，模拟墨迹在流体里的扩散。
///
/// 渲染采用一次性顶点网格（每格两个三角形、逐顶点颜色插值），
/// 不使用 MaskFilter.blur / ImageFilter / ui.Image，避免逐帧申请全尺寸图层
/// 或上传纹理；栅格、顶点、颜色与索引缓冲全部复用，只有 ui.Vertices 每帧
/// 新建一次，交由引擎 finalizer 回收。
class FluidDynamicsPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;

  /// CustomPainter 每帧重建，流场状态需跨帧保留，故共享单例。
  static final _FluidField _field = _FluidField();

  FluidDynamicsPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _field.step(animationTime, bands);
    _field.paint(canvas, size, palette, bloom);
  }

  @override
  bool shouldRepaint(covariant FluidDynamicsPainter oldDelegate) => true;
}

/// 固定分辨率的二维流场：速度、染料、压力与散度全部按格心存储。
class _FluidField {
  static const int _nx = 128;
  static const int _ny = 72;
  static const int _cells = _nx * _ny;
  static const int _pressureIterations = 12;
  static const int _lutSize = 128;

  static const int _vertexColumns = _nx + 1;
  static const int _vertexCount = _vertexColumns * (_ny + 1);

  // 速度场与染料场的双缓冲
  final Float32List _u = Float32List(_cells);
  final Float32List _v = Float32List(_cells);
  final Float32List _uPrev = Float32List(_cells);
  final Float32List _vPrev = Float32List(_cells);
  // 速度场 MacCormack 平流的前向/回推中间场
  final Float32List _uForward = Float32List(_cells);
  final Float32List _vForward = Float32List(_cells);
  final Float32List _uBackward = Float32List(_cells);
  final Float32List _vBackward = Float32List(_cells);
  final Float32List _dye = Float32List(_cells);
  final Float32List _dyePrev = Float32List(_cells);
  // MacCormack 平流的前向/回推中间场
  final Float32List _dyeForward = Float32List(_cells);
  final Float32List _dyeBackward = Float32List(_cells);

  // 压力投影与涡量约束用的临时场
  final Float32List _pressure = Float32List(_cells);
  final Float32List _divergence = Float32List(_cells);
  final Float32List _curl = Float32List(_cells);

  // 湍流力场的三角函数按行/列预计算，逐格只做乘加
  final Float32List _waveXSin1 = Float32List(_nx);
  final Float32List _waveXCos1 = Float32List(_nx);
  final Float32List _waveXSin2 = Float32List(_nx);
  final Float32List _waveXCos2 = Float32List(_nx);
  final Float32List _waveXSin3 = Float32List(_nx);
  final Float32List _waveXCos3 = Float32List(_nx);
  final Float32List _waveYSin1 = Float32List(_ny);
  final Float32List _waveYCos1 = Float32List(_ny);
  final Float32List _waveYSin2 = Float32List(_ny);
  final Float32List _waveYCos2 = Float32List(_ny);
  final Float32List _waveYSin3 = Float32List(_ny);
  final Float32List _waveYCos3 = Float32List(_ny);

  // 渲染网格（位置只在尺寸变化时重建，颜色每帧写入）
  final Float32List _positions = Float32List(_vertexCount * 2);
  final Int32List _colors = Int32List(_vertexCount);
  final Uint16List _indices = Uint16List(_nx * _ny * 6);
  final Paint _meshPaint = Paint();

  Size _geometrySize = Size.zero;
  Int32List? _colorTable;
  List<Color>? _tableColors;
  double? _tableBloom;
  Color? _tablePeak;

  double _lastTime = double.nan;
  double _simTime = 0.0;
  bool _primed = false;
  final math.Random _rng = math.Random(0x5F3A21);

  _FluidField() {
    var cursor = 0;
    for (var y = 0; y < _ny; y++) {
      for (var x = 0; x < _nx; x++) {
        final topLeft = y * _vertexColumns + x;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + _vertexColumns;
        final bottomRight = bottomLeft + 1;
        _indices[cursor++] = topLeft;
        _indices[cursor++] = bottomLeft;
        _indices[cursor++] = topRight;
        _indices[cursor++] = topRight;
        _indices[cursor++] = bottomLeft;
        _indices[cursor++] = bottomRight;
      }
    }
  }

  /// 推进一步模拟。[time] 为外部动画时间轴（秒），[bands] 为低→高排列的能量。
  void step(double time, List<double> bands) {
    final dt = _consumeDelta(time);
    if (dt <= 0) return;

    _simTime += dt;
    if (!_primed) {
      _seedDye();
      _primed = true;
    }
    _applyFlow(dt, bands);
    _applyTurbulence(dt, bands);
    _inject(dt, bands);
    _advectVelocity(dt);
    _confineVorticity(dt);
    _project();
    _advectDye(dt);
    _relaxVelocity(dt);
  }

  /// 首帧铺一层很淡的全场染料。
  ///
  /// 只靠底边注入的话，上升流要十几秒才能把染料带到上半屏，切换风格后
  /// 画面下半部浓、上半部空。先撒一层有起伏的底噪，之后它会被涡旋反复
  /// 拉伸、折叠成丝状结构，整屏从一开始就有流体质感。
  void _seedDye() {
    // 白噪声 + 两遍可分离模糊：得到不规则的多尺度云纹。
    // 用解析正弦（如等间距条带）做初值时，流场会把它拉伸成规则网格，
    // 看起来像贴图而不是流体，所以这里必须用伪随机底噪。
    for (var i = 0; i < _cells; i++) {
      _dye[i] = _rng.nextDouble();
    }
    for (var pass = 0; pass < 3; pass++) {
      _blurField(_dye, _dyePrev);
    }

    var maxValue = 1e-4;
    for (var i = 0; i < _cells; i++) {
      if (_dye[i] > maxValue) maxValue = _dye[i];
    }
    // 立方曲线把大部分区域压到接近 0，只留下稀疏的高浓度团块：
    // 全场都是中等浓度时，屏幕上只剩一层均匀的雾，看不出任何流体结构。
    for (var i = 0; i < _cells; i++) {
      final normalized = _dye[i] / maxValue;
      _dye[i] = normalized * normalized * normalized * 0.95;
    }
  }

  /// 可分离的 1-2-1 模糊（先横向后纵向），[temp] 需与 [field] 等长。
  void _blurField(Float32List field, Float32List temp) {
    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final left = field[rowBase + (x > 0 ? x - 1 : 0)];
        final center = field[rowBase + x];
        final right = field[rowBase + (x < _nx - 1 ? x + 1 : _nx - 1)];
        temp[rowBase + x] = (left + center * 2.0 + right) * 0.25;
      }
    }
    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      final upBase = (y > 0 ? y - 1 : 0) * _nx;
      final downBase = (y < _ny - 1 ? y + 1 : _ny - 1) * _nx;
      for (var x = 0; x < _nx; x++) {
        field[rowBase + x] =
            (temp[upBase + x] + temp[rowBase + x] * 2.0 + temp[downBase + x]) *
                0.25;
      }
    }
  }

  /// 计算与上一帧的时间差：首帧、时间回退或异常步长都退化为 1/60。
  double _consumeDelta(double time) {
    if (!_lastTime.isFinite) {
      _lastTime = time;
      return 1.0 / 60.0;
    }
    final raw = time - _lastTime;
    _lastTime = time;
    // 同一时间戳的重复绘制（如尺寸变化触发二次 paint）不推进模拟
    if (!raw.isFinite || raw <= 0) return 0.0;
    if (raw < 0.004) return 0.0;
    return raw.clamp(0.008, 0.05);
  }

  /// 频段驱动的源项：底边若干“喷口”按频段能量注入染料与上升射流。
  ///
  /// 整排注入会让底边变成一条饱和亮带，且染料被均匀推开后只剩一团结实的
  /// 雾。这里改为离散喷嘴：每个喷嘴只填一个半径有限的核，边界梯度很陡，
  /// 被平流拉伸后自然形成细丝；喷嘴位置还会随时间缓慢摆动。
  void _inject(double dt, List<double> bands) {
    if (bands.isEmpty) return;

    const nozzleCount = 9;
    // 留出最底两行作固壁与排水，注入点在壁面之上
    final bottom = _ny - 3;
    const rowWeights = <double>[1.0, 0.75, 0.5, 0.3];

    for (var i = 0; i < nozzleCount; i++) {
      final phase = i / (nozzleCount - 1);
      final energy = _bandEnergy(bands, phase);
      if (!energy.isFinite || energy < 0.02) continue;

      final wander = math.sin(_simTime * 0.45 + i * 1.9) * _nx * 0.025;
      final centerX = 4.0 + (_nx - 9.0) * phase + wander;
      final radius = 2.0 + energy * 2.0;
      final coreDye = 0.5 + energy * 0.45;

      final xStart = (centerX - radius * 2.5).floor().clamp(1, _nx - 2);
      final xEnd = (centerX + radius * 2.5).ceil().clamp(1, _nx - 2);
      for (var x = xStart; x <= xEnd; x++) {
        final dx = x - centerX;
        final falloff = math.exp(-(dx * dx) / (radius * radius * 2.0));
        if (falloff < 0.02) continue;

        for (var dy = 0; dy < rowWeights.length; dy++) {
          final weight = falloff * rowWeights[dy];
          final cell = (bottom - dy) * _nx + x;

          // 染料用“不低于目标值”而不是累加：核心浓度恒定，被带走后由喷口补足
          final dye = coreDye * weight;
          if (dye > _dye[cell]) _dye[cell] = dye;

          // 射流：温和的上升速度（负值向上），过高会把染料瞬间抹匀
          final jet = -(1.2 + energy * 5.5) * weight;
          if (jet < _v[cell]) _v[cell] = jet;

          // 交替横向剪切：让相邻射流互相卷绕
          _u[cell] += math.sin(_simTime * 1.5 + i * 2.1) *
              energy *
              2.0 *
              weight *
              dt;
        }
      }
    }
  }

  /// 把 [t]（0 = 低频/画面中央，1 = 高频/两侧）映射回频段能量并线性插值。
  double _bandEnergy(List<double> bands, double t) {
    final n = bands.length;
    if (n == 0) return 0.0;
    if (n == 1) {
      final single = bands.first;
      return single.isFinite ? single.clamp(0.0, 1.0).toDouble() : 0.0;
    }

    final position = t.clamp(0.0, 1.0) * (n - 1);
    final low = position.floor();
    final high = low + 1 < n ? low + 1 : n - 1;
    final blend = position - low;
    final lowBand = bands[low];
    final highBand = bands[high];
    final lowEnergy = lowBand.isFinite ? lowBand.clamp(0.0, 1.0) : 0.0;
    final highEnergy = highBand.isFinite ? highBand.clamp(0.0, 1.0) : 0.0;
    return lowEnergy * (1.0 - blend) + highEnergy * blend;
  }

  /// 全场湍流搅动：三个尺度的无散涡旋力场（流函数取旋度）。
  ///
  /// 只用底部上升流时染料会像烟柱一样停在底部，无法铺满画面。
  /// 这里叠加一层随音乐增强的湍流：它由流函数 ψ 的旋度给出，天然无散，
  /// 不破坏压力投影；把染料反复拉伸、折叠，形成细长的丝状结构。
  /// 三个尺度分别负责大涡、中尺度卷曲与细丝褶皱。
  /// 三角函数按行/列预计算，逐格只做乘加。
  void _applyTurbulence(double dt, List<double> bands) {
    var level = 0.0;
    for (var i = 0; i < bands.length; i++) {
      final band = bands[i];
      if (band.isFinite) level += band.clamp(0.0, 1.0);
    }
    if (bands.isNotEmpty) level /= bands.length;

    // 力的大小必须让流速保持在 1~4 格/秒，否则半拉格朗日平流一步跨大半格，
    // 染料会被数值扩散抹成均匀雾。
    final strength = (1.6 + level * 5.0) * dt;
    final time = _simTime;

    final kx1 = 0.10 + level * 0.04;
    final ky1 = 0.13 + level * 0.05;
    const kx2 = 0.30;
    const ky2 = 0.34;
    const kx3 = 0.58;
    const ky3 = 0.62;
    final phaseX1 = time * 0.62;
    final phaseY1 = time * 0.48;
    final phaseX2 = -time * 0.95 + 1.3;
    final phaseY2 = time * 0.83 + 0.7;
    final phaseX3 = time * 1.15 + 2.6;
    final phaseY3 = -time * 0.92 + 4.1;

    for (var x = 0; x < _nx; x++) {
      final arg1 = kx1 * x + phaseX1;
      final arg2 = kx2 * x + phaseX2;
      final arg3 = kx3 * x + phaseX3;
      _waveXSin1[x] = math.sin(arg1);
      _waveXCos1[x] = math.cos(arg1);
      _waveXSin2[x] = math.sin(arg2);
      _waveXCos2[x] = math.cos(arg2);
      _waveXSin3[x] = math.sin(arg3);
      _waveXCos3[x] = math.cos(arg3);
    }
    for (var y = 0; y < _ny; y++) {
      final arg1 = ky1 * y + phaseY1;
      final arg2 = ky2 * y + phaseY2;
      final arg3 = ky3 * y + phaseY3;
      _waveYSin1[y] = math.sin(arg1);
      _waveYCos1[y] = math.cos(arg1);
      _waveYSin2[y] = math.sin(arg2);
      _waveYCos2[y] = math.cos(arg2);
      _waveYSin3[y] = math.sin(arg3);
      _waveYCos3[y] = math.cos(arg3);
    }

    for (var y = 1; y < _ny - 1; y++) {
      final rowBase = y * _nx;
      final sinY1 = _waveYSin1[y];
      final cosY1 = _waveYCos1[y];
      final sinY2 = _waveYSin2[y];
      final cosY2 = _waveYCos2[y];
      final sinY3 = _waveYSin3[y];
      final cosY3 = _waveYCos3[y];
      for (var x = 1; x < _nx - 1; x++) {
        final cell = rowBase + x;
        // u = ∂ψ/∂y，v = -∂ψ/∂x
        final du = -ky1 * _waveXSin1[x] * sinY1 -
            ky2 * _waveXSin2[x] * sinY2 -
            ky3 * _waveXSin3[x] * sinY3;
        final dv = -kx1 * _waveXCos1[x] * cosY1 -
            kx2 * _waveXCos2[x] * cosY2 -
            kx3 * _waveXCos3[x] * cosY3;
        _u[cell] += du * strength;
        _v[cell] += dv * strength;
      }
    }
  }

  /// 全局流场：整体缓慢上升 + 绕画面中心的旋转 + 按行剪切。
  ///
  /// 只有“横流 + 底部浮力”时，染料会被推到上边界后堆成亮带；改成
  /// 以中央涡旋为主、叠加一层很弱的上升漂移后，染料沿螺旋轨迹铺满整屏，
  /// 边界只承担吸收作用，不再需要靠浮力硬顶。
  void _applyFlow(double dt, List<double> bands) {
    var level = 0.0;
    for (var i = 0; i < bands.length; i++) {
      final band = bands[i];
      if (band.isFinite) level += band.clamp(0.0, 1.0);
    }
    if (bands.isNotEmpty) level /= bands.length;

    // 能量越高：旋转越快、上升越强、按行剪切越明显
    // 速度都用“格/秒”计，过大会让半拉格朗日平流每一步跨多半格，把染料抹成雾
    final base = 1.0 + level * 2.0;
    final drift = 1.2 + level * 2.8;
    final omega = 0.04 + level * 0.12;
    // 牵引强度不宜过大，否则每帧都把湍流速度拉回刚性旋转场，涡旋长不出来
    final blend = math.min(1.0, dt * 0.4);
    final centerX = (_nx - 1) * 0.5;
    final centerY = (_ny - 1) * 0.5;

    for (var y = 1; y < _ny; y++) {
      final rowBase = y * _nx;
      final dy = y - centerY;
      final shear = base *
          (0.35 + 0.65 * math.sin(y / _ny * math.pi * 1.7 + _simTime * 0.7));
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final dx = x - centerX;
        // 围绕中心的旋转场（屏幕 y 轴向下，方向仅影响观感，不影响无散性）
        final targetU = shear - omega * dy;
        final targetV = -drift + omega * dx * 0.55;
        _u[cell] += (targetU - _u[cell]) * blend;
        _v[cell] += (targetV - _v[cell]) * blend;
      }
    }
  }

  /// 涡量约束：把 |curl| 的梯度方向作为力，放大已有涡旋，避免数值耗散抹平细节。
  void _confineVorticity(double dt) {
    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final left = x > 0 ? _v[cell - 1] : 0.0;
        final right = x < _nx - 1 ? _v[cell + 1] : 0.0;
        final up = y > 0 ? _u[cell - _nx] : 0.0;
        final down = y < _ny - 1 ? _u[cell + _nx] : 0.0;
        _curl[cell] = 0.5 * ((right - left) - (down - up));
      }
    }

    const strength = 3.5;
    final step = strength * dt;

    for (var y = 1; y < _ny - 1; y++) {
      final rowBase = y * _nx;
      for (var x = 1; x < _nx - 1; x++) {
        final cell = rowBase + x;
        final gx = _curl[cell + 1].abs() - _curl[cell - 1].abs();
        final gy = _curl[cell + _nx].abs() - _curl[cell - _nx].abs();
        final length = math.sqrt(gx * gx + gy * gy);
        if (length < 1e-4) continue;

        final invLength = step / length;
        final curl = _curl[cell];
        // f = ε · (N × ω)，ω 指向屏幕外
        _u[cell] += gy * invLength * curl;
        _v[cell] -= gx * invLength * curl;
      }
    }
  }

  /// 速度平流：同样使用 MacCormack 修正。
  ///
  /// 纯半拉格朗日平流会持续削掉小尺度涡，速度场越来越光滑，染料只能顺着
  /// 几条大流线漂移，看起来像雾而不像流体。用二阶修正保住涡量后，
  /// 涡旋才能逐级拉出细丝。
  void _advectVelocity(double dt) {
    _uPrev.setAll(0, _u);
    _vPrev.setAll(0, _v);
    final damping = math.exp(-0.12 * dt);

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final px = x - dt * _uPrev[cell];
        final py = y - dt * _vPrev[cell];
        _uForward[cell] = _sample(_uPrev, px, py);
        _vForward[cell] = _sample(_vPrev, px, py);
      }
    }

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final px = x + dt * _uPrev[cell];
        final py = y + dt * _vPrev[cell];
        _uBackward[cell] = _sample(_uForward, px, py);
        _vBackward[cell] = _sample(_vForward, px, py);
      }
    }

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final leftU = _uPrev[rowBase + (x > 0 ? x - 1 : 0)];
        final rightU = _uPrev[rowBase + (x < _nx - 1 ? x + 1 : _nx - 1)];
        final upU = _uPrev[(y > 0 ? y - 1 : 0) * _nx + x];
        final downU = _uPrev[(y < _ny - 1 ? y + 1 : _ny - 1) * _nx + x];
        final leftV = _vPrev[rowBase + (x > 0 ? x - 1 : 0)];
        final rightV = _vPrev[rowBase + (x < _nx - 1 ? x + 1 : _nx - 1)];
        final upV = _vPrev[(y > 0 ? y - 1 : 0) * _nx + x];
        final downV = _vPrev[(y < _ny - 1 ? y + 1 : _ny - 1) * _nx + x];

        _u[cell] = _macCormack(
              forward: _uForward[cell],
              backward: _uBackward[cell],
              previous: _uPrev[cell],
              low: math.min(math.min(leftU, rightU), math.min(upU, downU)),
              high: math.max(math.max(leftU, rightU), math.max(upU, downU)),
            ) *
            damping;
        _v[cell] = _macCormack(
              forward: _vForward[cell],
              backward: _vBackward[cell],
              previous: _vPrev[cell],
              low: math.min(math.min(leftV, rightV), math.min(upV, downV)),
              high: math.max(math.max(leftV, rightV), math.max(upV, downV)),
            ) *
            damping;
      }
    }
  }

  /// MacCormack 修正并把结果夹到回溯点邻域的极值之间（抑制振铃）。
  double _macCormack({
    required double forward,
    required double backward,
    required double previous,
    required double low,
    required double high,
  }) {
    final corrected = forward + 0.5 * (previous - backward);
    if (!corrected.isFinite) return forward;
    if (corrected < low) return low;
    if (corrected > high) return high;
    return corrected;
  }

  /// 压力投影：求散度 → Jacobi 迭代压力 → 减去压力梯度，得到无散速度场。
  void _project() {
    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final left = x > 0 ? _u[cell - 1] : 0.0;
        final right = x < _nx - 1 ? _u[cell + 1] : 0.0;
        final up = y > 0 ? _v[cell - _nx] : 0.0;
        final down = y < _ny - 1 ? _v[cell + _nx] : 0.0;
        _divergence[cell] = -0.5 * (right - left + down - up);
        _pressure[cell] = 0.0;
      }
    }

    for (var iteration = 0; iteration < _pressureIterations; iteration++) {
      for (var y = 0; y < _ny; y++) {
        final rowBase = y * _nx;
        for (var x = 0; x < _nx; x++) {
          final cell = rowBase + x;
          final left = x > 0 ? _pressure[cell - 1] : _pressure[cell];
          final right = x < _nx - 1 ? _pressure[cell + 1] : _pressure[cell];
          final up = y > 0 ? _pressure[cell - _nx] : _pressure[cell];
          final down =
              y < _ny - 1 ? _pressure[cell + _nx] : _pressure[cell];
          _pressure[cell] =
              (_divergence[cell] + left + right + up + down) * 0.25;
        }
      }
    }

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final left = x > 0 ? _pressure[cell - 1] : _pressure[cell];
        final right = x < _nx - 1 ? _pressure[cell + 1] : _pressure[cell];
        final up = y > 0 ? _pressure[cell - _nx] : _pressure[cell];
        final down =
            y < _ny - 1 ? _pressure[cell + _nx] : _pressure[cell];
        _u[cell] -= 0.5 * (right - left);
        _v[cell] -= 0.5 * (down - up);
      }
    }

    // 边界：顶部与左右为固壁，底部保留上升入流（注入点就在其上方）
    for (var x = 0; x < _nx; x++) {
      _v[x] = 0.0;
      _u[(_ny - 1) * _nx + x] = 0.0;
    }
    for (var y = 0; y < _ny; y++) {
      _u[y * _nx] = 0.0;
      _u[y * _nx + _nx - 1] = 0.0;
    }
  }

  /// 染料平流：MacCormack 格式 + 指数耗散。
  ///
  /// 纯半拉格朗日平流每步都要做一次双线性插值，几帧内就把染料抹成均匀雾，
  /// 看不出丝状结构。MacCormack 先前向平流、再从结果回推，用两者的差值
  /// 抵消一阶数值扩散，最后把结果夹在回溯点邻域的极值之间避免振铃。
  void _advectDye(double dt) {
    _dyePrev.setAll(0, _dye);
    final decay = math.exp(-0.03 * dt);

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        _dyeForward[cell] =
            _sample(_dyePrev, x - dt * _u[cell], y - dt * _v[cell]);
      }
    }

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        _dyeBackward[cell] =
            _sample(_dyeForward, x + dt * _u[cell], y + dt * _v[cell]);
      }
    }

    for (var y = 0; y < _ny; y++) {
      final rowBase = y * _nx;
      for (var x = 0; x < _nx; x++) {
        final cell = rowBase + x;
        final left = _dyePrev[rowBase + (x > 0 ? x - 1 : 0)];
        final right = _dyePrev[rowBase + (x < _nx - 1 ? x + 1 : _nx - 1)];
        final up = _dyePrev[(y > 0 ? y - 1 : 0) * _nx + x];
        final down = _dyePrev[(y < _ny - 1 ? y + 1 : _ny - 1) * _nx + x];
        final low = math.min(
          math.min(left, right),
          math.min(up, down),
        );
        final high = math.max(
          math.max(left, right),
          math.max(up, down),
        );
        final corrected =
            _dyeForward[cell] + 0.5 * (_dyePrev[cell] - _dyeBackward[cell]);
        final clamped = corrected < low
            ? low
            : (corrected > high ? high : corrected);
        _dye[cell] = clamped * decay;
      }
    }

    // 底边与顶边吸收：固壁处染料会缓慢堆积成亮带，让它随时间淡出。
    final floorRow = (_ny - 1) * _nx;
    for (var x = 0; x < _nx; x++) {
      _dye[floorRow + x] *= 0.2;
      _dye[floorRow - _nx + x] *= 0.4;
      _dye[x] *= 0.35;
      _dye[_nx + x] *= 0.6;
    }
  }

  /// 速度回稳：限制极值并对整体做轻度阻尼，防止强瞬态让流场发散。
  void _relaxVelocity(double dt) {
    final damping = math.exp(-0.05 * dt);
    for (var i = 0; i < _cells; i++) {
      _u[i] = (_u[i] * damping).clamp(-10.0, 10.0);
      _v[i] = (_v[i] * damping).clamp(-10.0, 10.0);
    }
  }

  /// 双线性采样（越界坐标夹取到网格内，速度过高时也不会取到 NaN）。
  double _sample(Float32List field, double x, double y) {
    final sx = x.isFinite ? x.clamp(0.0, _nx - 1.0) : 0.0;
    final sy = y.isFinite ? y.clamp(0.0, _ny - 1.0) : 0.0;
    final x0 = sx.floor();
    final y0 = sy.floor();
    final x1 = math.min(x0 + 1, _nx - 1);
    final y1 = math.min(y0 + 1, _ny - 1);
    final fx = sx - x0;
    final fy = sy - y0;

    final top = field[y0 * _nx + x0] * (1.0 - fx) +
        field[y0 * _nx + x1] * fx;
    final bottom = field[y1 * _nx + x0] * (1.0 - fx) +
        field[y1 * _nx + x1] * fx;
    return top * (1.0 - fy) + bottom * fy;
  }

  /// 把染料场映射成顶点颜色并一次性绘制。
  void paint(
    Canvas canvas,
    Size size,
    VisualizerPalette palette,
    double bloom,
  ) {
    _ensureGeometry(size);
    final table = _resolveColorTable(palette, bloom);

    var total = 0.0;
    var cursor = 0;
    for (var y = 0; y <= _ny; y++) {
      final sampleY = y - 0.5;
      for (var x = 0; x <= _nx; x++) {
        // 顶点落在格角上，按格心坐标双线性采样，消除最近格取样留下的块状锯齿
        final dye = _sample(_dye, x - 0.5, sampleY);
        total += dye;
        final level = _gammaIndex(dye);
        _colors[cursor++] = level <= 0 ? 0 : table[level];
      }
    }

    // 染料几乎耗尽时不提交空的三角网格；重置 priming，下一帧重新铺底
    if (total < 2.0) {
      _primed = false;
      return;
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _positions,
      colors: _colors,
      indices: _indices,
    );
    // BlendMode.dst：只使用顶点颜色，忽略 Paint 自身颜色
    canvas.drawVertices(vertices, ui.BlendMode.dst, _meshPaint);
  }

  /// 网格位置只在画布尺寸变化时重建（颜色缓冲每帧复用）。
  void _ensureGeometry(Size size) {
    if (_geometrySize == size) return;
    _geometrySize = size;

    final cellWidth = size.width / _nx;
    final cellHeight = size.height / _ny;
    var cursor = 0;
    for (var y = 0; y <= _ny; y++) {
      final py = y * cellHeight;
      for (var x = 0; x <= _nx; x++) {
        _positions[cursor++] = x * cellWidth;
        _positions[cursor++] = py;
      }
    }
  }

  /// 染料浓度 → ARGB 查找表（含透明度渐变），仅在配色或辉光参数变化时重建。
  Int32List _resolveColorTable(VisualizerPalette palette, double bloom) {
    final colors = palette.gradient;
    final cached = _colorTable;
    if (cached != null &&
        _tableBloom == bloom &&
        _tablePeak == palette.peak &&
        _sameColors(_tableColors, colors)) {
      return cached;
    }

    final table = cached ?? Int32List(_lutSize);
    // 浅色主题的 peak 取正文深灰，深色主题取近白色；据此判断底色明暗。
    // 浅色底上中低透明度只是淡淡一层灰绿，必须更快逼近不透明才看得出结构。
    final lightBackground = palette.peak.computeLuminance() < 0.5;
    // 只用前两段配色，末尾收到峰值色：多数主题的第三色是品红/紫，
    // 整段走完会把染料核心染成粉色花斑，反而看不出流体结构。
    final stops = <Color>[
      colors.isNotEmpty ? colors.first : palette.primary,
      colors.length > 1 ? colors[1] : palette.secondary,
      palette.peak,
    ];
    final rampStart = lightBackground ? 0.12 : 0.2;
    final rampSpan = lightBackground ? 0.4 : 0.5;
    final rampExponent = lightBackground ? 0.9 : 0.85;

    for (var i = 0; i < _lutSize; i++) {
      final t = i / (_lutSize - 1);
      final scaled = t * (stops.length - 1);
      final lowIndex = scaled.floor().clamp(0, stops.length - 1);
      final highIndex = math.min(lowIndex + 1, stops.length - 1);
      var base =
          Color.lerp(stops[lowIndex], stops[highIndex], scaled - lowIndex)!;
      // 浅色底上，主题色本身偏亮，半透明只会把底色调成一片淡色；
      // 往黑里压一档当作“墨水”，与米色底拉开明度差。
      if (lightBackground) {
        base = Color.lerp(base, const Color(0xFF000000), 0.35)!;
      }
      // 只让高浓度区域显影：低浓度一律透明，画面才是一缕缕丝而不是一层雾
      final rampSpanT =
          ((t - rampStart) / rampSpan).clamp(0.0, 1.0).toDouble();
      final alpha =
          math.pow(rampSpanT, rampExponent).toDouble() * (0.95 + bloom * 0.1);
      table[i] = base.withValues(alpha: alpha).toARGB32();
    }

    _colorTable = table;
    _tableColors = List<Color>.of(colors);
    _tableBloom = bloom;
    _tablePeak = palette.peak;
    return table;
  }

  /// 染料浓度 → 颜色表下标。gamma 预先算成 256 项查表，
  /// 避免每帧对近万个顶点各调用一次 pow。
  int _gammaIndex(double dye) {
    if (!(dye > 0)) return 0;
    final index = (dye * 255.0).round();
    return _gammaLut[index > 255 ? 255 : index];
  }

  static final Uint8List _gammaLut = _buildGammaLut();

  static Uint8List _buildGammaLut() {
    final lut = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      final shaped = math.pow(i / 255.0, 1.15).toDouble() * (_lutSize - 1);
      lut[i] = shaped.round().clamp(0, _lutSize - 1);
    }
    return lut;
  }

  bool _sameColors(List<Color>? cached, List<Color> colors) {
    if (cached == null || cached.length != colors.length) return false;
    for (var i = 0; i < colors.length; i++) {
      if (cached[i].toARGB32() != colors[i].toARGB32()) return false;
    }
    return true;
  }
}
