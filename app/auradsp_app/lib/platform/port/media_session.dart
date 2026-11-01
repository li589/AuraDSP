// media_session.dart — 系统媒体会话端口（歌词同步用）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// Windows 实现 = SMTC PowerShell 子进程；其它平台 supported=false（空提供者）。
import '../../core/media_track.dart';

abstract interface class MediaSessionProvider {
  Stream<MediaTrackMetadata> get trackStream;

  /// 启动采集（空实现可忽略）。
  void start();

  /// 停止采集（空实现可忽略）。
  void stop();

  void dispose();
}

abstract interface class MediaSessionPort {
  /// 当前平台是否具备系统媒体会话能力。
  bool get supported;

  /// 创建提供者；调用方负责 start/stop/dispose。
  MediaSessionProvider create();
}
