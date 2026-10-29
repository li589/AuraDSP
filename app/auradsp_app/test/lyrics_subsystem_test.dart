import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/features/visualizer/lyrics/models/lyric_models.dart';
import 'package:auradsp_app/features/visualizer/lyrics/parsers/lrc_parser.dart';
import 'package:auradsp_app/features/visualizer/lyrics/services/media_sync_service.dart';
import 'package:auradsp_app/features/visualizer/lyrics/views/lyric_view.dart';

void main() {
  group('LrcParser Tests', () {
    const sampleLrc = '''
[ti:Aura Symphony]
[ar:AuraDSP Ensemble]
[al:Spatial Dimensions]
[offset:100]
[00:02.00]First intro melody begins
[00:05.50]Second verse echoing in stereo
[00:10.00]Chorus rising high above the clouds
''';

    const sampleTranslation = '''
[00:02.00]第一段前奏旋律响起
[00:05.50]第二段主歌在立体声中回荡
[00:10.00]副歌穿透云层高亢升起
''';

    test('Parses metadata tags and standard timestamp lines', () {
      final doc = LrcParser.parse(sampleLrc);

      expect(doc.title, 'Aura Symphony');
      expect(doc.artist, 'AuraDSP Ensemble');
      expect(doc.album, 'Spatial Dimensions');
      expect(doc.offset, const Duration(milliseconds: 100));
      expect(doc.lines.length, 3);

      expect(doc.lines[0].startTime, const Duration(seconds: 2));
      expect(doc.lines[0].text, 'First intro melody begins');
      expect(doc.lines[1].startTime, const Duration(seconds: 5, milliseconds: 500));
      expect(doc.lines[2].startTime, const Duration(seconds: 10));
    });

    test('Merges bilingual translation lines accurately', () {
      final doc = LrcParser.parse(sampleLrc, translationContent: sampleTranslation);

      expect(doc.lines[0].translation, '第一段前奏旋律响起');
      expect(doc.lines[1].translation, '第二段主歌在立体声中回荡');
      expect(doc.lines[2].translation, '副歌穿透云层高亢升起');
    });

    test('Binary search findLineIndex', () {
      final doc = LrcParser.parse(sampleLrc);

      // Before first line
      expect(doc.findLineIndex(const Duration(seconds: 1)), 0);
      // During second line
      expect(doc.findLineIndex(const Duration(seconds: 7)), 1);
      // During chorus
      expect(doc.findLineIndex(const Duration(seconds: 12)), 2);
    });

    test('Parses syllable-level enhanced karaoke tags', () {
      const karaokeLrc = '''
[00:01.00]<00:01.00>Au<00:01.30>ra<00:01.60>DSP<00:02.00>
''';
      final doc = LrcParser.parse(karaokeLrc);
      expect(doc.lines.length, 1);
      final line = doc.lines.first;
      expect(line.isKaraoke, isTrue);
      expect(line.syllables!.length, 3);
      expect(line.syllables![0].text, 'Au');
      expect(line.syllables![1].text, 'ra');
      expect(line.syllables![2].text, 'DSP');
    });
  });

  group('MediaSyncService Tests', () {
    test('Track and playback state updates', () async {
      final service = MediaSyncService();

      const track = MediaTrackMetadata(
        title: 'Cyberpulse',
        artist: 'Neon Wave',
        duration: Duration(minutes: 3, seconds: 30),
        position: Duration(seconds: 15),
        isPlaying: true,
      );

      service.updatePlaybackState(
        position: const Duration(seconds: 15),
        isPlaying: true,
      );
      await service.updateTrack(track);

      final doc = LrcParser.parse('''
[00:10.00]Line 1
[00:20.00]Line 2
''');
      service.loadLyricDocument(doc);

      expect(service.currentLyrics.value.lines.length, 2);
      expect(service.activeLineIndex.value, 0);

      service.dispose();
    });
  });

  group('LyricView Widget Tests', () {
    testWidgets('Renders empty state when document is empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LyricView(
              document: LyricDocument.empty,
              activeIndex: -1,
            ),
          ),
        ),
      );

      expect(find.text('No lyrics loaded'), findsOneWidget);
    });

    testWidgets('Renders lines and highlights active line', (tester) async {
      final doc = LrcParser.parse('''
[00:01.00]Hello world
[00:05.00]Welcome to AuraDSP
''');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricView(
              document: doc,
              activeIndex: 1,
            ),
          ),
        ),
      );

      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Welcome to AuraDSP'), findsOneWidget);
    });
  });
}
