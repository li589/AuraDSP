import '../models/lyric_models.dart';

/// Robust parser for standard and enhanced syllable-level LRC lyrics
abstract final class LrcParser {
  static final RegExp _tagRegex = RegExp(r'^\[([a-zA-Z]+):([^\]]*)\]');
  static final RegExp _timeRegex = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _syllableRegex = RegExp(r'<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>([^<]*)');

  /// Parse LRC content string and optional translation content
  static LyricDocument parse(
    String lrcContent, {
    String? translationContent,
  }) {
    if (lrcContent.trim().isEmpty) {
      return LyricDocument.empty;
    }

    String? title;
    String? artist;
    String? album;
    Duration offset = Duration.zero;

    final rawLines = <_RawLine>[];

    for (final rawLine in lrcContent.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // Parse metadata header tags
      final tagMatch = _tagRegex.firstMatch(line);
      if (tagMatch != null) {
        final key = tagMatch.group(1)?.toLowerCase();
        final val = tagMatch.group(2)?.trim() ?? '';
        switch (key) {
          case 'ti':
            title = val;
            break;
          case 'ar':
            artist = val;
            break;
          case 'al':
            album = val;
            break;
          case 'offset':
            final ms = int.tryParse(val) ?? 0;
            offset = Duration(milliseconds: ms);
            break;
        }
        continue;
      }

      // Parse timestamp tags
      final timeMatches = _timeRegex.allMatches(line).toList();
      if (timeMatches.isEmpty) continue;

      // Extract the text after all initial timestamps
      final lastMatch = timeMatches.last;
      final textPart = line.substring(lastMatch.end).trim();

      // Check for enhanced karaoke syllable tags: <mm:ss.xx>word
      final syllables = _parseSyllables(textPart);
      final plainText = syllables.isNotEmpty
          ? syllables.map((s) => s.text).join()
          : textPart;

      for (final tm in timeMatches) {
        final duration = _parseTimestamp(
          tm.group(1)!,
          tm.group(2)!,
          tm.group(3),
        );
        rawLines.add(_RawLine(
          startTime: duration,
          text: plainText,
          syllables: syllables.isNotEmpty ? syllables : null,
        ));
      }
    }

    // Sort by start timestamp
    rawLines.sort((a, b) => a.startTime.compareTo(b.startTime));

    // Calculate line end times
    final parsedLines = <LyricLine>[];
    for (var i = 0; i < rawLines.length; i++) {
      final cur = rawLines[i];
      Duration endTime;
      if (i + 1 < rawLines.length) {
        final nextStart = rawLines[i + 1].startTime;
        final maxDuration = const Duration(seconds: 8);
        endTime = (nextStart - cur.startTime > maxDuration)
            ? cur.startTime + maxDuration
            : nextStart;
      } else {
        endTime = cur.startTime + const Duration(seconds: 4);
      }

      parsedLines.add(LyricLine(
        startTime: cur.startTime,
        endTime: endTime,
        text: cur.text,
        syllables: cur.syllables,
      ));
    }

    // Merge translation if provided
    if (translationContent != null && translationContent.trim().isNotEmpty) {
      _mergeTranslation(parsedLines, translationContent);
    }

    return LyricDocument(
      lines: parsedLines,
      title: title,
      artist: artist,
      album: album,
      offset: offset,
    );
  }

  static List<LyricSyllable> _parseSyllables(String text) {
    final matches = _syllableRegex.allMatches(text).toList();
    if (matches.isEmpty) return const [];

    final result = <LyricSyllable>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final start = _parseTimestamp(m.group(1)!, m.group(2)!, m.group(3));
      final word = m.group(4) ?? '';
      if (word.isEmpty) continue;

      Duration end;
      if (i + 1 < matches.length) {
        final nextM = matches[i + 1];
        end = _parseTimestamp(nextM.group(1)!, nextM.group(2)!, nextM.group(3));
      } else {
        end = start + const Duration(milliseconds: 400);
      }

      result.add(LyricSyllable(
        startTime: start,
        endTime: end,
        text: word,
      ));
    }
    return result;
  }

  static Duration _parseTimestamp(String minStr, String secStr, String? fracStr) {
    final minutes = int.tryParse(minStr) ?? 0;
    final seconds = int.tryParse(secStr) ?? 0;
    var millis = 0;
    if (fracStr != null && fracStr.isNotEmpty) {
      if (fracStr.length == 1) {
        millis = (int.tryParse(fracStr) ?? 0) * 100;
      } else if (fracStr.length == 2) {
        millis = (int.tryParse(fracStr) ?? 0) * 10;
      } else {
        millis = int.tryParse(fracStr.substring(0, 3)) ?? 0;
      }
    }
    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }

  static void _mergeTranslation(List<LyricLine> lines, String transLrc) {
    final transDoc = parse(transLrc);
    if (transDoc.isEmpty) return;

    for (var i = 0; i < lines.length; i++) {
      final orig = lines[i];
      final bestIdx = transDoc.findLineIndex(orig.startTime);
      if (bestIdx >= 0 && bestIdx < transDoc.lines.length) {
        final tLine = transDoc.lines[bestIdx];
        final diff = (tLine.startTime - orig.startTime).inMilliseconds.abs();
        if (diff <= 350) {
          lines[i] = orig.copyWith(translation: tLine.text);
        }
      }
    }
  }
}

class _RawLine {
  final Duration startTime;
  final String text;
  final List<LyricSyllable>? syllables;

  const _RawLine({
    required this.startTime,
    required this.text,
    this.syllables,
  });
}
