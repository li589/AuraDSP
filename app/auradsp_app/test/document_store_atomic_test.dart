import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/io/document_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// APP-01 回归（全项目深度审查 S7）：持久化原子写 + 坏档隔离。
/// - DocumentStore.writeJson 落盘后目标文件内容完整，且不残留 .tmp；
/// - 原子写对既有文件的覆盖是整档替换（旧内容不与新内容交错）；
/// - AppConfig.load 遇损坏 config.json 时先隔离为 .corrupt-* 再生成
///   默认，坏档内容必须原样保留在隔离文件里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DocumentStore 原子写', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('auradsp_ds_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writeJson 内容完整且无 .tmp 残留', () {
      final path = '${dir.path}/a.json';
      expect(DocumentStore.writeJson(path, {'k': 'v1'}), isTrue);
      expect(File(path).readAsStringSync(), contains('"v1"'));
      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('二次写入整档替换', () {
      final path = '${dir.path}/b.json';
      expect(DocumentStore.writeJson(path, {'long': 'x' * 500}), isTrue);
      expect(DocumentStore.writeJson(path, {'s': 1}), isTrue);
      final text = File(path).readAsStringSync();
      expect(text, isNot(contains('xxx')));
      expect(DocumentStore.readJson(path).ok, isTrue);
    });
  });

  group('AppConfig 坏档隔离', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('auradsp_cfg_');
      ConfigManager.baseDirOverride = dir.path;
    });
    tearDown(() {
      ConfigManager.baseDirOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('损坏的 config.json 被隔离而非覆盖', () {
      final path = ConfigManager.configPath;
      File(path).writeAsStringSync('{"version": 3, "vizFps": ');
      final cfg = ConfigManager.load();
      // 默认配置已生成且可解析
      expect(cfg, isNotNull);
      expect(DocumentStore.readJson(path).ok, isTrue);
      // 坏档被隔离保留，内容原样
      final quarantined = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(quarantined.single.readAsStringSync(),
          '{"version": 3, "vizFps": ');
    });

    test('首次运行（文件缺失）不产生隔离文件', () {
      ConfigManager.load();
      final quarantined = dir
          .listSync()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(quarantined, isEmpty);
      expect(File(ConfigManager.configPath).existsSync(), isTrue);
    });
  });
}
