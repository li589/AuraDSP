// apo_transit_gc_test.dart — ApoTransit.collectOrphans 判别：
// 引用集内的条目无论多老都保留；无引用且老于 minAge 的文件与
// bundle 目录被删；无引用但年轻的条目保留（安全垫）；根不存
// 在返回 0。全部在临时目录内完成，不触真实中转根。

import 'dart:io';

import 'package:auradsp_app/engine/apo_transit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApoTransit.collectOrphans', () {
    late Directory tmp;
    // 逻辑时钟 = 真实时间 +31 天：dart:io 无目录 mtime 设置 API，
    // 故 bundle 目录用真实创建时间、靠 nowOverride 把它推入
    // 「老」区间；文件则可直接 setLastModifiedSync 到逻辑时刻。
    final now = DateTime.now().add(const Duration(days: 31));
    final old = now.subtract(const Duration(days: 30));
    final young = now.subtract(const Duration(days: 1));

    File makeFile(String name, DateTime mtime) {
      final f = File('${tmp.path}${Platform.pathSeparator}$name');
      f.writeAsStringSync('x');
      f.setLastModifiedSync(mtime);
      return f;
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('apo_gc_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('keeps referenced, deletes old unreferenced, spares young', () {
      final kept = makeFile('keep.wav', old);
      final stale = makeFile('stale.wav', old);
      final fresh = makeFile('fresh.wav', young);
      final bundle = Directory('${tmp.path}${Platform.pathSeparator}abc.vst3')
        ..createSync();
      File('${bundle.path}${Platform.pathSeparator}mod.vst3')
          .writeAsStringSync('y');

      final removed = ApoTransit.collectOrphans(
        {kept.path},
        rootOverride: tmp.path,
        nowOverride: now,
      );

      expect(removed, 2, reason: 'stale file + stale bundle dir');
      expect(kept.existsSync(), isTrue);
      expect(stale.existsSync(), isFalse);
      expect(
        fresh.existsSync(),
        isTrue,
        reason: 'young unreferenced entries are the safety margin',
      );
      expect(bundle.existsSync(), isFalse);
    });

    test('missing root is a no-op', () {
      expect(
        ApoTransit.collectOrphans(
          const {},
          rootOverride: '${tmp.path}${Platform.pathSeparator}does-not-exist',
          nowOverride: now,
        ),
        0,
      );
    });

    test('referenced matching is slash/case tolerant', () {
      final kept = makeFile('KeepCase.WAV', old);
      final removed = ApoTransit.collectOrphans(
        {kept.path.replaceAll(r'\', '/').toUpperCase()},
        rootOverride: tmp.path,
        nowOverride: now,
      );
      expect(removed, 0);
      expect(kept.existsSync(), isTrue);
    });
  });

  group('ApoTransit.transitPluginPathForAsync', () {
    test(
      'rejects non-empty APO plugin paths instead of publishing them',
      () async {
        // Already-transit-shaped input takes the old fast path without any IO;
        // the new contract must reject it before that path can be published.
        final source =
            '${ApoTransit.root}${Platform.pathSeparator}'
            'task2-controlled-fixture.clap';
        final result = await ApoTransit.transitPluginPathForAsync(source);
        expect(result, isNotNull);
        expect(result.path, isNull);
        expect(result.errorMessage, contains('不支持'));
        expect(result.errorMessage, contains('系统 APO'));
      },
    );

    test('keeps empty path as an explicit unload', () async {
      final result = await ApoTransit.transitPluginPathForAsync('');
      expect(result, isNotNull);
      expect(result.path, '');
      expect(result.errorMessage, isNull);
    });
  });
}
