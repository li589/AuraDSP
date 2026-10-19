import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/engine/local_channel_policy.dart';

int _ch({
  bool hasRaw = true,
  int rawCh = 6,
  bool passthrough51 = false,
  bool bypass = false,
  int devCh = 2,
  int mode = 0,
  bool binaural = false,
}) =>
    localEngineChannels(
      hasRaw: hasRaw,
      rawCh: rawCh,
      passthrough51: passthrough51,
      bypass: bypass,
      devCh: devCh,
      channelsMode: mode,
      binauralActive: binaural,
    );

void main() {
  group('B2b local engine channel policy', () {
    test('no raw / stereo → 2 (fold path)', () {
      expect(_ch(hasRaw: false, rawCh: 2), 2);
      expect(_ch(hasRaw: true, rawCh: 2), 2);
    });

    test('4/6/8 raw on stereo device (matrix) → engine channels', () {
      for (final ch in [4, 6, 8]) {
        expect(_ch(rawCh: ch, devCh: 2, mode: 0), ch,
            reason: 'matrix downmix folds rawCh=$ch to L/R');
      }
    });

    test('multichannel device (devCh>=rawCh) → engine channels', () {
      expect(_ch(rawCh: 6, devCh: 6, mode: 1), 6);
      expect(_ch(rawCh: 8, devCh: 8, mode: 1), 8);
    });

    test('discrete mode on stereo device without binaural → 2 (fold)', () {
      expect(_ch(rawCh: 6, devCh: 2, mode: 1, binaural: false), 2,
          reason: 'discrete keeps channels separate → C/LFE/surround lost');
    });

    test('binaural folds Nch to stereo regardless of mode → engine channels',
        () {
      expect(_ch(rawCh: 6, devCh: 2, mode: 1, binaural: true), 6);
      expect(_ch(rawCh: 8, devCh: 2, mode: 0, binaural: true), 8);
    });

    test('unsupported channel counts (3/5/7) → 2 (fold)', () {
      for (final ch in [3, 5, 7]) {
        expect(_ch(rawCh: ch, devCh: 8, mode: 0), 2,
            reason: 'rawCh=$ch is not a legal channels.count');
      }
    });

    test('passthrough51 / bypass force fold', () {
      expect(_ch(rawCh: 6, devCh: 8, passthrough51: true), 2);
      expect(_ch(rawCh: 6, devCh: 8, bypass: true), 2);
    });
  });
}
