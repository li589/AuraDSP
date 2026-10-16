// fold51_test.dart — Phase 2 5.1 混缩回归：解码层 Dolby fold 系数。
// 声道序 WAVE 标准：5.1 = L R C LFE LS RS；4ch = L R LS RS；3ch = L R C。
import 'dart:io';
import 'dart:typed_data';

import 'package:auradsp_app/engine/audio_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

String _writeWav(int ch, List<List<double>> frames) {
  final n = frames.length;
  final data = BytesBuilder();
  for (final fr in frames) {
    for (var c = 0; c < ch; c++) {
      final v = (fr[c].clamp(-1.0, 1.0) * 32767).round();
      data.add([(v & 0xFF), ((v >> 8) & 0xFF)]);
    }
  }
  final raw = data.toBytes();
  final h = BytesBuilder();
  void u32(int v) => h.add([
        v & 0xFF,
        ((v >> 8) & 0xFF),
        ((v >> 16) & 0xFF),
        ((v >> 24) & 0xFF)
      ]);
  void u16(int v) => h.add([v & 0xFF, ((v >> 8) & 0xFF)]);
  h.add('RIFF'.codeUnits);
  u32(36 + raw.length);
  h.add('WAVE'.codeUnits);
  h.add('fmt '.codeUnits);
  u32(16);
  u16(1);
  u16(ch);
  u32(48000);
  u32(48000 * ch * 2);
  u16(ch * 2);
  u16(16);
  h.add('data'.codeUnits);
  u32(raw.length);
  final all = BytesBuilder()
    ..add(h.toBytes())
    ..add(raw);
  final f = File(
      '${Directory.systemTemp.path}/fold51_${ch}ch_${n}f.wav');
  f.writeAsBytesSync(all.toBytes());
  return f.path;
}

void main() {
  test('5.1 fold follows Dolby coefficients', () {
    // L=R=C=LFE=LS=RS=0.2 → L=R=0.2+0.14142+0.14142+0.1
    final p = _writeWav(6, [
      [0.2, 0.2, 0.2, 0.2, 0.2, 0.2]
    ]);
    final d = decodeWavFile(p)!;
    expect(d.data[0], closeTo(0.5828, 0.002));
    expect(d.data[1], closeTo(0.5828, 0.002));
  });

  test('quad/3ch/mono fold correctly', () {
    var d = decodeWavFile(_writeWav(4, [
      [0.4, 0.2, 0.4, 0.2]
    ]))!;
    expect(d.data[0], closeTo(0.4 + 0.4 * 0.70711, 0.002));
    expect(d.data[1], closeTo(0.2 + 0.2 * 0.70711, 0.002));
    d = decodeWavFile(_writeWav(3, [
      [0.4, 0.1, 0.4]
    ]))!;
    expect(d.data[0], closeTo(0.4 + 0.4 * 0.70711, 0.002));
    expect(d.data[1], closeTo(0.1 + 0.4 * 0.70711, 0.002));
    d = decodeWavFile(_writeWav(1, [
      [0.4]
    ]))!;
    expect(d.data[0], closeTo(0.4, 0.002));
    expect(d.data[1], closeTo(0.4, 0.002));
  });

  test('stereo passes through bit-near-identical', () {
    final d = decodeWavFile(_writeWav(2, [
      [0.3, -0.3]
    ]))!;
    expect(d.data[0], closeTo(0.3, 0.002));
    expect(d.data[1], closeTo(-0.3, 0.002));
  });
}
