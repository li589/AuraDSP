/*
 * eel_slider_parser.dart — EEL2 滑块参数解析器（core 层，纯 Dart 零依赖）
 *
 * P1 从 features/eel_editor_support.dart 下沉：core/state.dart 需要它做
 * 脚本声明默认值解析，原先 core→features 的引用方向是倒挂。
 * features 侧通过 export 保持兼容，调用方无需改 import。
 */

/// 自适应滑块参数元数据
class EelSliderMeta {
  final int index; // 1..8
  final String rawName;
  final String displayName;
  final double defaultVal;
  final double minVal;
  final double maxVal;
  final double step;

  const EelSliderMeta({
    required this.index,
    required this.rawName,
    required this.displayName,
    this.defaultVal = 0.0,
    this.minVal = 0.0,
    this.maxVal = 1.0,
    this.step = 0.01,
  });
}

/// 自适应滑块解析器
abstract final class EelSliderParser {
  static final RegExp _declRegex = RegExp(
    r'slider(?<num>[1-8])\s*:\s*(?<def>-?[\d.]+)(\s*<\s*(?<min>-?[\d.]+)\s*,\s*(?<max>-?[\d.]+)(\s*,\s*(?<step>-?[\d.]+))?\s*>)?\s*(?<name>[^\r\n;]*)',
  );

  /// 解析代码文本中声明或引用的滑块参数
  static Map<int, EelSliderMeta> parse(String code) {
    final result = <int, EelSliderMeta>{};

    // 1. 扫描显式声明指令
    for (final m in _declRegex.allMatches(code)) {
      final numStr = m.namedGroup('num');
      if (numStr == null) continue;
      final idx = int.tryParse(numStr);
      if (idx == null) continue;

      final defVal = double.tryParse(m.namedGroup('def') ?? '') ?? 0.0;
      final minVal = double.tryParse(m.namedGroup('min') ?? '') ?? 0.0;
      final maxVal = double.tryParse(m.namedGroup('max') ?? '') ?? 1.0;
      final step = double.tryParse(m.namedGroup('step') ?? '') ?? 0.01;
      var name = (m.namedGroup('name') ?? '').trim();
      if (name.isEmpty) name = 'slider$idx';

      result[idx] = EelSliderMeta(
        index: idx,
        rawName: 'slider$idx',
        displayName: name,
        defaultVal: defVal,
        minVal: minVal,
        maxVal: maxVal,
        step: step,
      );
    }

    // 2. 扫描代码全局引用的 slider1..8
    for (var i = 1; i <= 8; i++) {
      final refPattern = RegExp('\\bslider$i\\b');
      if (refPattern.hasMatch(code)) {
        if (!result.containsKey(i)) {
          result[i] = EelSliderMeta(
            index: i,
            rawName: 'slider$i',
            displayName: '参数 $i (slider$i)',
            defaultVal: 0.0,
            minVal: 0.0,
            maxVal: 1.0,
            step: 0.01,
              );
        }
      }
    }

    return result;
  }
}
