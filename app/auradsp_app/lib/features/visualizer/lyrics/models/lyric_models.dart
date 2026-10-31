/// Models for timed lyrics, syllables, and media session metadata
class LyricSyllable {
  final Duration startTime;
  final Duration endTime;
  final String text;

  const LyricSyllable({
    required this.startTime,
    required this.endTime,
    required this.text,
  });

  /// Compute sweep progress [0.0, 1.0] for karaoke animation
  double progress(Duration position) {
    if (position < startTime) return 0.0;
    if (position >= endTime) return 1.0;
    final total = endTime.inMicroseconds - startTime.inMicroseconds;
    if (total <= 0) return 1.0;
    final current = position.inMicroseconds - startTime.inMicroseconds;
    return (current / total).clamp(0.0, 1.0);
  }
}

/// A single timestamped line of lyrics
class LyricLine {
  final Duration startTime;
  final Duration endTime;
  final String text;
  final String? translation;
  final List<LyricSyllable>? syllables;

  const LyricLine({
    required this.startTime,
    required this.endTime,
    required this.text,
    this.translation,
    this.syllables,
  });

  bool get isKaraoke => syllables != null && syllables!.isNotEmpty;

  /// Overall line progress [0.0, 1.0]
  double lineProgress(Duration position) {
    if (position < startTime) return 0.0;
    if (position >= endTime) return 1.0;
    final total = endTime.inMicroseconds - startTime.inMicroseconds;
    if (total <= 0) return 1.0;
    final cur = position.inMicroseconds - startTime.inMicroseconds;
    return (cur / total).clamp(0.0, 1.0);
  }

  LyricLine copyWith({
    Duration? startTime,
    Duration? endTime,
    String? text,
    String? translation,
    List<LyricSyllable>? syllables,
  }) {
    return LyricLine(
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      text: text ?? this.text,
      translation: translation ?? this.translation,
      syllables: syllables ?? this.syllables,
    );
  }
}

/// Structured document containing full lyric lines and metadata tags
class LyricDocument {
  final List<LyricLine> lines;
  final String? title;
  final String? artist;
  final String? album;
  final Duration offset;

  const LyricDocument({
    required this.lines,
    this.title,
    this.artist,
    this.album,
    this.offset = Duration.zero,
  });

  static const LyricDocument empty = LyricDocument(lines: []);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// Find active line index using binary search
  int findLineIndex(Duration position) {
    if (lines.isEmpty) return -1;
    final posWithOffset = position + offset;
    if (posWithOffset < lines.first.startTime) return 0;
    if (posWithOffset >= lines.last.startTime) return lines.length - 1;

    var low = 0;
    var high = lines.length - 1;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final line = lines[mid];
      if (posWithOffset >= line.startTime && posWithOffset < line.endTime) {
        return mid;
      } else if (posWithOffset < line.startTime) {
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return (low - 1).clamp(0, lines.length - 1);
  }
}

/// Normalized media playback track metadata
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
