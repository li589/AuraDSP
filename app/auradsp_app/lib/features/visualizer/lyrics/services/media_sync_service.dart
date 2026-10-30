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

  /// 用户手动点选某行歌词时产生的显示相位偏移（解决播放器不推送时间轴/时间轴不准）。
  /// 只影响歌词高亮，不回写媒体时钟；换曲归零。
  Duration _userOffset = Duration.zero;

  /// 同一曲目轮询时允许的整体前跳阈值（真实 seek 或播放器校准）
  static const Duration _forwardResync = Duration(milliseconds: 400);

  /// 回跳超过该幅度才认为是真实向后拖拽（否则视为 SMTC 快照滞后）
  static const Duration _backwardSeekFloor = Duration(seconds: 3);

  /// 行切换滞回：越过行首/行尾不足该值时保持当前行，压住边界来回翻动
  static const Duration _lineSwitchGuard = Duration(milliseconds: 140);

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

  /// 单调播放时钟：暂停时冻结在锚点，播放时按真实流逝时间推进。
  /// 所有歌词定位都从这一个读数出发，保证高亮不会因外部快照来回跳。
  Duration _estimatedPosition() {
    if (!_isPlaying || _lastSyncTime == null) return _basePosition;
    return _basePosition + DateTime.now().difference(_lastSyncTime!);
  }

  void _anchorClock(Duration position) {
    _basePosition = position;
    _lastSyncTime = DateTime.now();
  }

  /// 当前用于歌词定位的显示相位（单调时钟 + 用户手动校准偏移）
  Duration get displayPosition => _estimatedPosition() + _userOffset;

  void _tick() {
    if (!_isPlaying || _lastSyncTime == null) return;

    final doc = currentLyrics.value;
    if (doc.isEmpty) return;

    final curPos = displayPosition;
    final candidate = doc.findLineIndex(curPos);
    final current = activeLineIndex.value;
    final idx = _debounceLineSwitch(doc, curPos, current, candidate);
    if (idx != current) {
      activeLineIndex.value = idx;
    }
  }

  /// 边界滞回：向前进入新行需越过该行行首 [_lineSwitchGuard]；
  /// 向后回退需退到当前行行首之前同样的距离。避免时间在行界来回摆动时字形反复缩放。
  int _debounceLineSwitch(
    LyricDocument doc,
    Duration pos,
    int current,
    int candidate,
  ) {
    if (candidate == current) return current;
    if (current < 0 || current >= doc.lines.length) return candidate;

    if (candidate > current) {
      // findLineIndex 内部会叠加文档 offset，这里换算回显示相位空间的行首
      final lineStart = doc.lines[candidate].startTime - doc.offset;
      if (pos < lineStart + _lineSwitchGuard) return current;
    } else {
      final currentStart = doc.lines[current].startTime - doc.offset;
      if (pos + _lineSwitchGuard >= currentStart) return current;
    }
    return candidate;
  }

  /// Manually or automatically update playback status and position
  void updatePlaybackState({
    required Duration position,
    required bool isPlaying,
  }) {
    if (_disposed) return;
    _anchorClock(position);
    _isPlaying = isPlaying;
    _syncTicker();
    _tick();
  }

  /// Load a lyric document directly (e.g. from a local file or test)
  void loadLyricDocument(LyricDocument doc) {
    if (_disposed) return;
    _userOffset = Duration.zero;
    currentLyrics.value = doc;
    activeLineIndex.value = doc.isNotEmpty ? doc.findLineIndex(displayPosition) : -1;
    lyricsState.value =
        doc.isNotEmpty ? LyricsSyncState.ready : LyricsSyncState.notFound;
  }

  /// 手动校准：把目标行对齐到“此刻”，只改歌词相位，不回写媒体时钟。
  ///
  /// 适用于不推送 timeline 的播放器（显示时钟自身递增），也适用于时间轴有偏差
  /// 的播放器（后续轮询继续按 playerPosition + _userOffset 定位）。
  void calibrateToLine(int index) {
    if (_disposed) return;
    final doc = currentLyrics.value;
    if (index < 0 || index >= doc.lines.length) return;

    final target = doc.lines[index].startTime;
    _userOffset = target - doc.offset - _estimatedPosition();
    activeLineIndex.value = index;
    if (_isPlaying && _ticker == null) _startTicker();
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
      activeLineIndex.value = doc.findLineIndex(displayPosition);
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

    if (titleChanged) {
      _userOffset = Duration.zero;
      _isPlaying = track.isPlaying;
      _anchorClock(track.position);
      // 换曲即作废在途检索，并清空旧歌词，避免新曲目沿用上一首的歌词与行指针
      _trackGeneration++;
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      lyricsState.value = track.hasContent
          ? LyricsSyncState.searching
          : LyricsSyncState.noMedia;
    } else {
      // 同一曲目：SMTC 每秒快照本身可能滞后，若直接覆盖锚点会让（显示）时间回跳，
      // 行指针便在相邻两行之间来回翻动。因此以单调时钟为准，只接受明显的前跳与大回退。
      final estimated = _estimatedPosition();
      if (!track.isPlaying) {
        // 暂停：把已流逝时间折算进锚点后冻结
        _anchorClock(estimated);
      } else if (!_isPlaying) {
        // 从暂停恢复：只接受更靠后的位置，避免恢复瞬间回跳
        _anchorClock(
          track.position > estimated ? track.position : estimated,
        );
      } else if (track.position > Duration.zero) {
        final delta = track.position - estimated;
        if (delta >= _forwardResync) {
          _anchorClock(track.position);
        } else if (delta <= -_backwardSeekFloor) {
          _anchorClock(track.position);
        }
        // 小幅回退（≤3s）判定为快照滞后，忽略并保持当前单调时钟
      }
      _isPlaying = track.isPlaying;
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
        final doc = currentLyrics.value;
        final idx = doc.findLineIndex(displayPosition);
        final resolved =
            _debounceLineSwitch(doc, displayPosition, activeLineIndex.value, idx);
        if (resolved != activeLineIndex.value) {
          activeLineIndex.value = resolved;
        }
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
      activeLineIndex.value = doc.findLineIndex(displayPosition);
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
