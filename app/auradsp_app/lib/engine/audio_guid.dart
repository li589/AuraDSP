// part of audio_isolate.dart —— P1 按区拆分，纯搬运零改行。
part of 'audio_isolate.dart';
/* ---------------- GUID ---------------- */

final class Guid extends Struct {
  @Uint32()
  external int d1;
  @Uint16()
  external int d2;
  @Uint16()
  external int d3;
  @Array(8)
  external Array<Uint8> d4;

  static Pointer<Guid> alloc(String s) {
    final p = malloc<Guid>();
    final hex = s.replaceAll('-', '');
    p.ref.d1 = int.parse(hex.substring(0, 8), radix: 16);
    p.ref.d2 = int.parse(hex.substring(8, 12), radix: 16);
    p.ref.d3 = int.parse(hex.substring(12, 16), radix: 16);
    for (var i = 0; i < 8; i++) {
      p.ref.d4[i] = int.parse(hex.substring(16 + i * 2, 18 + i * 2), radix: 16);
    }
    return p;
  }
}

const _iidDeviceEnumerator = 'A95664D2-9614-4F35-A746-DE8DB63617E6';
const _clsidDeviceEnumerator = 'BCDE0395-E52F-467C-8E3D-C4579291692E';
const _iidAudioClient = '1CB9AD4C-DBFA-4C32-B178-C2F568A703B2';
const _iidAudioRenderClient = 'F294ACFC-3146-4483-A7BF-ADDCA7C260E2';

// KSDATAFORMAT_SUBTYPE_* 在 WAVEFORMATEXTENSIBLE 内存中的小端字节
// {00000003-0000-0010-8000-00AA00389B71} IEEE_FLOAT
const _subFloatLe = [
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
  0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
];
// {00000001-0000-0010-8000-00AA00389B71} PCM
const _subPcmLe = [
  0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
  0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
];
