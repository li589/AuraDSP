import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../../../platform/platform_profile.dart';
import '../models/lyric_models.dart';
import '../parsers/lrc_parser.dart';

/// Provider interface for capturing media session information across platforms
abstract interface class MediaSessionProvider {
  Future<MediaTrackMetadata?> getActiveTrack();
  void dispose();
}

/// Fallback / mock media session provider for testing and unsupported OS
class MockMediaSessionProvider implements MediaSessionProvider {
  @override
  Future<MediaTrackMetadata?> getActiveTrack() async => null;

  @override
  void dispose() {}
}

/// Open online lyrics client using LrcLib API (public, no authentication needed)
class LrcLibOnlineClient {
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  final Map<String, LyricDocument> _cache = {};

  /// Fetch synchronized lyrics from LrcLib by title and artist
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
  }) async {
    final queryKey = '${trackName.trim().toLowerCase()}_${artistName.trim().toLowerCase()}';
    if (_cache.containsKey(queryKey)) {
      return _cache[queryKey];
    }

    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'track_name': trackName,
        'artist_name': artistName,
        if (duration != null && duration.inSeconds > 0)
          'duration': duration.inSeconds.toString(),
      });

      final request = await _client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>?;

      if (data == null) return null;

      final syncedLrc = data['syncedLyrics'] as String?;
      if (syncedLrc != null && syncedLrc.trim().isNotEmpty) {
        final doc = LrcParser.parse(syncedLrc);
        _cache[queryKey] = doc;
        return doc;
      }

      final plainLyrics = data['plainLyrics'] as String?;
      if (plainLyrics != null && plainLyrics.trim().isNotEmpty) {
        // Fallback for plain un-synced text
        final lines = plainLyrics
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map((l) => LyricLine(
                  startTime: Duration.zero,
                  endTime: const Duration(seconds: 3600),
                  text: l.trim(),
                ))
            .toList();
        final doc = LyricDocument(lines: lines, title: trackName, artist: artistName);
        _cache[queryKey] = doc;
        return doc;
      }
    } catch (_) {
      // Network or parse failure, swallow gracefully
    }
    return null;
  }
}

/// Unified media synchronization and lyrics orchestrator service
class MediaSyncService {
  final LrcLibOnlineClient _onlineClient = LrcLibOnlineClient();

  /// Normalized platform OS key from PlatformProfile
  String get platformOs => PlatformProfile.os;

  final ValueNotifier<MediaTrackMetadata> currentTrack =
      ValueNotifier<MediaTrackMetadata>(MediaTrackMetadata.empty);

  final ValueNotifier<LyricDocument> currentLyrics =
      ValueNotifier<LyricDocument>(LyricDocument.empty);

  final ValueNotifier<int> activeLineIndex = ValueNotifier<int>(-1);

  Timer? _ticker;
  DateTime? _lastSyncTime;
  Duration _basePosition = Duration.zero;
  bool _isPlaying = false;

  /// 仅在播放时启动 20Hz 行同步 ticker，停播即释放，避免页面常驻空转。
  void _syncTicker() {
    if (_isPlaying) {
      _startTicker();
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  void _tick() {
    if (!_isPlaying || _lastSyncTime == null) return;

    final elapsed = DateTime.now().difference(_lastSyncTime!);
    final curPos = _basePosition + elapsed;

    final doc = currentLyrics.value;
    if (doc.isNotEmpty) {
      final idx = doc.findLineIndex(curPos);
      if (idx != activeLineIndex.value) {
        activeLineIndex.value = idx;
      }
    }
  }

  /// Manually or automatically update playback status and position
  void updatePlaybackState({
    required Duration position,
    required bool isPlaying,
  }) {
    _basePosition = position;
    _lastSyncTime = DateTime.now();
    _isPlaying = isPlaying;
    _syncTicker();
    _tick();
  }

  /// Load a lyric document directly (e.g. from a local file or test)
  void loadLyricDocument(LyricDocument doc) {
    currentLyrics.value = doc;
    activeLineIndex.value = doc.isNotEmpty ? 0 : -1;
  }

  /// Update current track metadata and search for lyrics
  Future<void> updateTrack(MediaTrackMetadata track) async {
    currentTrack.value = track;
    _basePosition = track.position;
    _lastSyncTime = DateTime.now();
    _isPlaying = track.isPlaying;
    _syncTicker();

    if (!track.hasContent) {
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      return;
    }

    // Try online lyrics retrieval if network is enabled
    final doc = await _onlineClient.fetchLyrics(
      trackName: track.title,
      artistName: track.artist,
      duration: track.duration,
    );

    if (doc != null && doc.isNotEmpty) {
      currentLyrics.value = doc;
      activeLineIndex.value = doc.findLineIndex(track.position);
    }
  }

  /// Look for companion .lrc file on disk
  Future<bool> loadLocalLrcFile(String audioFilePath) async {
    try {
      final extIdx = audioFilePath.lastIndexOf('.');
      if (extIdx <= 0) return false;
      final lrcPath = '${audioFilePath.substring(0, extIdx)}.lrc';
      final file = File(lrcPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final doc = LrcParser.parse(content);
        if (doc.isNotEmpty) {
          loadLyricDocument(doc);
          return true;
        }
      }
    } catch (_) {
      // File IO failure
    }
    return false;
  }

  void dispose() {
    _ticker?.cancel();
    currentTrack.dispose();
    currentLyrics.dispose();
    activeLineIndex.dispose();
  }
}
