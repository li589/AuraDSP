/// VAIO 桥崩溃断路器（第六轮用户裁定补装，2026-11-11）。
///
/// 语义：VAIO 桥被启动（自动恢复或手动）时在数据目录落一个
/// 标记文件；桥干净停下或 App 正常退出时清除。若进程在桥
/// 运行期间整进程死亡（原生崩溃/被杀/断电），标记会残留——
/// 下次启动构造期消费它：本次跳过 VAIO 桥的自动启动（一
/// 次性，标记读后即删），并通知用户原因，防止「起桥→崩溃
/// →重启又起桥」的死循环把软件锁死成开机必崩。用户在本
/// 次会话里手动选择 VAIO 模式即视为知情接管，断路器解除、
/// 标记重新布防。
///
/// 文件 IO 全部同步且吞错：守卫自身永不许影响启动流程。
library;

import 'dart:io';

import 'error_sink.dart';

class VaioBootGuard {
  static const String markerName = 'vaio_bridge_armed.flag';

  static File _marker(String dataDir) =>
      File('$dataDir${Platform.pathSeparator}$markerName');

  /// 启动时消费标记：存在 = 上一会话带着在跑的 VAIO 桥非
  /// 正常结束。消费即删除（一次性跳过，下个会话恢复常态）。
  static bool consume(String dataDir) {
    try {
      final f = _marker(dataDir);
      if (!f.existsSync()) return false;
      f.deleteSync();
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 布防：桥已启动，本会话若非正常结束，下次启动将跳过。
  static void arm(String dataDir) {
    try {
      _marker(dataDir)
          .writeAsStringSync(DateTime.now().toIso8601String(), flush: true);
    } catch (e, st) {
      swallow(e, st);
    }
  }

  /// 解除：桥干净停下或 App 正常退出。
  static void disarm(String dataDir) {
    try {
      final f = _marker(dataDir);
      if (f.existsSync()) f.deleteSync();
    } catch (e, st) {
      swallow(e, st);
    }
  }
}
