// file_selector_dialog.dart — FileDialogPort 的 file_selector 适配（全平台）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// 这是 `package:file_selector` 在 APP 内的唯一落点（门禁 F9）。
// Android/iOS 由 file_selector 的平台实现走 SAF/UIDocumentPicker；若后续要
// 换成更细的 SAF 适配，只替换本文件。
import 'package:file_selector/file_selector.dart' as fs;

import '../port/file_dialog.dart';

final class FileSelectorDialog implements FileDialogPort {
  const FileSelectorDialog();

  List<fs.XTypeGroup>? _typeGroups(String? label, List<String> extensions) {
    if (extensions.isEmpty) return null;
    return [
      fs.XTypeGroup(label: label ?? 'Files', extensions: extensions),
    ];
  }

  @override
  Future<String?> openFile({
    String? title,
    List<String> extensions = const [],
    String? initialDirectory,
  }) async {
    final file = await fs.openFile(
      acceptedTypeGroups: _typeGroups(title, extensions) ?? const [],
      initialDirectory: initialDirectory,
      confirmButtonText: null,
    );
    return file?.path;
  }

  @override
  Future<List<String>> openFiles({
    String? title,
    List<String> extensions = const [],
    String? initialDirectory,
  }) async {
    final files = await fs.openFiles(
      acceptedTypeGroups: _typeGroups(title, extensions) ?? const [],
      initialDirectory: initialDirectory,
      confirmButtonText: null,
    );
    return [for (final f in files) f.path];
  }

  @override
  Future<String?> saveFile({
    String? title,
    List<String> extensions = const [],
    String? initialDirectory,
    String? suggestedName,
  }) async {
    final location = await fs.getSaveLocation(
      acceptedTypeGroups: _typeGroups(title, extensions) ?? const [],
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
      confirmButtonText: null,
    );
    return location?.path;
  }

  @override
  Future<String?> selectDirectory({
    String? title,
    String? initialDirectory,
    String? confirmLabel,
  }) {
    return fs.getDirectoryPath(
      initialDirectory: initialDirectory,
      confirmButtonText: confirmLabel,
    );
  }
}
