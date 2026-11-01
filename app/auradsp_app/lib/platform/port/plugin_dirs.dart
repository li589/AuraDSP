// plugin_dirs.dart — 插件扫描目录发现端口。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §6。
// 契约：只返回**当前设备真实存在**的目录（实现内部做存在性过滤/去重）。
abstract interface class PluginDirsPort {
  /// [env] 仅用于测试注入环境变量；生产传 null = Platform.environment。
  List<String> discover({Map<String, String>? env});
}
