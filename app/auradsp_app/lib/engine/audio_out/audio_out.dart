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
