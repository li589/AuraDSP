import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/features/visualizer/lyrics/models/lyric_models.dart';
import 'package:auradsp_app/features/visualizer/lyrics/parsers/lrc_parser.dart';
import 'package:auradsp_app/features/visualizer/lyrics/services/media_sync_service.dart';
import 'package:auradsp_app/features/visualizer/lyrics/services/online_lyrics_service.dart';
import 'package:auradsp_app/features/visualizer/lyrics/views/lyric_view.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_stage.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';

/// 离线歌词源：单元测试不得触网，检索结果完全由用例注入
class _FakeOnlineLyricsService extends OnlineLyricsService {
  final LyricDocument? document;

  _FakeOnlineLyricsService([this.document]);

  @override
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
  }) async =>
      document;
}

/// 可手动控制完成时机的歌词源：用于验证慢速检索不会被同曲轮询作废
class _DeferredOnlineLyricsService extends OnlineLyricsService {
  final Completer<LyricDocument?> completer = Completer<LyricDocument?>();
  int calls = 0;

  @override
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
  }) {
    calls++;
    return completer.future;
  }
}

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
      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: _FakeOnlineLyricsService(),
      );

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

    test('AutoSync with MockMediaSessionProvider emits track and updates lyrics', () async {
      final doc = LrcParser.parse('''
[00:00.00]First line
[00:03.00]Second line
''');
      final mockProvider = MockMediaSessionProvider();
      final service = MediaSyncService(
        provider: mockProvider,
        onlineService: _FakeOnlineLyricsService(doc),
      );
      service.startAutoSync();

      mockProvider.emitTrack(const MediaTrackMetadata(
        title: 'Song',
        artist: 'Artist',
        position: Duration(seconds: 4),
        isPlaying: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.currentTrack.value.title, 'Song');
      expect(service.currentLyrics.value.lines.length, 2);
      expect(service.activeLineIndex.value, 1);

      service.dispose();
    });

    test('SMTC zero-timeline protection preserves clock progression for NetEase CloudMusic', () async {
      final doc = LrcParser.parse('''
[00:00.00]Intro
[00:01.00]Verse 1
[00:02.00]Verse 2
''');
      final mockProvider = MockMediaSessionProvider();
      final service = MediaSyncService(
        provider: mockProvider,
        onlineService: _FakeOnlineLyricsService(doc),
      );
      service.startAutoSync();

      // 1. Initial track arrival with position 0
      mockProvider.emitTrack(const MediaTrackMetadata(
        title: 'NetEase Song',
        artist: 'Artist',
        position: Duration.zero,
        isPlaying: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.activeLineIndex.value, 0);

      // 2. Simulate subsequent NetEase SMTC poll still reporting position 0 while song is playing.
      // Clock must continue to advance, not get reset to zero!
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      mockProvider.emitTrack(const MediaTrackMetadata(
        title: 'NetEase Song',
        artist: 'Artist',
        position: Duration.zero,
        isPlaying: true,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      // After ~1.1s elapsed, it should have advanced to Verse 1 (>= 1.0s)
      expect(service.activeLineIndex.value, greaterThanOrEqualTo(1));

      service.dispose();
    });

    test('Same-track polling does not discard slow online lyric results', () async {
      final provider = MockMediaSessionProvider();
      final online = _DeferredOnlineLyricsService();
      final service = MediaSyncService(
        provider: provider,
        onlineService: online,
      );

      const track = MediaTrackMetadata(
        title: 'Slow Song',
        artist: 'Artist',
        position: Duration(seconds: 5),
        isPlaying: true,
      );

      final first = service.updateTrack(track);
      // 模拟 SMTC 每秒轮询再次上报同一曲目（真实场景下会导致慢速检索被作废）
      final second = service.updateTrack(
        track.copyWith(position: const Duration(seconds: 6)),
      );
      expect(service.lyricsState.value, LyricsSyncState.searching);
      expect(online.calls, 1);

      online.completer.complete(LrcParser.parse('''
[00:00.00]First line
[00:05.00]Second line
'''));
      await first;
      await second;

      expect(service.currentLyrics.value.lines.length, 2);
      expect(service.lyricsState.value, LyricsSyncState.ready);
      expect(service.activeLineIndex.value, greaterThanOrEqualTo(0));

      service.dispose();
    });

    test('Exposes no-media and not-found states for visible UI feedback', () async {
      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: _FakeOnlineLyricsService(),
      );

      expect(service.lyricsState.value, LyricsSyncState.idle);

      await service.updateTrack(MediaTrackMetadata.empty);
      expect(service.lyricsState.value, LyricsSyncState.noMedia);

      await service.updateTrack(const MediaTrackMetadata(
        title: 'Unknown Track',
        artist: 'Nobody',
        isPlaying: true,
      ));
      expect(service.lyricsState.value, LyricsSyncState.notFound);
      expect(service.currentLyrics.value.isEmpty, isTrue);

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

  group('VisualizerStage Lyrics Overlay', () {
    testWidgets('Shows visible status and actions when enabled without media',
        (tester) async {
      tester.view.physicalSize = const Size(900, 560);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: _FakeOnlineLyricsService(),
      );
      addTearDown(service.dispose);

      final spectrum =
          ValueNotifier<List<double>>(List<double>.filled(32, 0.0));
      final level = ValueNotifier<double>(-60.0);
      addTearDown(spectrum.dispose);
      addTearDown(level.dispose);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: withAuraExtension(ThemeData.dark(), auraDark),
          home: Scaffold(
            body: VisualizerStage(
              playing: false,
              spectrum: spectrum,
              levelL: level,
              levelR: level,
              config: const VisualizerConfig(showLyrics: true),
              onStyleChanged: (_) {},
              onToggleStageMode: () {},
              onDisplayModeChanged: (_) {},
              onToggleLyrics: () {},
              onOpenDrawer: () {},
              onOpenLocalLrc: () {},
              mediaSync: service,
              emptyText: 'No audio',
              active: false,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 头部与空态卡片都应给出可见文案，而不是整层被隐藏
      expect(find.text('No active media session'), findsWidgets);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Local LRC'), findsOneWidget);
    });
  });
}
