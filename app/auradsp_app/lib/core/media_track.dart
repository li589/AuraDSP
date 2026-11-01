// media_track.dart — 系统媒体会话的归一化曲目元数据（平台无关）。
//
// 从 features/visualizer/lyrics/models/lyric_models.dart 迁出：
// platform/ 的媒体会话端口需要消费该模型，不能反向依赖 features/。
class MediaTrackMetadata {
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Duration position;
  final bool isPlaying;

  const MediaTrackMetadata({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.isPlaying = false,
  });

  static const MediaTrackMetadata empty = MediaTrackMetadata();

  bool get hasContent => title.isNotEmpty || artist.isNotEmpty;

  MediaTrackMetadata copyWith({
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    Duration? position,
    bool? isPlaying,
  }) {
    return MediaTrackMetadata(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      position: position ?? this.position,
      isPlaying: isPlaying ?? this.isPlaying,
    );
  }
}
