// mpris_provider_test.dart — S5b MPRIS 媒体会话提供者的活体断言。
//
// 需要会话总线：无 DBUS_SESSION_BUS_ADDRESS 时整组跳过（CI 的
// dart-tests job 无桌面会话）。本地以
//   dbus-run-session -- flutter test test/mpris_provider_test.dart
// 运行：测试自注册一个假的 org.mpris.MediaPlayer2.fakeplayer，
// 再让 MprisProvider 枚举并读取其 Metadata/PlaybackStatus/Position，
// 断言归一化后的 MediaTrackMetadata 与注册值一致。
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/media_track.dart';
import 'package:auradsp_app/platform/media/media_session_linux.dart';

class FakePlayer extends DBusObject {
  FakePlayer() : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  static final Map<String, DBusValue> _props = {
    'PlaybackStatus': DBusString('Playing'),
    'Position': DBusInt64(42000000),
    'Metadata': DBusDict(
      DBusSignature('s'),
      DBusSignature('v'),
      {
        DBusString('xesam:title'):
            DBusVariant(DBusString('Blue Suede Shoes')),
        DBusString('xesam:artist'): DBusVariant(DBusArray(
            DBusSignature('s'), [DBusString('Carl Perkins')])),
        DBusString('xesam:album'):
            DBusVariant(DBusString('Original Sun Greatest Hits')),
        DBusString('mpris:length'): DBusVariant(DBusInt64(179000000)),
      },
    ),
  };

  @override
  Future<DBusMethodResponse> getProperty(
      String interface, String name) async {
    if (interface == 'org.mpris.MediaPlayer2.Player' &&
        _props.containsKey(name)) {
      return DBusGetPropertyResponse(_props[name]!);
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == 'org.mpris.MediaPlayer2.Player') {
      return DBusGetAllPropertiesResponse(_props);
    }
    return DBusGetAllPropertiesResponse({});
  }
}

void main() {
  test('MprisProvider reads a live MPRIS player', () async {
    if (!Platform.isLinux ||
        Platform.environment['DBUS_SESSION_BUS_ADDRESS'] == null) {
      return; // 无会话总线：跳过（见文件头）。
    }
    final server = DBusClient.session();
    final nameReply =
        await server.requestName('org.mpris.MediaPlayer2.fakeplayer');
    expect(nameReply, DBusRequestNameReply.primaryOwner);
    await server.registerObject(FakePlayer());

    final provider = MprisProvider();
    final firstTrack = provider.trackStream.first.timeout(
      const Duration(seconds: 15),
      onTimeout: () => MediaTrackMetadata.empty,
    );
    provider.start();
    final track = await firstTrack;
    provider.dispose();
    await server.close();

    expect(track.title, 'Blue Suede Shoes');
    expect(track.artist, 'Carl Perkins');
    expect(track.album, 'Original Sun Greatest Hits');
    expect(track.isPlaying, isTrue);
    expect(track.duration, const Duration(seconds: 179));
    expect(track.position, const Duration(seconds: 42));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
