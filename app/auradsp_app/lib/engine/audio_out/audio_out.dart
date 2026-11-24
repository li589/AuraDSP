// audio_out.dart —— App 侧桌面设备输出端口（AudioOut）。
//
// 方案：docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md ADR-CP-3。
// 设备输出归 App 侧：引擎 DLL 只做 DSP，不持有设备（Android 走 HAL，不经过本端口）。
// 实现：audio_out_wasapi.dart（Windows）与 audio_out_linux.dart
// （Linux / PulseAudio simple API，S3 起）；macOS 实现随新平台补入。
import 'dart:typed_data';

abstract class AudioOut {
  bool get started;

  /// 实际协商到的设备采样率（Hz）。
  int get sampleRate;

  /// 实际协商到的设备声道数。
  int get channels;

  /// 设备缓冲总帧数。
  int get bufferFrames;

  /// 当前设备缓冲中待播放帧数（泵循环据此计算可写帧数）。
  int currentPadding();

  void init({int? requestedSampleRate});

  void start();

  void stop();

  /// 拉取一块设备缓冲并写入 [frames] 帧、每帧 [srcCh] 声道。
  /// 内部完成设备位深/声道格式转换与 ReleaseBuffer（等价于原
  /// GetBuffer → writeToDevice → ReleaseBuffer 三步）。
  void write(Float32List src, {required int frames, int srcCh = 2});
}

/// 镜像扇出输出（2×2 S3，2026-11-23）：主输出之外并行渲染一路
/// 镜像（VAIO 输出格的 WASAPI 监听）。节拍与全部状态口径只认
/// 主输出——镜像时钟跟随主管线，写不进（缓冲不足）整块跳过、
/// 写失败即摘除镜像并经 [onMirrorError] 上报一次，永不反噬
/// 主路。镜像的格式适配由其自身 write 承担（与主输出同口径）；
/// 采样率与主输出不一致的镜像在构造侧就应被拒绝（变速不可接受），
/// 本类只按同率前提工作。
final class MirrorAudioOut implements AudioOut {
  MirrorAudioOut(this.primary, this.mirror,
      {this._onMirrorError});

  final AudioOut primary;
  AudioOut? mirror;
  final void Function(Object e, StackTrace st)? _onMirrorError;

  @override
  bool get started => primary.started;

  @override
  int get sampleRate => primary.sampleRate;

  @override
  int get channels => primary.channels;

  @override
  int get bufferFrames => primary.bufferFrames;

  @override
  int currentPadding() => primary.currentPadding();

  @override
  void init({int? requestedSampleRate}) =>
      primary.init(requestedSampleRate: requestedSampleRate);

  @override
  void start() => primary.start();

  @override
  void stop() {
    final m = mirror;
    mirror = null;
    if (m != null) {
      try {
        m.stop();
      } catch (e, st) {
        _onMirrorError?.call(e, st);
      }
    }
    primary.stop();
  }

  @override
  void write(Float32List src, {required int frames, int srcCh = 2}) {
    primary.write(src, frames: frames, srcCh: srcCh);
    final m = mirror;
    if (m == null || !m.started) return;
    try {
      // 镜像缓冲不足整块跳过：镜像只许迟到、不许拖住主路节拍。
      if (m.bufferFrames - m.currentPadding() < frames) return;
      m.write(src, frames: frames, srcCh: srcCh);
    } catch (e, st) {
      // 镜像设备失效：摘除并上报一次，后续块不再重试。
      mirror = null;
      _onMirrorError?.call(e, st);
      try {
        m.stop();
        // swallow: 镜像已摘除，stop 的二次失败无处可去也不影响主路。
      } catch (e2, st2) {
        _onMirrorError?.call(e2, st2);
      }
    }
  }
}
