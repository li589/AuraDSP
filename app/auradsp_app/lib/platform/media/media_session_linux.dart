// media_session_linux.dart — MediaSessionPort 的 Linux 实现（MPRIS）。
//
// 与 Windows 的 SMTC 提供者对称：读取系统里其它播放器的当前曲目，
// 供歌词同步消费。Linux 的对应面是 MPRIS（org.mpris.MediaPlayer2）
// ——播放器在会话总线上以 org.mpris.MediaPlayer2.* 名字注册，
// org.mpris.MediaPlayer2.Player 接口提供 PlaybackStatus / Metadata /
// Position。Position 不发变化信号、靠轮询推进，故本实现 2 秒一轮
// （枚举播放器 → 取全部属性 → 选曲），与歌词同步的容忍度匹配。
// 纯 Dart D-Bus 客户端（dbus 包），不外挂 gdbus/busctl 命令。
import 'dart:async';

import 'package:dbus/dbus.dart';

import '../../core/error_sink.dart';
import '../../core/media_track.dart';
import '../platform_profile.dart';
import '../port/media_session.dart';

final class LinuxMediaSession implements MediaSessionPort {
  const LinuxMediaSession();

  @override
  bool get supported => PlatformProfile.os == 'linux';

  @override
  MediaSessionProvider create() => MprisProvider();
}

class MprisProvider implements MediaSessionProvider {
  static const String _prefix = 'org.mpris.MediaPlayer2.';
  static const String _playerIface = 'org.mpris.MediaPlayer2.Player';
  static final DBusObjectPath _path =
      DBusObjectPath('/org/mpris/MediaPlayer2');
  static const Duration _interval = Duration(seconds: 2);

  final StreamController<MediaTrackMetadata> _controller =
      StreamController<MediaTrackMetadata>.broadcast();

  DBusClient? _client;
  Timer? _timer;
  MediaTrackMetadata _last = MediaTrackMetadata.empty;
  bool _disposed = false;
  bool _polling = false;

  @override
  Stream<MediaTrackMetadata> get trackStream => _controller.stream;

  @override
  void start() {
    if (_disposed || _timer != null) return;
    if (PlatformProfile.os != 'linux') return;
    _timer = Timer.periodic(_interval, (_) => _poll());
    _poll();
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _client?.close();
    _client = null;
    _controller.close();
  }

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      _client ??= DBusClient.session();
      final names = await _client!.listNames();
      final players = names.where((n) => n.startsWith(_prefix)).toList();
      MediaTrackMetadata? best;
      var bestScore = -1;
      for (final name in players) {
        final track = await _readPlayer(name);
        if (track == null || !track.hasContent) continue;
        // 选取优先级：正在播放 > 暂停；同级取先枚举到的（总线序稳定）。
        final score = track.isPlaying ? 2 : 1;
        if (score > bestScore) {
          best = track;
          bestScore = score;
        }
      }
      _emit(best ?? MediaTrackMetadata.empty);
    } catch (e, st) {
      // 会话总线不可用（无桌面会话等）：静默降级为无曲目，不刷错误流。
      _client = null;
      _emit(MediaTrackMetadata.empty);
      if (!_disposed) swallow(e, st);
    } finally {
      _polling = false;
    }
  }

  Future<MediaTrackMetadata?> _readPlayer(String name) async {
    try {
      final obj = DBusRemoteObject(_client!,
          name: name, path: _path);
      final props = await obj.getAllProperties(_playerIface);
      final status = _asString(props['PlaybackStatus']);
      final meta = props['Metadata'];
      if (meta is! DBusDict) return null;
      final fields = <String, DBusValue>{};
      meta.children.forEach((k, v) {
        if (k is DBusString && v is DBusVariant) {
          fields[k.value] = v.value;
        }
      });
      final lengthUs = _asInt(fields['mpris:length']);
      final posUs = _asInt(props['Position']);
      return MediaTrackMetadata(
        title: _asString(fields['xesam:title']) ?? '',
        artist: _asStringList(fields['xesam:artist']).join(', '),
        album: _asString(fields['xesam:album']) ?? '',
        duration: lengthUs == null
            ? Duration.zero
            : Duration(microseconds: lengthUs),
        position: posUs == null
            ? Duration.zero
            : Duration(microseconds: posUs),
        isPlaying: status == 'Playing',
      );
    } catch (_) {
      // 单个播放器读取失败（刚退出等）不拖垮整轮枚举。
      return null;
    }
  }

  void _emit(MediaTrackMetadata track) {
    if (_disposed) return;
    // 与 Windows 提供者同口径：每轮都推（含 Position 推进，歌词同步靠它）；
    // 仅当整条元数据逐字段未变时跳过，避免静止状态下的无谓刷新。
    final unchanged = track.title == _last.title &&
        track.artist == _last.artist &&
        track.album == _last.album &&
        track.isPlaying == _last.isPlaying &&
        track.duration == _last.duration &&
        track.position == _last.position;
    _last = track;
    if (!unchanged && !_controller.isClosed) {
      _controller.add(track);
    }
  }

  static String? _asString(DBusValue? v) =>
      v is DBusString ? v.value : null;

  static int? _asInt(DBusValue? v) {
    if (v is DBusInt64) return v.value;
    if (v is DBusUint64) return v.value;
    if (v is DBusInt32) return v.value;
    if (v is DBusUint32) return v.value;
    return null;
  }

  static List<String> _asStringList(DBusValue? v) {
    if (v is DBusArray) {
      return v.children
          .whereType<DBusString>()
          .map((e) => e.value)
          .toList();
    }
    final single = _asString(v);
    return single == null || single.isEmpty ? const [] : [single];
  }
}
