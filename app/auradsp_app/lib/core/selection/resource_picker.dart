// resource_picker.dart — 「选择/打开」的统一治理（对话框端口 + 校验 + 记忆）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §5.4。
// 本文件只依赖 platform/port 契约，不 import 具体平台实现；组合根
// （platform/adapters.dart）把 FileDialogPort 注入进来。
import '../../platform/port/file_dialog.dart';
import '../error_sink.dart';
import '../io/resource_gate.dart';
import '../path_memory.dart';

enum ResourcePickMode { file, directory }

/// 一次选择请求。文案由 UI 传入（core 不做 l10n）。
class ResourcePickRequest {
  final String title;
  final String? prompt;
  final String? initialPath;
  final ResourcePickMode mode;
  final List<String>? allowedExtensions;
  final String? memorySlot;
  final String? confirmLabel;

  const ResourcePickRequest({
    required this.title,
    this.prompt,
    this.initialPath,
    this.mode = ResourcePickMode.file,
    this.allowedExtensions,
    this.memorySlot,
    this.confirmLabel,
  });
}

final class ResourcePicker {
  const ResourcePicker({required this.dialog});

  final FileDialogPort dialog;

  /// 该 slot 的上次目录 / 资源库兜底目录；无记忆返回 null。
  String? initialDirectory(String? slot) {
    if (slot == null || slot.isEmpty) return null;
    return PathMemory.dirFor(slot) ?? PathMemory.fallbackDir(slot);
  }

  /// 调原生选择器；成功后写 PathMemory。失败/取消返回 null，不抛。
  Future<String?> browse(ResourcePickRequest request) async {
    try {
      final initialDir = request.initialPath?.isNotEmpty == true
          ? request.initialPath
          : initialDirectory(request.memorySlot);

      String? picked;
      if (request.mode == ResourcePickMode.directory) {
        picked = await dialog.selectDirectory(
          title: request.title,
          initialDirectory: initialDir,
          confirmLabel: request.confirmLabel,
        );
      } else {
        picked = await dialog.openFile(
          title: request.title,
          extensions: request.allowedExtensions ?? const [],
          initialDirectory: initialDir,
        );
      }

      if (picked != null && picked.isNotEmpty && request.memorySlot != null) {
        remember(request.memorySlot!, picked, mode: request.mode);
      }
      return picked;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /// 记录一次成功选择（原生选择器或手动输入统一走这里）。
  void remember(
    String slot,
    String path, {
    required ResourcePickMode mode,
  }) {
    if (slot.isEmpty || path.isEmpty) return;
    if (mode == ResourcePickMode.directory) {
      PathMemory.setDir(slot, path);
    } else {
      PathMemory.recordPick(slot, path);
    }
  }

  /// 校验手动输入/粘贴的路径。返回 `ok` 或具体问题；空路径按 `missing`。
  static ResourceIssue validate(
    String path, {
    required ResourcePickMode mode,
    List<String>? allowedExtensions,
  }) {
    if (path.trim().isEmpty) return ResourceIssue.missing;
    final issue = ResourceGate.checkPath(
      path,
      directory: mode == ResourcePickMode.directory,
    );
    if (issue != ResourceIssue.ok) return issue;
    if (mode == ResourcePickMode.file && allowedExtensions != null) {
      return ResourceGate.checkExtension(path, allowedExtensions);
    }
    return ResourceIssue.ok;
  }
}
