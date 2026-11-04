// media_session_linux.dart — MediaSessionPort 的 Linux 实现（MPRIS）。
//
// 与 Windows 的 SMTC 提供者对称：读取系统里其它播放器的当前曲目，
// 供歌词同步消费。Linux 的对应面是 MPRIS（org.mpris.MediaPlayer2）。
//
// 信号化（2026-11-04，关闭审查 F6 的 2 秒总线轮询）：
//   - 播放器集合的变化走 NameOwnerChanged（dbus 包的现成事件流）；
//   - Metadata / PlaybackStatus 的变化走 PropertiesChanged 订阅；
//   - 跳转走 Seeked 信号（携带精确位置）；
//   - Position 本身按 MPRIS 规范不发信号——但不再为它轮询总线：
//     以（锚位置, 锚时刻）在本地按秒外推，1 秒一拍的本地计时器
//     只做算术、零总线流量，且仅在选中曲目处于 Playing 时运行。
// 总线往返只发生在启动枚举与上述事件上。总线故障的恢复走慢速
// 重试（5 秒），且保持 F2 口径：失败只在进入故障时记一次。
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

/// 单个播放器的事件驱动状态：属性快照 + 位置锚。
///
/// 位置不变量：任意时刻的播放位置 = 锚位置 +（Playing 时的流逝
/// 时间）。状态切换、换歌、Seeked、Position 属性到达都会重锚。
class _PlayerState {
  String status = '';
  String title = '';
  String artist = '';
  String album = '';
  int lengthUs = 0;
  int anchorPosUs = 0;
  DateTime anchorTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isPlaying => status == 'Playing';
  bool get hasContent => title.isNotEmpty || artist.isNotEmpty;

  /// 把一次 GetAllProperties 的全量结果灌入（初始读取）。
  void applyAll(Map<String, DBusValue> props, DateTime now) {
    final st = _asString(props['PlaybackStatus']);
    if (st != null) status = st;
    final meta = props['Metadata'];
    if (meta is DBusDict) _applyMetadata(meta);
    final pos = _asInt(props['Position']);
    anchorPosUs = pos ?? 0;
    anchorTime = now;
  }

  /// 应用一条 PropertiesChanged 增量（changedProperties 字典）。
  void applyChanged(DBusDict changed, DateTime now) {
    changed.children.forEach((k, v) {
      if (k is! DBusString || v is! DBusVariant) return;
      switch (k.value) {
        case 'PlaybackStatus':
          // 先把锚推进到当前外推点再切状态，暂停/恢复不漂移。
          anchorPosUs = positionUsAt(now);
          anchorTime = now;
          final st = _asString(v.value);
          if (st != null) status = st;
        case 'Metadata':
          if (v.value is DBusDict) {
            _applyMetadata(v.value as DBusDict);
            // 换歌惯例：位置归零（若同一信号里另带 Position，
            // 其处理在后，会覆盖本锚）。
            anchorPosUs = 0;
            anchorTime = now;
          }
        case 'Position':
          final pos = _asInt(v.value);
          if (pos != null) {
            anchorPosUs = pos;
            anchorTime = now;
          }
      }
    });
  }

  void applySeeked(int posUs, DateTime now) {
    anchorPosUs = posUs;
    anchorTime = now;
  }

  void _applyMetadata(DBusDict meta) {
    final fields = <String, DBusValue>{};
    meta.children.forEach((k, v) {
      if (k is DBusString && v is DBusVariant) fields[k.value] = v.value;
    });
    title = _asString(fields['xesam:title']) ?? '';
    artist = _asStringList(fields['xesam:artist']).join(', ');
    album = _asString(fields['xesam:album']) ?? '';
    lengthUs = _asInt(fields['mpris:length']) ?? 0;
  }

  int positionUsAt(DateTime now) {
    if (!isPlaying) return anchorPosUs;
    var p = anchorPosUs + now.difference(anchorTime).inMicroseconds;
    if (lengthUs > 0 && p > lengthUs) p = lengthUs;
    return p < 0 ? 0 : p;
  }

  MediaTrackMetadata at(DateTime now) {
    // 位置量化到整秒：歌词同步的粒度足够，也让外推值稳定
    // （首帧 == 播放器报告值，不带毫秒尾巴）。
    final posSec = positionUsAt(now) ~/ Duration.microsecondsPerSecond;
    return MediaTrackMetadata(
      title: title,
      artist: artist,
      album: album,
      duration: Duration(microseconds: lengthUs),
      position: Duration(seconds: posSec),
      isPlaying: isPlaying,
    );
  }

  static String? _asString(DBusValue? v) => v is DBusString ? v.value : null;

  static int? _asInt(DBusValue? v) {
    if (v is DBusInt64) return v.value;
    if (v is DBusUint64) return v.value;
    if (v is DBusInt32) return v.value;
    if (v is DBusUint32) return v.value;
    return null;
  }

  static List<String> _asStringList(DBusValue? v) {
    if (v is DBusArray) {
      return v.children.whereType<DBusString>().map((e) => e.value).toList();
    }
    final single = _asString(v);
    return single == null || single.isEmpty ? const [] : [single];
  }
}

class MprisProvider implements MediaSessionProvider {
  static const String _prefix = 'org.mpris.MediaPlayer2.';
  static const String _playerIface = 'org.mpris.MediaPlayer2.Player';
  static const String _propsIface = 'org.freedesktop.DBus.Properties';
  static final DBusObjectPath _path =
      DBusObjectPath('/org/mpris/MediaPlayer2');
  static const Duration _tickInterval = Duration(seconds: 1);
  static const Duration _recoveryDelay = Duration(seconds: 5);

  final StreamController<MediaTrackMetadata> _controller =
      StreamController<MediaTrackMetadata>.broadcast();

  DBusClient? _client;
  StreamSubscription<DBusNameOwnerChangedEvent>? _nameSub;
  StreamSubscription<DBusSignal>? _propsSub;
  StreamSubscription<DBusSignal>? _seekSub;
  Timer? _tick;
  Timer? _recovery;
  final Map<String, _PlayerState> _players = {};
  final Map<String, String> _uniqueToName = {};
  MediaTrackMetadata _last = MediaTrackMetadata.empty;
  bool _disposed = false;
  bool _started = false;

  /// 总线故障态：失败只在进入故障时记一次（审查 F2）——无桌面会话的
  /// 环境里若每轮重试都 swallow，会把错误汇刷满。
  bool _busDown = false;

  @override
  Stream<MediaTrackMetadata> get trackStream => _controller.stream;

  @override
  void start() {
    if (_disposed || _started) return;
    if (PlatformProfile.os != 'linux') return;
    _started = true;
    unawaited(_init());
  }

  @override
  void stop() {
    _started = false;
    _teardownBus();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _client?.close();
    _client = null;
    _controller.close();
  }

  /// 建连 + 订阅 + 初始枚举。先订阅后枚举，避免间隙里丢事件
  /// （枚举到的播放器再按名去重合并）。
  Future<void> _init() async {
    if (_disposed || !_started) return;
    try {
      _client ??= DBusClient.session();
      final client = _client!;
      _nameSub = client.nameOwnerChanged.listen(
        _onNameOwnerChanged,
        onError: _onStreamError,
      );
      _propsSub = DBusSignalStream(
        client,
        interface: _propsIface,
        name: 'PropertiesChanged',
        path: _path,
      ).listen(_onPropertiesChanged, onError: _onStreamError);
      _seekSub = DBusSignalStream(
        client,
        interface: _playerIface,
        name: 'Seeked',
        path: _path,
      ).listen(_onSeeked, onError: _onStreamError);
      final names = await client.listNames();
      for (final name in names.where((n) => n.startsWith(_prefix))) {
        await _addPlayer(name);
      }
      _busDown = false;
      _refresh();
    } catch (e, st) {
      _onBusFailure(e, st);
    }
  }

  void _teardownBus() {
    _tick?.cancel();
    _tick = null;
    _recovery?.cancel();
    _recovery = null;
    unawaited(_nameSub?.cancel());
    unawaited(_propsSub?.cancel());
    unawaited(_seekSub?.cancel());
    _nameSub = null;
    _propsSub = null;
    _seekSub = null;
    _players.clear();
    _uniqueToName.clear();
  }

  void _onStreamError(Object e) {
    if (_disposed || !_started) return;
    _onBusFailure(e, null);
  }

  /// 会话总线不可用（无桌面会话等）：静默降级为无曲目；旧客户端
  /// 先关再弃，故障只在进入时记一次（审查 F2）；慢速重试恢复。
  void _onBusFailure(Object e, StackTrace? st) {
    final stale = _client;
    _client = null;
    _teardownBus();
    if (stale != null) unawaited(stale.close());
    _emit(MediaTrackMetadata.empty);
    if (!_disposed && !_busDown && st != null) swallow(e, st);
    _busDown = true;
    if (_started && !_disposed) {
      _recovery = Timer(_recoveryDelay, () => unawaited(_init()));
    }
  }

  Future<void> _addPlayer(String name) async {
    final client = _client;
    if (client == null || _disposed) return;
    try {
      final owner = await client.getNameOwner(name);
      if (owner != null) _uniqueToName[owner] = name;
      final obj = DBusRemoteObject(client, name: name, path: _path);
      final props = await obj.getAllProperties(_playerIface);
      final state = _PlayerState()..applyAll(props, DateTime.now());
      if (!_disposed && _started) {
        _players[name] = state;
      }
    } catch (e, st) {
      // 单个播放器读取失败（刚退出等）不拖垮整轮枚举。
      swallow(e, st);
    }
  }

  void _onNameOwnerChanged(DBusNameOwnerChangedEvent e) {
    if (_disposed || !_started || !e.name.startsWith(_prefix)) return;
    final newOwner = e.newOwner;
    if (newOwner == null || newOwner.isEmpty) {
      _players.remove(e.name);
      _uniqueToName.removeWhere((_, v) => v == e.name);
      _refresh();
    } else {
      _uniqueToName[newOwner] = e.name;
      unawaited(_addPlayer(e.name).then((_) => _refresh()));
    }
  }

  void _onPropertiesChanged(DBusSignal signal) {
    if (_disposed || !_started) return;
    final name = _uniqueToName[signal.sender];
    final state = name == null ? null : _players[name];
    if (state == null || signal.values.length < 2) return;
    final iface = signal.values[0];
    if (iface is! DBusString || iface.value != _playerIface) return;
    final changed = signal.values[1];
    if (changed is! DBusDict) return;
    state.applyChanged(changed, DateTime.now());
    _refresh();
  }

  void _onSeeked(DBusSignal signal) {
    if (_disposed || !_started) return;
    final name = _uniqueToName[signal.sender];
    final state = name == null ? null : _players[name];
    if (state == null || signal.values.isEmpty) return;
    final pos = signal.values[0];
    if (pos is DBusInt64) {
      state.applySeeked(pos.value, DateTime.now());
      _refresh();
    }
  }

  /// 按当前状态重选曲目并推送；同时管理本地外推计时器的启停
  /// （仅选中曲目处于 Playing 时才需要逐秒推进位置）。
  void _refresh() {
    if (_disposed) return;
    _PlayerState? best;
    var bestScore = -1;
    for (final state in _players.values) {
      if (!state.hasContent) continue;
      // 选取优先级：正在播放 > 暂停；同级取先枚举到的（插入序稳定）。
      final score = state.isPlaying ? 2 : 1;
      if (score > bestScore) {
        best = state;
        bestScore = score;
      }
    }
    _emit(best?.at(DateTime.now()) ?? MediaTrackMetadata.empty);
    final wantTick = best != null && best.isPlaying;
    if (wantTick && _tick == null) {
      _tick = Timer.periodic(_tickInterval, (_) => _refresh());
    } else if (!wantTick) {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _emit(MediaTrackMetadata track) {
    if (_disposed) return;
    // 与 Windows 提供者同口径：状态有变就推（含 Position 推进，歌词
    // 同步靠它）；仅当整条元数据逐字段未变时跳过，避免静止状态下
    // 的无谓刷新。
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
}
