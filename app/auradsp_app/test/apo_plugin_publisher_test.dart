import 'dart:ffi';
import 'dart:io';

import 'package:auradsp_app/engine/audio_isolate.dart';
import 'package:auradsp_app/engine/bridge_manager.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _OpenFileMappingNative = Pointer<Void> Function(
  Uint32,
  Int32,
  Pointer<Utf16>,
);
typedef _OpenFileMappingDart = Pointer<Void> Function(int, int, Pointer<Utf16>);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);

bool _mappingExists(String name) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final open = kernel32
      .lookupFunction<_OpenFileMappingNative, _OpenFileMappingDart>(
        'OpenFileMappingW',
      );
  final close = kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
    'CloseHandle',
  );
  final nativeName = name.toNativeUtf16();
  Pointer<Void> handle = nullptr;
  try {
    handle = open(0x00000004, 0, nativeName); // FILE_MAP_READ
    return handle.address != 0;
  } finally {
    calloc.free(nativeName);
    if (handle.address != 0) close(handle);
  }
}

String _fixtureName(String label) =>
    'Local\\AuraDSP_ApoPluginPublisher_${label}_$pid';

void main() {
  test('production publisher neither creates nor writes a plugin mapping', () {
    final publisher = ApoPluginPublisher(
      mappingName: _fixtureName('production'),
    )..active = true;
    publisher.syncFromMirror(
      [
        PluginSlotCfg()
          ..loaded = true
          ..path = r'C:\fixtures\production.clap'
          ..id = 'fixture.production',
      ],
      chainEnabled: true,
      pdcEnabled: false,
    );

    expect(
      publisher.publishSlotState(0, const [1, 2, 3]),
      isFalse,
      reason: 'production state publication must be disabled',
    );
    expect(
      _mappingExists(_fixtureName('production')),
      isFalse,
      reason: 'production must not leave behind a user-writable block',
    );
  }, skip: !Platform.isWindows);

  test('explicit trusted test publisher retains its controlled write path', () {
    final name = _fixtureName('trusted');
    final publisher = ApoPluginPublisher(
      trustedTestOnly: true,
      mappingName: name,
    )..active = true;

    expect(publisher.publishSlotState(0, const [1, 2, 3]), isTrue);
    expect(_mappingExists(name), isTrue);
  }, skip: !Platform.isWindows);
}
