// MirrorAudioOut（2×2 S3）单元测试：节拍/状态只认主输出，
// 镜像扇出、缓冲不足整块跳过、失败摘除且只上报一次。
import 'dart:typed_data';

import 'package:auradsp_app/engine/audio_out/audio_out.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAudioOut implements AudioOut {
  FakeAudioOut({this.rate = 48000, this.buffer = 1024, this.padding = 0});

  final int rate;
  final int buffer;
  int padding;
  bool failWrite = false;
  bool failStop = false;

  @override
  bool started = false;

  final List<int> writes = [];
  int stopCalls = 0;

  @override
  int get sampleRate => rate;

  @override
  int get channels => 2;

  @override
  int get bufferFrames => buffer;

  @override
  int currentPadding() => padding;

  @override
  void init({int? requestedSampleRate}) {}

  @override
  void start() => started = true;

  @override
  void stop() {
    stopCalls++;
    if (failStop) throw StateError('stop failed');
    started = false;
  }

  @override
  void write(Float32List src, {required int frames, int srcCh = 2}) {
    if (failWrite) throw StateError('write failed');
    writes.add(frames);
  }
}

void main() {
  final src = Float32List(1024);

  test('pacing and state delegate to the primary only', () {
    final p = FakeAudioOut(rate: 44100, buffer: 512, padding: 7);
    final m = FakeAudioOut(rate: 48000, buffer: 2048, padding: 3);
    final out = MirrorAudioOut(p, m);
    expect(out.sampleRate, 44100);
    expect(out.bufferFrames, 512);
    expect(out.currentPadding(), 7);
    p.started = true;
    expect(out.started, isTrue);
  });

  test('write fans out to primary and mirror', () {
    final p = FakeAudioOut();
    final m = FakeAudioOut()..started = true;
    final out = MirrorAudioOut(p, m);
    out.write(src, frames: 256);
    expect(p.writes, [256]);
    expect(m.writes, [256]);
  });

  test('mirror block is skipped when its buffer lacks room', () {
    final p = FakeAudioOut();
    final m = FakeAudioOut(buffer: 512, padding: 400)..started = true;
    final out = MirrorAudioOut(p, m);
    out.write(src, frames: 256);
    expect(p.writes, [256]);
    expect(m.writes, isEmpty);
    expect(out.mirror, same(m)); // 跳过不是失败，镜像保留
  });

  test('mirror write failure drops the mirror and reports once', () {
    var reports = 0;
    final p = FakeAudioOut();
    final m = FakeAudioOut()..started = true;
    m.failWrite = true;
    final out = MirrorAudioOut(p, m, onMirrorError: (e, st) => reports++);
    out.write(src, frames: 128);
    out.write(src, frames: 128);
    expect(p.writes, [128, 128]); // 主路不受影响
    expect(out.mirror, isNull);
    expect(reports, 1);
    expect(m.stopCalls, 1); // 摘除时尝试停镜像
  });

  test('stop stops mirror and primary; mirror stop failure is reported '
      'but primary still stops', () {
    var reports = 0;
    final p = FakeAudioOut()..started = true;
    final m = FakeAudioOut()..started = true;
    m.failStop = true;
    final out = MirrorAudioOut(p, m, onMirrorError: (e, st) => reports++);
    out.stop();
    expect(m.stopCalls, 1);
    expect(p.stopCalls, 1);
    expect(p.started, isFalse);
    expect(reports, 1);
  });

  test('no mirror attached: write and stop hit the primary only', () {
    final p = FakeAudioOut()..started = true;
    final out = MirrorAudioOut(p, null);
    out.write(src, frames: 64);
    out.stop();
    expect(p.writes, [64]);
    expect(p.stopCalls, 1);
  });
}
