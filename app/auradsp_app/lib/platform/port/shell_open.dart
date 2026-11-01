// shell_open.dart — 系统文件管理器 / 默认应用打开端口。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
abstract interface class ShellOpenPort {
  /// 用系统文件管理器打开路径（文件或目录）。失败返回 false，不抛异常。
  Future<bool> openPath(String path);
}
