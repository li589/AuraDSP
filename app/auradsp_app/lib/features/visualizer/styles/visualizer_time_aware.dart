/// 时间可变画笔协议（2026-10-31 内存优化）。
///
/// 视口缓存画笔实例、只更新时间：CustomPainter 不在逐帧重建，画笔内部的
/// Path / Paint / Shader / Vertices 才能在整场播放中保持同一份原生对象，
/// 避免 60fps 的 Skia 原生分配落到 GC finalizer 队列（旧实现是「部分可视化
/// 内存涨到 2GB」的主因）。
abstract interface class VisualizerTimeAware {
  void setVisualizerTime(double time);
}
