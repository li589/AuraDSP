/*
 * equalizer_apo_parser.dart — EqualizerAPO / Peace TXT 纯 Dart 规范解析器
 *
 * 遵循 Clean-Room 原则自研实现，解析 Equalizer APO / Peace 生成的 .txt 均衡配置文件：
 * - Channel: all / L / R 路由指令
 * - Preamp: -X.X dB 前级增益（支持全局与单通道）
 * - Filter [N]: ON/OFF [PK|LSC|HSC|LP|HP|BP|NO] Fc [Freq] Hz Gain [Gain] dB Q [Q] 滤波器参数
 */

/// 滤波器类型
enum ApoFilterType {
  peaking('PK', 'Peaking EQ'),
  lowShelf('LSC', 'Low Shelf'),
  highShelf('HSC', 'High Shelf'),
  lowPass('LP', 'Low Pass'),
  highPass('HP', 'High Pass'),
  bandPass('BP', 'Band Pass'),
  notch('NO', 'Notch Filter');

  final String code;
  final String displayName;
  const ApoFilterType(this.code, this.displayName);

  static ApoFilterType? fromCode(String code) {
    final upper = code.toUpperCase();
    for (final t in values) {
      if (t.code == upper) return t;
    }
    // 特殊别名容错
    if (upper == 'LS' || upper == 'LOWSHELF') return ApoFilterType.lowShelf;
    if (upper == 'HS' || upper == 'HIGHSHELF') return ApoFilterType.highShelf;
    if (upper == 'PEAK' || upper == 'PEAKING') return ApoFilterType.peaking;
    if (upper == 'NOTCH') return ApoFilterType.notch;
    return null;
  }
}

/// 声道目标
enum ApoTargetChannel {
  all('all', 'L + R (All Channels)'),
  left('L', 'Left Channel'),
  right('R', 'Right Channel');

  final String id;
  final String label;
  const ApoTargetChannel(this.id, this.label);

  static ApoTargetChannel fromString(String raw) {
    final s = raw.trim().toUpperCase();
    if (s == 'L' || s == 'LEFT') return ApoTargetChannel.left;
    if (s == 'R' || s == 'RIGHT') return ApoTargetChannel.right;
    return ApoTargetChannel.all;
  }
}

/// 单个解析出的滤波器定义
class ApoFilter {
  final int index;
  final bool enabled;
  final ApoFilterType type;
  final double freq;
  final double gainDb;
  final double q;
  final ApoTargetChannel channel;
  final String rawText;

  const ApoFilter({
    required this.index,
    required this.enabled,
    required this.type,
    required this.freq,
    required this.gainDb,
    required this.q,
    required this.channel,
    required this.rawText,
  });

  @override
  String toString() =>
      'ApoFilter#$index[$channel, $type, Fc=${freq}Hz, Gain=${gainDb}dB, Q=$q, on=$enabled]';
}

/// 解析异常或警告
class ApoParseIssue {
  final int line;
  final String rawText;
  final String message;

  const ApoParseIssue({
    required this.line,
    required this.rawText,
    required this.message,
  });

  @override
  String toString() => 'Line $line: $message ("$rawText")';
}

/// 完整解析结果
class ApoConfiguration {
  final double globalPreamp;
  final double leftPreamp;
  final double rightPreamp;
  final List<ApoFilter> filters;
  final List<ApoParseIssue> issues;

  const ApoConfiguration({
    this.globalPreamp = 0.0,
    this.leftPreamp = 0.0,
    this.rightPreamp = 0.0,
    this.filters = const [],
    this.issues = const [],
  });

  /// 是否包含解析异常
  bool get hasIssues => issues.isNotEmpty;

  /// 左右声道是否包含独立的非全声道配置
  bool get hasStereoDifference {
    if (leftPreamp != rightPreamp) return true;
    for (final f in filters) {
      if (f.channel != ApoTargetChannel.all) return true;
    }
    return false;
  }

  /// 有效激活的全局/立体声滤波器
  List<ApoFilter> get activeFilters => filters.where((f) => f.enabled).toList();

  List<ApoFilter> get globalFilters =>
      filters.where((f) => f.enabled && f.channel == ApoTargetChannel.all).toList();

  List<ApoFilter> get leftFilters =>
      filters.where((f) => f.enabled && f.channel == ApoTargetChannel.left).toList();

  List<ApoFilter> get rightFilters =>
      filters.where((f) => f.enabled && f.channel == ApoTargetChannel.right).toList();
}

/// EqualizerAPO 纯 Dart 语法解析引擎
class EqualizerApoParser {
  // 正则：Channel: all / Channel: L / Channel: R / Channel: L R
  static final RegExp _channelRegex = RegExp(
    r'^Channel:\s*([a-zA-Z0-9\s]+)',
    caseSensitive: false,
  );

  // 正则：Preamp: -3.5 dB
  static final RegExp _preampRegex = RegExp(
    r'^Preamp:\s*([+-]?\d+(?:\.\d+)?)\s*dB',
    caseSensitive: false,
  );

  // 正则：Filter 1: ON PK Fc 1000 Hz Gain -3.5 dB Q 1.41
  // 容错：Filter: ON ... 或 Filter 1: ON ...
  static final RegExp _filterRegex = RegExp(
    r'^Filter(?:\s+(\d+))?:\s*(ON|OFF)\s+([A-Za-z]+)(?:\s+\d+\s*dB)?\s+Fc\s+([\d.]+)\s*Hz\s+Gain\s+([+-]?[\d.]+)\s*dB\s+Q\s+([\d.]+)',
    caseSensitive: false,
  );

  /// 解析 EqualizerAPO 配置字符串
  static ApoConfiguration parse(String content) {
    var globalPreamp = 0.0;
    var leftPreamp = 0.0;
    var rightPreamp = 0.0;
    final filters = <ApoFilter>[];
    final issues = <ApoParseIssue>[];

    var currentChannel = ApoTargetChannel.all;
    final lines = content.split(RegExp(r'\r?\n'));
    var autoIndex = 1;

    for (var i = 0; i < lines.length; i++) {
      final lineNum = i + 1;
      final rawLine = lines[i];
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }

      // 1. 声道路由行
      final chMatch = _channelRegex.firstMatch(line);
      if (chMatch != null) {
        final chStr = chMatch.group(1)!.trim().toUpperCase();
        if (chStr == 'ALL' || (chStr.contains('L') && chStr.contains('R'))) {
          currentChannel = ApoTargetChannel.all;
        } else if (chStr == 'L' || chStr == 'LEFT') {
          currentChannel = ApoTargetChannel.left;
        } else if (chStr == 'R' || chStr == 'RIGHT') {
          currentChannel = ApoTargetChannel.right;
        } else {
          // 暂不处理非立体声的多声道孤立通道，归入 all 或当前通道
          currentChannel = ApoTargetChannel.all;
        }
        continue;
      }

      // 2. Preamp 行
      final preMatch = _preampRegex.firstMatch(line);
      if (preMatch != null) {
        final val = double.tryParse(preMatch.group(1)!) ?? 0.0;
        switch (currentChannel) {
          case ApoTargetChannel.all:
            globalPreamp = val;
            break;
          case ApoTargetChannel.left:
            leftPreamp = val;
            break;
          case ApoTargetChannel.right:
            rightPreamp = val;
            break;
        }
        continue;
      }

      // 3. Filter 行
      final fMatch = _filterRegex.firstMatch(line);
      if (fMatch != null) {
        final idxStr = fMatch.group(1);
        final index = idxStr != null ? (int.tryParse(idxStr) ?? autoIndex) : autoIndex;
        autoIndex = index + 1;

        final stateStr = fMatch.group(2)!.toUpperCase();
        final enabled = stateStr == 'ON';

        final typeStr = fMatch.group(3)!;
        final type = ApoFilterType.fromCode(typeStr) ?? ApoFilterType.peaking;

        final freq = double.tryParse(fMatch.group(4)!) ?? 1000.0;
        final gainDb = double.tryParse(fMatch.group(5)!) ?? 0.0;
        final q = double.tryParse(fMatch.group(6)!) ?? 0.707;

        if (freq <= 0 || q <= 0) {
          issues.add(ApoParseIssue(
            line: lineNum,
            rawText: line,
            message: 'Frequency and Q must be positive numbers',
          ));
        }

        filters.add(ApoFilter(
          index: index,
          enabled: enabled,
          type: type,
          freq: freq,
          gainDb: gainDb,
          q: q,
          channel: currentChannel,
          rawText: line,
        ));
        continue;
      }

      // 4. 未识别或格式异常的行
      final lower = line.toLowerCase();
      if (lower.startsWith('filter')) {
        issues.add(ApoParseIssue(
          line: lineNum,
          rawText: line,
          message: 'Malformed filter syntax',
        ));
      } else if (lower.startsWith('preamp')) {
        issues.add(ApoParseIssue(
          line: lineNum,
          rawText: line,
          message: 'Malformed preamp syntax',
        ));
      } else if (lower.startsWith('channel')) {
        issues.add(ApoParseIssue(
          line: lineNum,
          rawText: line,
          message: 'Malformed channel syntax',
        ));
      } else {
        issues.add(ApoParseIssue(
          line: lineNum,
          rawText: line,
          message: 'Unrecognized directive',
        ));
      }
    }

    return ApoConfiguration(
      globalPreamp: globalPreamp,
      leftPreamp: leftPreamp,
      rightPreamp: rightPreamp,
      filters: filters,
      issues: issues,
    );
  }
}
