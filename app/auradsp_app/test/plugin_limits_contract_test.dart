// plugin_limits_contract_test.dart — F-09 跨语言插件常量一致性门禁
//
// engine/plugins/plugin_limits.h 是插件槽位/总线通道/VST2 数组上限的唯一定义处，
// 本次审计把散落在 VST2/VST3/CLAP/IPC 协议/宿主管理器/Dart 的 4 与 8 收敛过去。
// 该头文件被 C++ 与 Dart 两侧同时消费，无法靠编译器发现漂移，故在此做静态对账：
//   - Dart PluginManager.kMaxSlots ↔ kMaxSlots；
//   - Dart kVizChannelMax ↔ AURADSP_CH_MAX（kBusChannels 直接引用它，不得另写 8）；
//   - kVst2ArrayChannels 必须大于总线通道上限（64 是厂商数组上限，语义不同）；
//   - IPC 协议层与宿主不得回退到字面量。
// 任何一侧单独修改都会让本测试失败。

import 'dart:io';

import 'package:auradsp_app/core/plugins/plugin_manager.dart' show PluginManager;
import 'package:auradsp_app/engine/auradsp_ffi.dart' show kVizChannelMax;
import 'package:flutter_test/flutter_test.dart';

/// 从包根目录（app/auradsp_app）向上找 engine 源码；兼容从仓库根运行。
String _readEngine(String rel) {
  for (final base in const ['', '../', '../../']) {
    final file = File('$base' 'engine/$rel');
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('找不到 engine/$rel（测试工作目录异常）');
}

/// 读取 `constexpr <type> <name> = <digits>[u];` 形式的整数常量。
int _intConst(String src, String name) {
  final m = RegExp('constexpr\\s+\\w+\\s+$name\\s*=\\s*(\\d+)u?\\s*;')
      .firstMatch(src);
  expect(m, isNotNull, reason: '$name 未在 source 中定义');
  return int.parse(m!.group(1)!);
}

void main() {
  test('插件槽位/通道常量跨语言一致（F-09）', () {
    final limits = _readEngine('plugins/plugin_limits.h');

    // 1) 槽位数：Dart PluginManager.kMaxSlots ↔ C++ kMaxSlots。
    expect(_intConst(limits, 'kMaxSlots'), PluginManager.kMaxSlots,
        reason: 'Dart kMaxSlots 与 plugin_limits.h 不一致');

    // 2) 总线通道：C++ 直接引用 ABI 常量；Dart viz 容量等于同一值。
    expect(
      limits,
      contains('constexpr uint32_t kBusChannels = AURADSP_CH_MAX;'),
      reason: 'kBusChannels 必须直接引用 AURADSP_CH_MAX，不得另写字面量',
    );
    final engineHeader = _readEngine('auradsp_engine.h');
    final chMax =
        RegExp('#define\\s+AURADSP_CH_MAX\\s+(\\d+)').firstMatch(engineHeader);
    expect(chMax, isNotNull, reason: 'auradsp_engine.h 缺少 AURADSP_CH_MAX');
    expect(int.parse(chMax!.group(1)!), kVizChannelMax,
        reason: 'Dart kVizChannelMax 与 AURADSP_CH_MAX 不一致');

    // 3) VST2 临时指针数组上限与总线通道上限语义分离，不得退化为 8。
    expect(_intConst(limits, 'kVst2ArrayChannels'), greaterThan(kVizChannelMax),
        reason: 'VST2 数组上限不得退化为总线通道上限（会截断多通道插件）');

    // 4) IPC 协议层与宿主管理器的镜像必须引用唯一定义处。
    final protocol =
        _readEngine('plugins/platform/win32/host/plugin_ipc_protocol.h');
    expect(protocol, contains('kMaxSlots = auradsp::limits::kMaxSlots'),
        reason: 'IPC 协议层不得重新硬编码槽位数');
    expect(protocol, contains('kChannels = auradsp::limits::kBusChannels'),
        reason: 'IPC 协议层不得重新硬编码总线通道上限');
    final host = _readEngine('plugins/api/plugin_host.h');
    expect(host, contains('kMaxPluginSlots = auradsp::limits::kMaxSlots'),
        reason: 'PluginHostManager 不得重新硬编码槽位数');
  });
}
