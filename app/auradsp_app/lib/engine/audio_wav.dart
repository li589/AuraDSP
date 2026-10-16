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

  if (bits != 16 && bits != 24 && bits != 32) return null;
  final frames = dataLen ~/ (bits ~/ 8 * ch);
  final out = Float32List(frames * 2);
  const scale = 1.0 / 2147483648.0;
  // 通道采样读取（Phase 2 前：仅取 c%ch，前两声道直读，多声道静默丢弃）。
  double rd(int f, int c) {
    final base = dataOff + f * ch * (bits ~/ 8) + c * (bits ~/ 8);
    switch (bits) {
      case 16:
        return bd.getInt16(base, Endian.little) / 32768.0;
      case 24:
        // 符号扩展 24 位 → [-1,1)
        final s = ((bytes[base + 2] << 24) |
                (bytes[base + 1] << 16) |
                (bytes[base] << 8)) >>
            8;
        return s / 8388608.0;
      case 32:
        return fmtTag == 3
            ? bd.getFloat32(base, Endian.little)
            : bd.getInt32(base, Endian.little) * scale;
      default:
        return 0.0;
    }
  }

  // Phase 2：多声道 Dolby 混缩（WAVE 声道序 L R C LFE LS RS；4 声道为
  // L R LS RS；3 声道为 L R C）。叠加后钳位（热 5.1 允许削峰，不断尾）。
  const kC = 0.70710678;
  for (var f = 0; f < frames; f++) {
    double l, r;
    if (ch == 1) {
      l = r = rd(f, 0);
    } else {
      l = rd(f, 0);
      r = rd(f, 1);
      if (ch == 3) {
        final c = rd(f, 2) * kC;
        l += c;
        r += c;
      } else if (ch == 4) {
        l += rd(f, 2) * kC;
        r += rd(f, 3) * kC;
      } else if (ch >= 5) {
        final c = rd(f, 2) * kC;
        l += c;
        r += c;
        // 6 声道才有 LFE（ch==5 无 LFE，环绕前移一位）。
        final lfe = ch >= 6 ? rd(f, 3) * 0.5 : 0.0;
        final ls = rd(f, ch >= 6 ? 4 : 3) * kC;
        final rs = rd(f, ch >= 6 ? 5 : 4) * kC;
        l += lfe + ls;
        r += lfe + rs;
      }
    }
    out[f * 2] = l.isFinite ? l.clamp(-1.0, 1.0) : 0.0;
    out[f * 2 + 1] = r.isFinite ? r.clamp(-1.0, 1.0) : 0.0;
  }
  return DecodedWav(out, rate);
}

/// MP3 解码（engine_audiofile.cpp `auradsp_decode_audio_file`，dr_mp3）。
/// 输出契约与 decodeWavFile 一致（stereo interleave float32）；失败 null。
/// 大文件一次性进内存（与 WAV 路径同等暴露；engine 侧限源文件 64MB）。
DecodedWav? decodeMp3File(AuraDspLib lib, String path) {
  final p = path.toNativeUtf8();
  final ratePtr = malloc<Int32>();
  final framesPtr = malloc<Uint64>();
  try {
    final out = lib.decodeAudioFile(p, ratePtr, framesPtr);
    if (out.address == 0) return null;
    try {
      final n = framesPtr.value.toInt() * 2;
      if (n <= 0 || ratePtr.value < 8000) return null;
      final data = Float32List(n);
      data.setAll(0, out.asTypedList(n));
      return DecodedWav(data, ratePtr.value);
    } finally {
      lib.freeAudioBuffer(out.cast());
    }
  } finally {
    malloc.free(p);
    malloc.free(ratePtr);
    malloc.free(framesPtr);
  }
}
