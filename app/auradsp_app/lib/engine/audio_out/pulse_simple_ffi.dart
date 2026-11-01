// pulse_simple_ffi.dart —— PulseAudio simple API 的共享 FFI 类型。
//
// pa_sample_spec / pa_buffer_attr 结构体与 pa_simple_* 函数原型此前在
// audio_out_linux.dart 与 audio_in_linux.dart 各定义一份——PA 的 ABI
// 布局一旦理解漂移，两份镜像就会静默分叉（与 G7-1 viz 镜像单源门禁
// 同类风险）。抽到这里单源定义，两侧只保留各自的库持有与业务逻辑。
import 'dart:ffi';

import 'package:ffi/ffi.dart' show Utf8;

const paStreamPlayback = 1; // PA_STREAM_PLAYBACK
const paStreamRecord = 2; // PA_STREAM_RECORD
const paSampleFloat32Le = 5; // PA_SAMPLE_FLOAT32LE
const paUsecPerSec = 1000000;

/// pa_sample_spec（pulse/sample.h）。
final class PaSampleSpec extends Struct {
  @Int32()
  external int format;
  @Uint32()
  external int rate;
  @Uint8()
  external int channels;
}

/// pa_buffer_attr（pulse/def.h）。字段以 0xFFFFFFFF(-1) 表示服务端默认。
final class PaBufferAttr extends Struct {
  @Uint32()
  external int maxlength;
  @Uint32()
  external int tlength;
  @Uint32()
  external int prebuf;
  @Uint32()
  external int minreq;
  @Uint32()
  external int fragsize;
}

typedef PaSimpleNewNative = Pointer<Void> Function(
    Pointer<Utf8>, // server (NULL = default)
    Pointer<Utf8>, // name (application name)
    Int32, // dir (PA_STREAM_PLAYBACK / PA_STREAM_RECORD)
    Pointer<Utf8>, // dev (NULL = default)
    Pointer<Utf8>, // stream_name
    Pointer<PaSampleSpec>,
    Pointer<Void>, // channel map (NULL)
    Pointer<PaBufferAttr>,
    Pointer<Int32>); // error
typedef PaSimpleNewDart = Pointer<Void> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<PaSampleSpec>,
    Pointer<Void>,
    Pointer<PaBufferAttr>,
    Pointer<Int32>);

typedef PaSimpleWriteNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Size, Pointer<Int32>);
typedef PaSimpleReadNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Size, Pointer<Int32>);
typedef PaSimpleIoDart = int Function(
    Pointer<Void>, Pointer<Void>, int, Pointer<Int32>);

typedef PaSimpleUnaryNative = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef PaSimpleUnaryDart = int Function(Pointer<Void>, Pointer<Int32>);

typedef PaSimpleFreeNative = Void Function(Pointer<Void>);
typedef PaSimpleGetLatencyNative = Uint64 Function(
    Pointer<Void>, Pointer<Int32>);
typedef PaStrerrorNative = Pointer<Utf8> Function(Int32);
