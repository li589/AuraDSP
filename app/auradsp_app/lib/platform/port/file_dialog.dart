// file_dialog.dart — 文件/目录选择端口（平台无关契约）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// 规则：业务代码只经 PlatformAdapters.instance.dialog（或 ResourcePicker）调用，
// 不得直接 import `package:file_selector`（门禁 F9）。
abstract interface class FileDialogPort {
  /// 选择一个已存在的文件。扩展名不含点（如 `wav`）；空表 = 不过滤。
  Future<String?> openFile({
    String? title,
    List<String> extensions = const [],
    String? initialDirectory,
  });

  /// 选择多个已存在的文件。
  Future<List<String>> openFiles({
    String? title,
    List<String> extensions = const [],
    String? initialDirectory,
  });

  /// 选择保存位置（返回目标路径，不负责写盘）。
  Future<String?> saveFile({
    String? title,
    List<String> extensions = const [],
    String? initialDirectory,
    String? suggestedName,
  });

  /// 选择一个已存在的目录。
  Future<String?> selectDirectory({
    String? title,
    String? initialDirectory,
    String? confirmLabel,
  });
}
