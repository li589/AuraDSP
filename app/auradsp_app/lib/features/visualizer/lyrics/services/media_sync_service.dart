import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../../../core/error_sink.dart';
import '../../../../platform/platform_profile.dart';
import '../models/lyric_models.dart';
import '../parsers/lrc_parser.dart';
import 'online_lyrics_service.dart';
import 'windows_smtc_provider.dart';

/// 跨平台媒体会话提供者接口
abstract interface class MediaSessionProvider {
  Stream<MediaTrackMetadata> get trackStream;
  void dispose();
}

/// 单元测试或不支持平台的虚设提供者
class MockMediaSessionProvider implements MediaSessionProvider {
  final StreamController<MediaTrackMetadata> _controller =
      StreamController<MediaTrackMetadata>.broadcast();

  @override
  Stream<MediaTrackMetadata> get trackStream => _controller.stream;

  void emitTrack(MediaTrackMetadata track) {
    if (!_controller.isClosed) _controller.add(track);
  }

  @override
  void dispose() {
    _controller.close();
  }
}

/// 歌词检索状态：为 UI 提供可见反馈（无媒体 / 检索中 / 已就绪 / 未找到）
enum LyricsSyncState { idle, noMedia, searching, ready, notFound }

/// 统一媒体时钟同步与歌词编排调度服务
class MediaSyncService {
  final MediaSessionProvider _provider;
  final OnlineLyricsService _onlineService;

  StreamSubscription<MediaTrackMetadata>? _sessionSub;

  /// 每次换曲自增，用于丢弃过期的在线歌词查询结果
  int _trackGeneration = 0;
  bool _disposed = false;

  final ValueNotifier<MediaTrackMetadata> currentTrack =
      ValueNotifier<MediaTrackMetadata>(MediaTrackMetadata.empty);

  final ValueNotifier<LyricDocument> currentLyrics =
      ValueNotifier<LyricDocument>(LyricDocument.empty);

  final ValueNotifier<int> activeLineIndex = ValueNotifier<int>(-1);

  final ValueNotifier<LyricsSyncState> lyricsState =
      ValueNotifier<LyricsSyncState>(LyricsSyncState.idle);

  Timer? _ticker;
  DateTime? _lastSyncTime;
  Duration _basePosition = Duration.zero;
  bool _isPlaying = false;

  MediaSyncService({
    MediaSessionProvider? provider,
    OnlineLyricsService? onlineService,
  })  : _provider = provider ??
            (PlatformProfile.os == 'windows'
                ? WindowsSmtcProvider()
                : MockMediaSessionProvider()),
        _onlineService = onlineService ?? OnlineLyricsService();

  /// 启动系统媒体传输控制 (SMTC) 监听，自动绑定歌词
  void startAutoSync() {
    _sessionSub?.cancel();
    final p = _provider;
    if (p is WindowsSmtcProvider) {
      p.start();
    }
    _sessionSub = _provider.trackStream.listen((track) {
      updateTrack(track);
    });

    // 再次开启歌词时若已有曲目但歌词为空（上次检索失败/尚未检索），立即补拉一次
    final track = currentTrack.value;
    if (track.hasContent &&
        currentLyrics.value.isEmpty &&
        lyricsState.value != LyricsSyncState.searching) {
      unawaited(retryLyrics());
    }
  }

  /// 停止自动同步监听
  void stopAutoSync() {
    _sessionSub?.cancel();
    _sessionSub = null;
  }

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
    if (_disposed) return;
    _basePosition = position;
    _lastSyncTime = DateTime.now();
    _isPlaying = isPlaying;
    _syncTicker();
    _tick();
  }

  /// Load a lyric document directly (e.g. from a local file or test)
  void loadLyricDocument(LyricDocument doc) {
    if (_disposed) return;
    currentLyrics.value = doc;
    activeLineIndex.value = doc.isNotEmpty ? 0 : -1;
    lyricsState.value =
        doc.isNotEmpty ? LyricsSyncState.ready : LyricsSyncState.notFound;
  }

  /// 手动重新检索当前曲目歌词（忽略“同曲轮询不重复请求”的节流）
  Future<void> retryLyrics() async {
    if (_disposed) return;
    final track = currentTrack.value;
    if (!track.hasContent) {
      lyricsState.value = LyricsSyncState.noMedia;
      return;
    }

    final generation = ++_trackGeneration;
    lyricsState.value = LyricsSyncState.searching;

    final doc = await _onlineService.fetchLyrics(
      trackName: track.title,
      artistName: track.artist,
      duration: track.duration,
    );

    if (_disposed || generation != _trackGeneration) return;

    if (doc != null && doc.isNotEmpty) {
      currentLyrics.value = doc;
      activeLineIndex.value = doc.findLineIndex(_basePosition);
      lyricsState.value = LyricsSyncState.ready;
    } else {
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      lyricsState.value = LyricsSyncState.notFound;
    }
  }

  /// Update current track metadata and search for lyrics
  Future<void> updateTrack(MediaTrackMetadata track) async {
    if (_disposed) return;
    final previous = currentTrack.value;
    final titleChanged =
        track.title != previous.title || track.artist != previous.artist;

    currentTrack.value = track;
    _isPlaying = track.isPlaying;

    if (titleChanged) {
      _basePosition = track.position;
      _lastSyncTime = DateTime.now();
      // 换曲即作废在途检索，并清空旧歌词，避免新曲目沿用上一首的歌词与行指针
      _trackGeneration++;
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      lyricsState.value = track.hasContent
          ? LyricsSyncState.searching
          : LyricsSyncState.noMedia;
    } else if (track.position > Duration.zero) {
      // 若外部上报了有效时间轴（如 Spotify/Edge），则以此校准时钟；
      // 若外部上报为 0（如网易云等国内播放器 SMTC 不传 timeline），则维持当前递增时钟，避免被归零重置
      _basePosition = track.position;
      _lastSyncTime = DateTime.now();
    }

    _syncTicker();

    if (!track.hasContent) {
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      lyricsState.value = LyricsSyncState.noMedia;
      return;
    }

    // 同一曲目的轮询：仅校正行指针，避免每秒重复发起网络查询。
    // 注意不得递增 _trackGeneration，否则会作废耗时超过一次轮询间隔的在线检索结果。
    if (!titleChanged) {
      if (currentLyrics.value.isNotEmpty) {
        activeLineIndex.value =
            currentLyrics.value.findLineIndex(_basePosition);
        lyricsState.value = LyricsSyncState.ready;
      }
      return;
    }

    final generation = _trackGeneration;

    // 尝试在线检索歌词（LrcLib 优先，QQ 音乐多语言保底）
    final doc = await _onlineService.fetchLyrics(
      trackName: track.title,
      artistName: track.artist,
      duration: track.duration,
    );

    // 查询期间已切歌或服务已释放：丢弃过期结果
    if (_disposed || generation != _trackGeneration) return;

    if (doc != null && doc.isNotEmpty) {
      currentLyrics.value = doc;
      activeLineIndex.value = doc.findLineIndex(_basePosition);
      lyricsState.value = LyricsSyncState.ready;
    } else {
      lyricsState.value = LyricsSyncState.notFound;
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
    } catch (e, st) {
      // 本地歌词文件读取失败属可预期路径，留痕后回退
      swallow(e, st);
    }
    return false;
  }

  void dispose() {
    _disposed = true;
    stopAutoSync();
    _ticker?.cancel();
    _provider.dispose();
    currentTrack.dispose();
    currentLyrics.dispose();
    activeLineIndex.dispose();
    lyricsState.dispose();
  }
}
