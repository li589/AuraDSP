// part of audio_isolate.dart —— P1 按区拆分，纯搬运零改行。
part of 'audio_isolate.dart';
/* ---------------- WAV 解码 ---------------- */

final class DecodedWav {
  final Float32List data; // stereo interleaved
  final int sampleRate;
  DecodedWav(this.data, this.sampleRate);
}

DecodedWav? decodeWavFile(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  if (bytes.length < 44) return null;
  if (bytes[0] != 0x52 || bytes[1] != 0x49) return null; // "RI"
  var off = 12; // 跳过 RIFF size + WAVE
  int fmtTag = 0, ch = 0, rate = 0, bits = 0;
  int dataOff = -1, dataLen = 0;
  while (off + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(off, off + 4));
    final sz = bd.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') {
      fmtTag = bd.getUint16(off + 8, Endian.little);
      ch = bd.getUint16(off + 10, Endian.little);
      rate = bd.getUint32(off + 12, Endian.little);
      bits = bd.getUint16(off + 8 + 14, Endian.little);
      if (fmtTag == 0xFFFE && sz >= 40) {
        // SubFormat 首个 DWORD 即 subtype 序号（PCM=1/FLOAT=3）
        fmtTag = bd.getUint32(off + 8 + 24, Endian.little);
      }
    } else if (id == 'data') {
      dataOff = off + 8;
      dataLen = math.min(sz, bytes.length - dataOff);
    }
    off += 8 + sz + (sz & 1); // RIFF chunk 对齐 2
  }
  if (dataOff < 0 || ch < 1 || rate < 8000) return null;

  final frames = dataLen ~/ (bits ~/ 8 * ch);
  final out = Float32List(frames * 2);
  const scale = 1.0 / 2147483648.0;
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < 2; c++) {
      final srcCh = c % ch;
      final base = dataOff + f * ch * (bits ~/ 8) + srcCh * (bits ~/ 8);
      double v;
      switch (bits) {
        case 16:
          v = bd.getInt16(base, Endian.little) / 32768.0;
          break;
        case 24:
          // 符号扩展 24 位 → [-1,1)
          final s = ((bytes[base + 2] << 24) |
                  (bytes[base + 1] << 16) |
                  (bytes[base] << 8)) >>
              8;
          v = s / 8388608.0;
          break;
        case 32:
          v = fmtTag == 3
              ? bd.getFloat32(base, Endian.little)
              : bd.getInt32(base, Endian.little) * scale;
          break;
        default:
          return null;
      }
      out[f * 2 + c] = v.isFinite ? v.clamp(-1.0, 1.0) : 0.0;
    }
  }
  return DecodedWav(out, rate);
}
