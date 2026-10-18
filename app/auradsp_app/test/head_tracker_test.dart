import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/engine/head_tracker.dart';

void main() {
  group('OpenTrack UDP yaw parser', () {
    test('parses 6-double packet', () {
      final data = ByteData(48);
      data.setFloat64(0, 42.5, Endian.little);
      expect(parseOpenTrackYaw(data.buffer.asUint8List()), 42.5);
    });

    test('parses 6-float packet', () {
      final data = ByteData(24);
      data.setFloat32(0, -17.25, Endian.little);
      expect(parseOpenTrackYaw(data.buffer.asUint8List()), -17.25);
    });

    test('clamps yaw to +/-180', () {
      final data = ByteData(48);
      data.setFloat64(0, 999.0, Endian.little);
      expect(parseOpenTrackYaw(data.buffer.asUint8List()), 180.0);
      data.setFloat64(0, -999.0, Endian.little);
      expect(parseOpenTrackYaw(data.buffer.asUint8List()), -180.0);
    });

    test('rejects short/invalid packets', () {
      expect(parseOpenTrackYaw(List<int>.filled(8, 0)), isNull);
      final data = ByteData(48);
      data.setFloat64(0, double.nan, Endian.little);
      expect(parseOpenTrackYaw(data.buffer.asUint8List()), isNull);
    });
  });
}
