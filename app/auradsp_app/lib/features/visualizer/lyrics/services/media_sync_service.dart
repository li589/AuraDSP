import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../../../core/error_sink.dart';
import '../../../../core/io/resource_gate.dart';
import '../../../../core/visualizer_types.dart';
import '../../../../platform/adapters.dart';
import '../../../../platform/port/media_session.dart';
import '../models/lyric_models.dart';
import '../parsers/lrc_parser.dart';
import 'online_lyrics_service.dart';

/// 单元测试用假提供者（生产路径由 MediaSessionPort 创建）。
class MockMediaSessionProvider implements MediaSessionProvider {
  final StreamController<MediaTrackMetadata> _controller =
      StreamController<MediaTrackMetadata>.broadcast();

  @override
  Stream<MediaTrackMetadata> get trackStream => _controller.stream;

  void emitTrack(MediaTrackMetadata track) {
    if (!_controller.isClosed) _controller.add(track);
  }

  @override
  void start() {}

  @override
  void stop() {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// 歌词检索状态：为 UI 提供可见反馈
/// （无媒体 / 检索中 / 已就绪 / 未找到 / 平台不支持系统媒体会话）
enum LyricsSyncState { idle, noMedia, searching, ready, notFound, unsupported }

/// 统一媒体时钟同步与歌词编排调度服务
class MediaSyncService {
  final MediaSessionProvider _provider;
  final OnlineLyricsService _onlineService;

  StreamSubscription<MediaTrackMetadata>? _sessionSub;

  /// 当前曲目的归一化键（title+artist）。SMTC 每秒快照可能出现空白/大小写/
  /// 多余空格抖动，用归一化键比较，避免把同一首歌误判成换曲。
  String? _trackKey;
  DateTime? _lastContentAt;

  /// 同一键已有在途检索：每秒轮询时直接复用，避免重复打网。
  String? _inflightKey;

  /// 用户手动加载了本地歌词 → 同一曲目下不被在线结果覆盖。
  bool _manualLyrics = false;

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

  /// SMTC 空窗容忍：部分播放器会短暂返回 empty（切歌/暂停/会话重建）。
  /// 宽限期内保留上一条曲目与歌词，避免「清空 → 重新 searching」反复闪烁。
  static const Duration _emptyGrace = Duration(seconds: 5);

  /// 当前平台是否具备系统媒体会话服务（Windows SMTC）。Linux/Android 等
  /// 平台尚无对应提供者时，UI 用干净的「暂不支持」标注替代「未检测到媒体」，
  /// 避免用户误以为有媒体在放却匹配不到。
  final bool _hasSystemMediaSession;

  MediaSyncService({
    MediaSessionProvider? provider,
    OnlineLyricsService? onlineService,
    LyricsSource lyricsSource = LyricsSource.auto,
    bool? hasSystemMediaSession,
  })  : _provider =
            provider ?? PlatformAdapters.instance.mediaSession.create(),
        _onlineService = onlineService ?? OnlineLyricsService(),
        _hasSystemMediaSession = hasSystemMediaSession ??
            (provider != null ||
                PlatformAdapters.instance.mediaSession.supported) {
    // 注入的来源随服务一起生效（测试的离线假源同样继承该字段）。
    _onlineService.preference = lyricsSource;
  }

  /// 切换在线歌词来源（R6）：清空旧源缓存，并在有曲目时立即用新源重试。
  void setLyricsSource(LyricsSource source) {
    if (_disposed || _onlineService.preference == source) return;
    _onlineService.preference = source;
    _onlineService.clearCache();
    if (currentTrack.value.hasContent && !_manualLyrics) {
      unawaited(retryLyrics());
    }
  }

  /// 平台媒体会话是否可用（UI 状态文案据此区分 unsupported 与 noMedia）。
  bool get hasSystemMediaSession => _hasSystemMediaSession;

  /// 启动系统媒体传输控制 (SMTC) 监听，自动绑定歌词
  void startAutoSync() {
    _sessionSub?.cancel();
    _provider.start();
    _sessionSub = _provider.trackStream.listen((track) {
      updateTrack(track);
    });

    // 无系统媒体会话服务（Linux/Android 等）：干净标注「暂不支持」，
    // 仍保留本地 LRC 手动加载能力。
    if (!_hasSystemMediaSession && currentLyrics.value.isEmpty) {
      lyricsState.value = LyricsSyncState.unsupported;
      return;
    }

    // 再次开启歌词时若已有曲目但歌词为空（上次检索失败/尚未检索），立即补拉一次
    final track = currentTrack.value;
    if (track.hasContent &&
        currentLyrics.value.isEmpty &&
        lyricsState.value != LyricsSyncState.searching) {
      unawaited(retryLyrics());
    }
  }

  /// 停止自动同步监听（同时停掉 SMTC 子进程，避免后台每秒轮询）
  void stopAutoSync() {
    _sessionSub?.cancel();
    _sessionSub = null;
    _provider.stop();
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
    _manualLyrics = doc.isNotEmpty;
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

  /// 曲目标识归一化：去首尾空白、折叠连续空白、忽略大小写。
  /// 只用于「是否同一首歌」判断，不改变展示文本。
  static String _keyOf(MediaTrackMetadata track) {
    String norm(String s) =>
        s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    return '${norm(track.title)}\u0000${norm(track.artist)}';
  }

  /// 手动重新检索当前曲目歌词（强制跳过负命中缓存）。
  Future<void> retryLyrics() async {
    if (_disposed) return;
    final track = currentTrack.value;
    if (!track.hasContent) {
      lyricsState.value = _hasSystemMediaSession
          ? LyricsSyncState.noMedia
          : LyricsSyncState.unsupported;
      return;
    }

    final key = _keyOf(track);
    _trackKey = key;
    _lastContentAt = DateTime.now();
    _manualLyrics = false;
    await _search(track, key, manual: true);
  }

  /// 在线检索当前曲目。同键已有在途请求时直接复用其结果，避免并发重复打网。
  Future<void> _search(
    MediaTrackMetadata track,
    String key, {
    required bool manual,
  }) async {
    if (_inflightKey == key) return;
    _inflightKey = key;
    lyricsState.value = LyricsSyncState.searching;
    try {
      final doc = await _onlineService.fetchLyrics(
        trackName: track.title,
        artistName: track.artist,
        duration: track.duration,
        force: manual,
      );

      // 查询期间已切曲 / 本地歌词已手动固定 / 服务释放：丢弃结果。
      if (_disposed || _trackKey != key || _manualLyrics) return;

      if (doc != null && doc.isNotEmpty) {
        currentLyrics.value = doc;
        activeLineIndex.value = doc.findLineIndex(displayPosition);
        lyricsState.value = LyricsSyncState.ready;
      } else {
        currentLyrics.value = LyricDocument.empty;
        activeLineIndex.value = -1;
        lyricsState.value = LyricsSyncState.notFound;
      }
    } finally {
      if (_inflightKey == key) _inflightKey = null;
    }
  }

  /// Update current track metadata and search for lyrics
  Future<void> updateTrack(MediaTrackMetadata track) async {
    if (_disposed) return;

    // SMTC 抖动容忍（2026-11-01）：部分播放器会短暂返回 empty（切歌/暂停/
    // 会话重建），或标题/歌手在空白与真实值之间交替。宽限期内保留上一条
    // 曲目与歌词，避免「清空 → 重新 searching」的持续加载循环。
    if (!track.hasContent) {
      final last = _lastContentAt;
      if (currentTrack.value.hasContent &&
          last != null &&
          DateTime.now().difference(last) < _emptyGrace) {
        return;
      }
      _trackKey = null;
      _lastContentAt = null;
      _inflightKey = null;
      _manualLyrics = false;
      currentTrack.value = track;
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      lyricsState.value = _hasSystemMediaSession
          ? LyricsSyncState.noMedia
          : LyricsSyncState.unsupported;
      _syncTicker();
      return;
    }

    final key = _keyOf(track);
    final trackChanged = key != _trackKey;
    _lastContentAt = DateTime.now();
    currentTrack.value = track;

    if (trackChanged) {
      // 换曲：作废旧检索、清空旧歌词；结果有效性由 _trackKey 判定，
      // 不再依赖自增 generation（同曲重试不会互相作废）。
      _trackKey = key;
      _manualLyrics = false;
      _userOffset = Duration.zero;
      _isPlaying = track.isPlaying;
      _anchorClock(track.position);
      currentLyrics.value = LyricDocument.empty;
      activeLineIndex.value = -1;
      lyricsState.value = LyricsSyncState.searching;
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

    // 同一曲目的轮询：仅校正行指针，避免每秒重复发起网络查询。
    if (!trackChanged) {
      if (currentLyrics.value.isNotEmpty) {
        final doc = currentLyrics.value;
        final idx = doc.findLineIndex(displayPosition);
        final resolved = _debounceLineSwitch(
            doc, displayPosition, activeLineIndex.value, idx);
        if (resolved != activeLineIndex.value) {
          activeLineIndex.value = resolved;
        }
        lyricsState.value = LyricsSyncState.ready;
      }
      return;
    }

    await _search(track, key, manual: false);
  }

  /// Look for companion .lrc file on disk
  Future<bool> loadLocalLrcFile(String audioFilePath) async {
    try {
      final extIdx = audioFilePath.lastIndexOf('.');
      if (extIdx <= 0) return false;
      final lrcPath = '${audioFilePath.substring(0, extIdx)}.lrc';
      final read = ResourceGate.readText(lrcPath);
      if (read.ok) {
        final doc = LrcParser.parse(read.text!);
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
