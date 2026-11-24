// visualizer_per_style_test.dart — 每方案可视化设置（2026-11-23 user 裁定）
//
// 语义：生效配置 = 全局为底 + 当前风格覆盖表只替换调参字段；
// 风格/歌词/MilkDrop 路径恒归全局；覆盖表随 config.json 与会话
// 记忆持久化；抽屉两档（全局/当前预设）分别写入不同存储。
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('每方案可视化设置', () {
    test('无覆盖时生效值即全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerConfig(
        const VisualizerConfig().copyWith(sensitivity: 1.4),
      );
      expect(m.visualizerConfig.value.sensitivity, 1.4);
      expect(m.visualizerHasStyleOverride, isFalse);
    });

    test('覆盖只替换调参字段，歌词与 MilkDrop 路径恒归全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerConfig(
        const VisualizerConfig().copyWith(
          showLyrics: true,
          milkdropPresetPath: 'D:/presets/a.milk',
        ),
      );
      // 抽屉在当前预设档只改调参时，传入的快照除调参外与生效值一致：
      // 全局域字段（歌词/MilkDrop 路径）不因覆盖写入而改变。
      // （全局域被主动改动的同步落全局行为见下一条用例。）
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(sensitivity: 2.2),
      );
      final eff = m.visualizerConfig.value;
      expect(eff.sensitivity, 2.2); // 调参字段被覆盖
      expect(eff.showLyrics, isTrue); // 全局域不被覆盖快照带走
      expect(eff.milkdropPresetPath, 'D:/presets/a.milk');
      expect(m.visualizerHasStyleOverride, isTrue);
      // 全局本身的调参字段未被覆盖写入污染
      expect(m.config.visualizerConfig.sensitivity, 1.0);
    });

    test('覆盖里改全局域字段会同步落全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(
          milkdropPresetPath: 'D:/presets/c.milk',
        ),
      );
      expect(m.config.visualizerConfig.milkdropPresetPath,
          'D:/presets/c.milk');
      expect(m.visualizerConfig.value.milkdropPresetPath,
          'D:/presets/c.milk');
    });

    test('切换风格后各自覆盖互不影响，清除覆盖回全局', () {
      final m = AppModel(testing: true);
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(gravity: 3.0),
      ); // bars 覆盖
      m.setVisualizerConfig(
        m.config.visualizerConfig
            .copyWith(style: VisualizerStyle.oscilloscope),
      );
      expect(m.visualizerConfig.value.gravity, 1.8); // 示波器无覆盖
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(gravity: 0.9),
      );
      m.setVisualizerConfig(
        m.config.visualizerConfig.copyWith(style: VisualizerStyle.bars),
      );
      expect(m.visualizerConfig.value.gravity, 3.0); // bars 覆盖还在
      m.clearVisualizerStyleOverride();
      expect(m.visualizerConfig.value.gravity, 1.8);
      expect(m.visualizerHasStyleOverride, isFalse);
    });

    test('覆盖表随 config JSON 往返不丢（稀疏形态）', () {
      final cfg = AppConfig(
        visualizerPerStyle: {
          'bars': const VisualizerStyleOverride(bloom: 0.9),
          'tornado': const VisualizerStyleOverride(barCount: 64),
        },
      );
      final json = cfg.toJson();
      final back = AppConfig.fromJson(json);
      expect(back.visualizerPerStyle.length, 2);
      expect(back.visualizerPerStyle['bars']!.bloom, 0.9);
      expect(back.visualizerPerStyle['bars']!.sensitivity, isNull);
      expect(back.visualizerPerStyle['tornado']!.barCount, 64);
    });

    test('稀疏覆盖：只改过的字段冻结，其余跟随全局（审查 Dart-F2）', () {
      final m = AppModel(testing: true);
      // 预设档只动灵敏度
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(sensitivity: 2.2),
      );
      // 存储层只记灵敏度一字段
      final entry = m.config.visualizerPerStyle['bars']!;
      expect(entry.sensitivity, 2.2);
      expect(entry.gravity, isNull);
      expect(entry.bloom, isNull);
      // 之后全局改重力：该风格跟随（旧整份快照实现会静默失效）
      m.setVisualizerConfig(
        m.config.visualizerConfig.copyWith(gravity: 2.6),
      );
      expect(m.visualizerConfig.value.gravity, 2.6);
      expect(m.visualizerConfig.value.sensitivity, 2.2); // 覆盖仍在
    });

    test('覆盖值与全局相同则不留条目', () {
      final m = AppModel(testing: true);
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(sensitivity: 2.2),
      );
      expect(m.visualizerHasStyleOverride, isTrue);
      // 预设档把灵敏度改回全局值 → diff 为空、条目消失
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(sensitivity: 1.0),
      );
      expect(m.visualizerHasStyleOverride, isFalse);
    });

    test('全局档整份编辑不烤入覆盖值（applyVisualizerEdit）', () {
      final m = AppModel(testing: true);
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(sensitivity: 2.2),
      ); // bars 覆盖灵敏度 2.2（生效值）
      // 全局档以生效值为基底只改重力
      m.applyVisualizerEdit(
        m.visualizerConfig.value.copyWith(gravity: 2.6),
      );
      // 全局只落重力；灵敏度全局仍 1.0、覆盖仍 2.2
      expect(m.config.visualizerConfig.gravity, 2.6);
      expect(m.config.visualizerConfig.sensitivity, 1.0);
      expect(m.visualizerConfig.value.sensitivity, 2.2);
      expect(m.visualizerConfig.value.gravity, 2.6);
    });

    test('旧档整份快照 JSON 读入后在场字段视为覆盖', () {
      final cfg = AppConfig.fromJson({
        'visualizer': {
          'style': 'bars',
          'perStyle': {
            'bars': {
              'style': 'bars',
              'colorTheme': 'system',
              'sensitivity': 1.0,
              'bloom': 0.9,
              'showLyrics': true,
            },
          },
        },
      });
      final entry = cfg.visualizerPerStyle['bars']!;
      expect(entry.bloom, 0.9);
      expect(entry.sensitivity, 1.0); // 在场即覆盖（生效行为不变）
    });

    test('全局复位只复位调谐参数，风格/歌词/MilkDrop 选择保留（审查 F5）', () {
      final m = AppModel(testing: true);
      m.setVisualizerConfig(
        const VisualizerConfig().copyWith(
          style: VisualizerStyle.tornado,
          sensitivity: 2.2,
          bloom: 0.1,
          barCount: 64,
          showLyrics: true,
          showTranslation: false,
          milkdropPresetPath: 'D:/presets/x.milk',
        ),
      );
      // 当前风格留一份覆盖，复位不得触碰（按档复位）。
      m.setVisualizerStyleOverride(
        m.visualizerConfig.value.copyWith(gravity: 3.3),
      );
      expect(m.visualizerHasStyleOverride, isTrue);

      m.resetVisualizerTuningToDefaults();

      final raw = m.config.visualizerConfig;
      // 调谐回出厂
      expect(raw.sensitivity, 1.0);
      expect(raw.bloom, 0.5);
      expect(raw.barCount, 32);
      // 选择保留
      expect(raw.style, VisualizerStyle.tornado);
      expect(raw.showLyrics, isTrue);
      expect(raw.showTranslation, isFalse);
      expect(raw.milkdropPresetPath, 'D:/presets/x.milk');
      // 覆盖仍在，生效值里覆盖字段仍由覆盖提供
      expect(m.visualizerHasStyleOverride, isTrue);
      expect(m.visualizerConfig.value.gravity, 3.3);
    });

    test('脏覆盖表条目逐条跳过不丢整表', () {
      final cfg = AppConfig.fromJson({
        'visualizer': {
          'style': 'bars',
          'perStyle': {
            'bars': {'bloom': 0.7},
            'broken': 42,
          },
        },
      });
      expect(cfg.visualizerPerStyle.length, 1);
      expect(cfg.visualizerPerStyle['bars']!.bloom, 0.7);
    });
  });
}
