/*
 * eel_slider_parser.dart — EEL2 滑块参数解析器（core 层，纯 Dart 零依赖）
 *
 * P1 从 features/eel_editor_support.dart 下沉：core/state.dart 需要它做
 * 脚本声明默认值解析，原先 core→features 的引用方向是倒挂。
 * features 侧通过 export 保持兼容，调用方无需改 import。
 */

/// 自适应滑块参数元数据
class EelSliderMeta {
  final int index; // 1..8 (宿主滑块) 或 9+ (扩展/自定义变量)
  final String rawName; // 如 "slider1", "dBassGain", "freqSplit1"
  final String displayName;
  final double defaultVal;
  final double minVal;
  final double maxVal;
  final double step;
  final List<String> enumOptions;
  final bool isHostSlider; // 是否映射到底层引擎的 slider1..8

  const EelSliderMeta({
    required this.index,
    required this.rawName,
    required this.displayName,
    this.defaultVal = 0.0,
    this.minVal = 0.0,
    this.maxVal = 1.0,
    this.step = 0.01,
    this.enumOptions = const [],
    this.isHostSlider = true,
  });
}

/// 自适应滑块解析器
abstract final class EelSliderParser {
  // 支持:
  // 1) slider1:0<-100,100,.1>Delay amount (ms)
  // 2) //slider1:1<0,6,1>Octaves Down
  // 3) slider15:1<0,3,1{No,Murky,Confused,Unpleasant}>Attitude
  // 4) dBassGain:100<0,100,1>Bass strength (%)
  // 5) freqSplit1:400<1,24000,1>Split 1 at frequency (Hz)
  // 6) slider2: 0.5 简短声明
  static final RegExp _declRegex = RegExp(
    r'^[ \t]*(?://[ \t]*)?(?<var>[a-zA-Z_][a-zA-Z0-9_]*)[ \t]*:[ \t]*(?<def>-?[\d.]+)(?:[ \t]*<[ \t]*(?<min>-?[\d.]+)[ \t]*,[ \t]*(?<max>-?[\d.]+)(?:[ \t]*,[ \t]*(?<step>-?[\d.]+)(?:\{(?<enum>[^}]+)\})?)?[ \t]*>)?(?<name>[^\r\n;]*)',
    multiLine: true,
  );

  /// 解析代码文本中声明或引用的滑块参数
  static Map<int, EelSliderMeta> parse(String code) {
    final result = <int, EelSliderMeta>{};
    var customIndexCounter = 101;

    // 1. 扫描显式声明指令
    for (final m in _declRegex.allMatches(code)) {
      final varName = m.namedGroup('var');
      if (varName == null) continue;

      // 忽略非参数的元数据头部 (如 desc:, author:, tags:)
      final lowerVar = varName.toLowerCase();
      if (lowerVar == 'desc' || lowerVar == 'author' || lowerVar == 'tags' || lowerVar == 'license') {
        continue;
      }

      final hasBrackets = m.namedGroup('min') != null && m.namedGroup('max') != null;
      final isSliderVar = lowerVar.startsWith('slider');

      // 非 slider 开头且无 <min, max> 范围声明的行，忽略（防止误匹配常规赋值/语句）
      if (!isSliderVar && !hasBrackets) {
        continue;
      }

      int idx;
      bool isHost;

      if (isSliderVar) {
        final numPart = int.tryParse(varName.substring(6));
        if (numPart != null) {
          idx = numPart;
          isHost = idx >= 1 && idx <= 8;
        } else {
          idx = customIndexCounter++;
          isHost = false;
        }
      } else {
        idx = customIndexCounter++;
        isHost = false;
      }

      final defVal = double.tryParse(m.namedGroup('def') ?? '') ?? 0.0;
      final minVal = double.tryParse(m.namedGroup('min') ?? '') ?? 0.0;
      final maxVal = double.tryParse(m.namedGroup('max') ?? '') ?? (hasBrackets ? 1.0 : 1.0);
      final step = double.tryParse(m.namedGroup('step') ?? '') ?? 0.01;

      // 解析可能存在的枚举选项 {Opt1,Opt2,...}
      final enumStr = m.namedGroup('enum');
      final enumOptions = enumStr != null && enumStr.isNotEmpty
          ? enumStr.split(',').map((s) => s.trim()).toList()
          : const <String>[];

      var name = (m.namedGroup('name') ?? '').trim();
      if (name.isEmpty) {
        name = varName;
      }

      result[idx] = EelSliderMeta(
        index: idx,
        rawName: varName,
        displayName: name,
        defaultVal: defVal,
        minVal: minVal,
        maxVal: maxVal,
        step: step,
        enumOptions: enumOptions,
        isHostSlider: isHost,
      );
    }

    // 2. 扫描代码全局引用的 slider1..8（若未显式声明则以默认 0..1 兜底）
    for (var i = 1; i <= 8; i++) {
      final refPattern = RegExp('\\bslider$i\\b');
      if (refPattern.hasMatch(code)) {
        if (!result.containsKey(i)) {
          result[i] = EelSliderMeta(
            index: i,
            rawName: 'slider$i',
            displayName: 'slider$i',
            defaultVal: 0.0,
            minVal: 0.0,
            maxVal: 1.0,
            step: 0.01,
            isHostSlider: true,
          );
        }
      }
    }

    return result;
  }
}
