// mpris_provider_test.dart — MPRIS 媒体会话提供者的活体断言。
//
// 需要会话总线：无 DBUS_SESSION_BUS_ADDRESS 时整组跳过（CI 的
// dart-tests job 无桌面会话）。本地以
//   dbus-run-session -- flutter test test/mpris_provider_test.dart
// 运行：测试自注册一个假的 org.mpris.MediaPlayer2.fakeplayer，
// 再让 MprisProvider 读取其 Metadata/PlaybackStatus/Position 并
// 断言归一化结果；2026-11-04 信号化后追加事件驱动断言：位置靠
// 本地外推推进（期间 GetAllProperties 调用数不变）、元数据变化
// 与 Seeked 经信号即时到达、播放器消失即时清空。
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/media_track.dart';
import 'package:auradsp_app/platform/media/media_session_linux.dart';

class FakePlayer extends DBusObject {
  FakePlayer() : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  static const String iface = 'org.mpris.MediaPlayer2.Player';

  final Map<String, DBusValue> props = {
    'PlaybackStatus': DBusString('Playing'),
    'Position': DBusInt64(42000000),
    'Metadata': _metadata('Blue Suede Shoes'),
  };

  int getAllCount = 0;

  static DBusValue _metadata(String title) => DBusDict(
        DBusSignature('s'),
        DBusSignature('v'),
        {
          DBusString('xesam:title'): DBusVariant(DBusString(title)),
          DBusString('xesam:artist'): DBusVariant(DBusArray(
              DBusSignature('s'), [DBusString('Carl Perkins')])),
          DBusString('xesam:album'):
              DBusVariant(DBusString('Original Sun Greatest Hits')),
          DBusString('mpris:length'): DBusVariant(DBusInt64(179000000)),
        },
      );

  Future<void> changeTitle(String title) async {
    props['Metadata'] = _metadata(title);
    await emitPropertiesChanged(iface, changedProperties: {
      'Metadata': _metadata(title),
    });
  }

  Future<void> seek(int posUs) async {
    props['Position'] = DBusInt64(posUs);
    await emitSignal(iface, 'Seeked', [DBusInt64(posUs)]);
  }

  Future<void> setStatus(String status) async {
    props['PlaybackStatus'] = DBusString(status);
    await emitPropertiesChanged(iface, changedProperties: {
      'PlaybackStatus': DBusString(status),
    });
  }

  @override
  Future<DBusMethodResponse> getProperty(
      String interface, String name) async {
    if (interface == iface && props.containsKey(name)) {
      return DBusGetPropertyResponse(props[name]!);
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == iface) {
      getAllCount++;
      return DBusGetAllPropertiesResponse(props);
    }
    return DBusGetAllPropertiesResponse({});
  }
}

Future<bool> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return cond();
}

void main() {
  test('MprisProvider reads a live MPRIS player (signalized)', () async {
    if (!Platform.isLinux ||
        Platform.environment['DBUS_SESSION_BUS_ADDRESS'] == null) {
      return; // 无会话总线：跳过（见文件头）。
    }
    final server = DBusClient.session();
    final nameReply =
        await server.requestName('org.mpris.MediaPlayer2.fakeplayer');
    expect(nameReply, DBusRequestNameReply.primaryOwner);
    final fake = FakePlayer();
    await server.registerObject(fake);

    final provider = MprisProvider();
    final events = <MediaTrackMetadata>[];
    final sub = provider.trackStream.listen(events.add);
    provider.start();

    // 初始枚举：全量读取一次，首帧与注册值一致（含位置整秒值）。
    expect(await _waitFor(() => events.isNotEmpty), isTrue,
        reason: '初始曲目未到达');
    final first = events.first;
    expect(first.title, 'Blue Suede Shoes');
    expect(first.artist, 'Carl Perkins');
    expect(first.album, 'Original Sun Greatest Hits');
    expect(first.isPlaying, isTrue);
    expect(first.duration, const Duration(seconds: 179));
    expect(first.position, const Duration(seconds: 42));
    expect(fake.getAllCount, 1);

    // 位置推进靠本地外推：数秒内位置前进 ≥2 秒，
    // 且期间没有任何新的总线全量读取（信号化核心断言）。
    expect(
      await _waitFor(
        () => events.any((t) => t.position >= const Duration(seconds: 44)),
        timeout: const Duration(seconds: 6),
      ),
      isTrue,
      reason: '位置未按外推推进',
    );
    expect(fake.getAllCount, 1,
        reason: '外推期间发生了总线重读（仍在轮询）');

    // 元数据变化经 PropertiesChanged 即时到达（远快于旧 2 秒轮询）。
    events.clear();
    await fake.changeTitle('Heartbreak Hotel');
    expect(
      await _waitFor(() => events.any((t) => t.title == 'Heartbreak Hotel'),
          timeout: const Duration(milliseconds: 1500)),
      isTrue,
      reason: '元数据变化未即时到达',
    );

    // Seeked 信号重锚位置。
    events.clear();
    await fake.seek(99000000);
    expect(
      await _waitFor(
          () => events.any((t) => t.position == const Duration(seconds: 99)),
          timeout: const Duration(milliseconds: 1500)),
      isTrue,
      reason: 'Seeked 未即时重锚',
    );

    // 暂停：状态经信号到达，位置冻结。
    await fake.setStatus('Paused');
    expect(
      await _waitFor(() => events.any((t) => !t.isPlaying),
          timeout: const Duration(milliseconds: 1500)),
      isTrue,
      reason: '暂停状态未即时到达',
    );
    events.clear();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(events.where((t) => t.isPlaying), isEmpty);
    final frozen = events.map((t) => t.position).toSet();
    expect(frozen.length, lessThanOrEqualTo(1),
        reason: '暂停后位置仍在推进');

    // 播放器消失：NameOwnerChanged 即时清空。
    events.clear();
    await server.releaseName('org.mpris.MediaPlayer2.fakeplayer');
    expect(
      await _waitFor(() => events.any((t) => !t.hasContent),
          timeout: const Duration(milliseconds: 1500)),
      isTrue,
      reason: '播放器消失未即时反映',
    );

    await sub.cancel();
    provider.dispose();
    await server.close();
  }, timeout: const Timeout(Duration(seconds: 45)));
}
