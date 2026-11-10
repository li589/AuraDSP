// VAIO 崩溃断路器标记文件语义（第六轮用户裁定补装）：
// 布防→消费判读为「未净退出」且一次性；解除后不再触发。
import 'dart:io';

import 'package:auradsp_app/core/vaio_boot_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VaioBootGuard', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('vaio_guard_test');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('无标记时消费为 false', () {
      expect(VaioBootGuard.consume(dir.path), isFalse);
    });

    test('布防后消费为 true 且标记被删（一次性）', () {
      VaioBootGuard.arm(dir.path);
      final marker =
          File('${dir.path}${Platform.pathSeparator}${VaioBootGuard.markerName}');
      expect(marker.existsSync(), isTrue);
      expect(VaioBootGuard.consume(dir.path), isTrue);
      expect(marker.existsSync(), isFalse);
      // 已消费：下个会话恢复常态，不再跳过。
      expect(VaioBootGuard.consume(dir.path), isFalse);
    });

    test('解除后消费为 false（干净退出路径）', () {
      VaioBootGuard.arm(dir.path);
      VaioBootGuard.disarm(dir.path);
      expect(VaioBootGuard.consume(dir.path), isFalse);
    });

    test('目录不存在时全员吞错不抛', () {
      final missing = '${dir.path}${Platform.pathSeparator}nope';
      expect(VaioBootGuard.consume(missing), isFalse);
      VaioBootGuard.disarm(missing); // 不抛即过
    });
  });
}
