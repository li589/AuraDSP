import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

import 'visualizer_atlas_bake.dart';

export 'visualizer_atlas_bake.dart' show SpriteSlice;

/// 可视化柔光精灵图集（构建期预烘焙 PNG，运行期只做一次图片解码）。
///
/// 性能背景（2026-11-07 实测）：`canvas.scale` + `RadialGradient` 的大面积
/// 半透明填充在 Impeller GL 上走通用矩阵路径，逐像素求值并大面积混合，
/// 是龙卷风/云流 CPU 与 GPU 的主要成本。因此所有柔光改为**预烘焙灰度精灵**
/// （白色 + 透明度），运行期只用位图采样。
///
/// 2026-11-08 内存定案：`toImageSync` 与「一张 1024×1024 image 活着」本身
/// 只要约 10 MB；烘焙 + 立刻 dispose 立刻归还，活着不画则常驻 +334 MB。
/// 这 334 MB 来自**烘焙内容**（1093 条绘制、约 250 个一次性 Gradient
/// shader、844 次 `ColorFilter` 薄片），且绑在这张烘出来的 `ui.Image` 上。
/// 因此运行期不再烘焙：改为加载构建期生成的 PNG 资源，只做一次普通解码。
///
/// 运行期只有**一条**绘制路径：逐实例 `colors` + `BlendMode.modulate` 的
/// `drawRawAtlas`。图集是「白色 + alpha」的密度图，颜色与亮度都写在绘制
/// 指令里，**不侵入图集内容**。
///
/// 注意：逐实例 `colors` **必须**配 `BlendMode.modulate`（纹理色 × 实例色，
/// 纹理 alpha 保留）；配 `srcOver` 会丢掉纹理 alpha、只剩纯色四边形。
///
/// 常驻纹理预算（硬上限）：
/// 1 张 × 1024 × 1024 × 4 B = 4,194,304 B ≈ **4.0 MB**（目标 ≤ 20 MB）。
/// 全进程只有这一张图集，不按主题 / 亮度档 / 密度 / 窗口尺寸分桶；
/// `FilterQuality.low` 是双线性、不生成 mipmap，因此没有额外 mip 链。
///
/// 生命周期：`_image` 只解码一次、**永不替换**。首帧发起异步解码，未完成时
/// `imageOrNull == null`，调用方跳过精灵批次（静态背景照常绘制）。
/// 解码失败时同样保持 `imageOrNull == null`，且**不会每帧重试**：失败标记
/// 一旦置位，本进程后续 `ensureImage()` 直接返回，精灵层永久关闭，
/// 不抛异常、不崩溃、不退回同步烘焙。
///
/// 图集布局与绘制内容都在 [visualizer_atlas_bake.dart]（唯一一份实现，
/// 由离线生成器 `tool/bake_viz_atlas_test.dart` 使用）：
/// - blob        192×192 柔和圆斑
/// - blobWide    224×168 横向压扁的云
/// - blobTall    168×224 纵向拉长的云
/// - saucer      352×96  底部浅盘（宽高比 ≈ 3.67）
/// - puff        224×80  小团絮（不规则多瓣 + 细颗粒，高频湍流纹理来源）
/// - star        64×64 ×4 四档亮度星点（运行期按种子挑选，形成亮度分布）
/// - funnelWide  448×448 龙卷风外层锥体
/// - funnelCore  352×448 龙卷风内层亮锥
class VisualizerSpriteAtlas {
  static final VisualizerSpriteAtlas instance = VisualizerSpriteAtlas._();

  /// 构建期生成的图集资源（1024×1024 PNG，透明底，白色密度）。
  static const String assetPath = 'assets/viz/atlas_v1.png';

  ui.Image? _image;

  /// 解码在飞：`ensureImage()` 由每帧 `paint()` 调用，需要幂等。
  Future<void>? _loading;

  /// 解码失败标记：置位后不再重试，精灵层在本进程内永久跳过。
  bool _failed = false;

  SpriteSlice get blob => VizAtlasLayout.blob;
  SpriteSlice get blobWide => VizAtlasLayout.blobWide;
  SpriteSlice get blobTall => VizAtlasLayout.blobTall;
  SpriteSlice get saucer => VizAtlasLayout.saucer;

  /// 小团絮（224×80，宽高比 2.8:1）：运行期按 30~135 px 贴到云体 / 锥面上，
  /// 缩放后 11~60 px，边缘不规则（不是椭圆也不是细线），
  /// 用来提供中高频湍流团块。
  SpriteSlice get puff => VizAtlasLayout.puff;

  /// 四档亮度：0.30 / 0.52 / 0.78 / 1.0（烘焙进峰值 alpha）。
  List<SpriteSlice> get starTiers => VizAtlasLayout.starTiers;

  SpriteSlice get funnelWide => VizAtlasLayout.funnelWide;
  SpriteSlice get funnelCore => VizAtlasLayout.funnelCore;

  VisualizerSpriteAtlas._();

  /// 已解码完成的图集；解码完成前（或失败后）恒为 `null`。
  ///
  /// 调用方**不得**在这里触发同步烘焙：未就绪时直接跳过精灵批次即可。
  ui.Image? get imageOrNull => _image;

  /// 幂等触发一次图集解码。解码进行中、已完成或已失败都不会重复发起。
  void ensureImage() {
    if (_image != null || _loading != null || _failed) return;
    _loading = _loadAsset();
  }

  /// 加载构建期生成的图集 PNG：只解码一次，绝不退回同步烘焙。
  ///
  /// 失败时只置位 [_failed]，精灵层永久跳过（静态背景不受影响）。
  Future<void> _loadAsset() async {
    try {
      final data = await rootBundle.load(assetPath);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      _image = frame.image;
    } catch (_) {
      _failed = true;
    } finally {
      _loading = null;
    }
  }

  /// 与运行期共用的锥体母线（u=0 底部，u=1 顶部）。
  ///
  /// 底部最窄、向上单调外扩；只在最底部 10% 轻微外翻收进浅盘，
  /// 中段没有任何鼓起，避免读成「花瓶」或「杯口」。
  static double radiusAt(double u) => VizAtlasLayout.radiusAt(u);
}
