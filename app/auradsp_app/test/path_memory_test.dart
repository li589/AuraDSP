// PathMemory 统一路径记忆 JSON —— 分槽读写 / 失效目录 / 无变化不写盘
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/path_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PathMemory 分槽路径记忆', () {
    setUp(() {
      PathMemory.resetForTest();
      // flutter test 沙箱：baseDir 已指向临时目录，无需额外注入
    });

    test('recordPick 记录文件所在目录，dirFor 原样读回', () {
      final tmp = Directory.systemTemp.createTempSync('pm_');
      try {
        final f = File('${tmp.path}/a.wav');
        f.writeAsStringSync('x');
        expect(PathMemory.recordPick(PathMemory.slotTestAudio, f.path), isTrue);
        expect(PathMemory.dirFor(PathMemory.slotTestAudio), tmp.path);
        // 跨实例（重新加载内存态）仍读回——真落盘
        PathMemory.resetForTest();
        expect(PathMemory.dirFor(PathMemory.slotTestAudio), tmp.path);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('无记忆 slot 返回 null；已消失的目录视为无记忆', () {
      expect(PathMemory.dirFor(PathMemory.slotConvolverIr), isNull);
      expect(PathMemory.dirFor('__gone__'), isNull);
      // 写入一个不存在的目录后读回应为 null（盘符卸载场景）
      PathMemory.setDir(PathMemory.slotDdcVdc, r'Z:\__nope__\__nope__');
      expect(PathMemory.dirFor(PathMemory.slotDdcVdc), isNull);
    });

    test('同一 slot 重复 setDir 同值不重复写盘（无变化短路）', () {
      final tmp = Directory.systemTemp.createTempSync('pm2_');
      try {
        final file = File(ConfigManager.path(PathMemory.filePathsJson));
        expect(PathMemory.setDir(PathMemory.slotArbmag, tmp.path), isTrue);
        final mtime1 = file.lastModifiedSync();
        // 同值再写：直接返回 true 但不碰盘
        expect(PathMemory.setDir(PathMemory.slotArbmag, tmp.path), isTrue);
        expect(file.lastModifiedSync(), mtime1);
        // 换值才写
        final tmp2 = Directory.systemTemp.createTempSync('pm3_');
        expect(PathMemory.setDir(PathMemory.slotArbmag, tmp2.path), isTrue);
        expect(file.lastModifiedSync(), isNot(mtime1));
        tmp2.deleteSync(recursive: true);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('各 slot 相互隔离（convolver 记录不影响 testAudio）', () {
      final a = Directory.systemTemp.createTempSync('pa_');
      final b = Directory.systemTemp.createTempSync('pb_');
      try {
        PathMemory.setDir(PathMemory.slotConvolverIr, a.path);
        PathMemory.setDir(PathMemory.slotTestAudio, b.path);
        expect(PathMemory.dirFor(PathMemory.slotConvolverIr), a.path);
        expect(PathMemory.dirFor(PathMemory.slotTestAudio), b.path);
      } finally {
        a.deleteSync(recursive: true);
        b.deleteSync(recursive: true);
      }
    });

    test('fallbackDir 在无记忆时可定位到已存在的资源目录', () {
      // 在沙箱内构造一个模拟 resources/convolver
      final sandbox = Directory(ConfigManager.baseDir);
      final simRes = Directory('${sandbox.path}/resources/convolver');
      simRes.createSync(recursive: true);

      expect(PathMemory.fallbackDir(PathMemory.slotConvolverIr), isNotNull);
      expect(PathMemory.fallbackDir(PathMemory.slotConvolverIr), contains('convolver'));
    });
  });
}
