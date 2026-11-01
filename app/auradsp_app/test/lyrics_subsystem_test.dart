import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

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
    bool force = false,
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
    bool force = false,
  }) {
    calls++;
    return completer.future;
  }
}

/// 计数用离线源：验证换源后立即重试
class _CountingOnlineLyricsService extends OnlineLyricsService {
  int calls = 0;
  bool? lastForce;

  @override
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
    bool force = false,
  }) async {
    calls++;
    lastForce = force;
    return null;
  }
}

/// 永不返回的歌词源：验证弱网/挂起时检索预算能收敛 UI 状态
class _HangingOnlineLyricsService extends OnlineLyricsService {
  final Completer<LyricDocument?> never = Completer<LyricDocument?>();
  int calls = 0;

  @override
  Future<LyricDocument?> fetchLyrics({
    required String trackName,
    required String artistName,
    Duration? duration,
    bool force = false,
  }) {
    calls++;
    return never.future;
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
    test('同曲元数据抖动 / 短暂 empty 不重复检索（2026-11-01 回归）', () async {
      final online = _CountingOnlineLyricsService();
      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: online,
        hasSystemMediaSession: true,
      );
      const track = MediaTrackMetadata(
        title: 'Song',
        artist: 'Artist',
        isPlaying: true,
        position: Duration(seconds: 1),
        duration: Duration(minutes: 3),
      );

      await service.updateTrack(track);
      expect(online.calls, 1);

      // 同一首歌：大小写/首尾空白抖动不得触发第二次检索
      await service.updateTrack(track.copyWith(
        title: '  SONG  ',
        artist: ' artist ',
      ));
      expect(online.calls, 1);

      // 播放器短暂返回 empty：宽限期内保留当前曲目与歌词
      await service.updateTrack(MediaTrackMetadata.empty);
      expect(service.currentTrack.value.hasContent, isTrue);
      expect(online.calls, 1);

      // empty 恢复为同一首歌：仍不得重复检索
      await service.updateTrack(track);
      expect(online.calls, 1);

      // 手动重试必须绕过负命中缓存
      await service.retryLyrics();
      expect(online.calls, 2);
      expect(online.lastForce, isTrue);

      service.dispose();
    });

    test('检索挂起时按预算收敛为 notFound，不永久 searching', () async {
      final online = _HangingOnlineLyricsService();
      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: online,
        hasSystemMediaSession: true,
        searchBudget: const Duration(milliseconds: 50),
      );
      const track = MediaTrackMetadata(
        title: 'Slow Network',
        artist: 'Artist',
        isPlaying: true,
      );

      await service.updateTrack(track);
      expect(online.calls, 1);
      expect(service.lyricsState.value, LyricsSyncState.notFound);

      service.dispose();
    });

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

    test('Stale SMTC snapshot never rewinds the active lyric line', () async {
      final doc = LrcParser.parse('''
[00:00.00]A
[00:01.00]B
[00:02.00]C
''');
      final provider = MockMediaSessionProvider();
      final service = MediaSyncService(
        provider: provider,
        onlineService: _FakeOnlineLyricsService(doc),
      );
      service.startAutoSync();

      const track = MediaTrackMetadata(
        title: 'Poller',
        artist: 'Artist',
        position: Duration.zero,
        isPlaying: true,
      );
      provider.emitTrack(track);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(service.activeLineIndex.value, greaterThanOrEqualTo(1));

      // 同曲轮询上报一个明显滞后的位置（快照滞后约 1s），不得让行指针回退
      provider.emitTrack(track.copyWith(
        position: const Duration(milliseconds: 200),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(service.activeLineIndex.value, greaterThanOrEqualTo(1));

      service.dispose();
    });

    test('Calibrating a line survives subsequent same-track polls', () async {
      final doc = LrcParser.parse('''
[00:00.00]Zero
[00:10.00]Ten
[00:20.00]Twenty
''');
      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: _FakeOnlineLyricsService(doc),
      );

      const track = MediaTrackMetadata(
        title: 'Manual',
        artist: 'Artist',
        position: Duration(seconds: 5),
        isPlaying: true,
      );
      await service.updateTrack(track);
      service.loadLyricDocument(doc);
      expect(service.activeLineIndex.value, 0);

      service.calibrateToLine(2);
      expect(service.activeLineIndex.value, 2);

      // 播放器继续每秒上报旧时间轴，校准偏移必须保留，行指针不得被拉回
      await service.updateTrack(
        track.copyWith(position: const Duration(seconds: 5)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(service.activeLineIndex.value, 2);

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

    testWidgets('Hover reveals calibrate action and taps the hovered line',
        (tester) async {
      final doc = LrcParser.parse('''
[00:01.00]Hello world
[00:05.00]Welcome to AuraDSP
''');
      int? calibrated;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: withAuraExtension(ThemeData.dark(), auraDark),
          home: Scaffold(
            body: SizedBox(
              height: 360,
              child: LyricView(
                document: doc,
                activeIndex: 0,
                onLineCalibrate: (i) => calibrated = i,
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('Hello world')));
      await tester.pump(const Duration(milliseconds: 200));

      // 悬停行右侧出现校准按钮；点击后回调携带该行下标
      final icon = find.byIcon(Icons.my_location_rounded).first;
      expect(icon, findsOneWidget);
      await tester.tap(icon);
      await tester.pump();

      expect(calibrated, 0);
    });

    testWidgets('当前行离开可视区后自动归位（R2）', (tester) async {
      final buffer = StringBuffer();
      for (var i = 0; i < 40; i++) {
        buffer.writeln(
            '[00:${(i * 2).toString().padLeft(2, '0')}.00]Line $i');
      }
      final doc = LrcParser.parse(buffer.toString());

      await tester.pumpWidget(
        MaterialApp(
          theme: withAuraExtension(ThemeData.dark(), auraDark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: LyricView(document: doc, activeIndex: 5),
            ),
          ),
        ),
      );
      await tester.pump();

      // 手动向下滚很远：当前行（第 5 行）离开可视区
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pump();

      final scrollable =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.pixels, greaterThan(150),
          reason: '前置条件：手动滚动应已远离起始位置');

      // 松手 900ms 后应自动归位到当前行
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();

      final viewRect = tester.getRect(find.byType(LyricView));
      final lineRect = tester.getRect(find.text('Line 5'));
      expect(lineRect.top, greaterThanOrEqualTo(viewRect.top - 1));
      expect(lineRect.bottom, lessThanOrEqualTo(viewRect.bottom + 1),
          reason: '当前行必须回到可视区内');
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
      // 2026-10-31：居中空态不再放「重新获取 / 本地 LRC」按钮——
      // 两个入口只在歌词层右上角的图标里（避免干扰沉浸视效）。
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Local LRC'), findsNothing);
    });

    testWidgets('Shows clean unsupported notice when platform lacks media session',
        (tester) async {
      tester.view.physicalSize = const Size(900, 560);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MediaSyncService(
        provider: MockMediaSessionProvider(),
        onlineService: _FakeOnlineLyricsService(),
        hasSystemMediaSession: false,
      );
      addTearDown(service.dispose);
      service.startAutoSync();
      addTearDown(service.stopAutoSync);

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

      expect(service.lyricsState.value, LyricsSyncState.unsupported);
      expect(
        find.text('System media session is unavailable on this platform'),
        findsWidgets,
      );
    });
  });

  group('LyricsSource (R6)', () {
    test('默认来源为 auto，且 auto 的回退顺序覆盖四个后端', () {
      const cfg = VisualizerConfig();
      expect(cfg.lyricsSource, LyricsSource.auto);
      expect(LyricsSource.autoOrder, const [
        LyricsSource.lrclib,
        LyricsSource.netease,
        LyricsSource.qq,
        LyricsSource.kugou,
      ]);
    });

    test('VisualizerConfig JSON round-trip 保留歌词来源与全部参数', () {
      const original = VisualizerConfig(
        style: VisualizerStyle.fluidDynamics,
        colorTheme: VisualizerColorTheme.aurora,
        sensitivity: 1.8,
        decayRate: 0.42,
        gravity: 2.6,
        barCount: 64,
        lineWidth: 2.4,
        bloom: 0.72,
        showGrid: false,
        showPeaks: false,
        showDbScale: false,
        showLyrics: true,
        showTranslation: false,
        lyricsSource: LyricsSource.netease,
      );
      final restored = VisualizerConfig.fromJson(original.toJson());
      expect(restored.style, VisualizerStyle.fluidDynamics);
      expect(restored.colorTheme, VisualizerColorTheme.aurora);
      expect(restored.sensitivity, 1.8);
      expect(restored.decayRate, 0.42);
      expect(restored.gravity, 2.6);
      expect(restored.barCount, 64);
      expect(restored.lineWidth, 2.4);
      expect(restored.bloom, 0.72);
      expect(restored.showGrid, isFalse);
      expect(restored.showPeaks, isFalse);
      expect(restored.showDbScale, isFalse);
      expect(restored.showLyrics, isTrue);
      expect(restored.showTranslation, isFalse);
      expect(restored.lyricsSource, LyricsSource.netease);
    });

    test('切换来源会清空缓存并对当前曲目立即重试', () async {
      final provider = MockMediaSessionProvider();
      final online = _CountingOnlineLyricsService();
      final service = MediaSyncService(
        provider: provider,
        onlineService: online,
      );

      await service.updateTrack(const MediaTrackMetadata(
        title: 'Song',
        artist: 'Artist',
        isPlaying: true,
      ));
      expect(online.calls, 1);

      service.setLyricsSource(LyricsSource.qq);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(online.calls, 2, reason: '换源后应立即用新来源重试');

      service.dispose();
    });
  });
}
