// native_library_loader.dart — 原生库加载的单一实现（S5c 抽取）。
//
// 此前四处各复制了一份「按候选名依次尝试 DynamicLibrary.open、
// 全失败抛 StateError」的逻辑（audio_out_linux / audio_in_linux 的
// openFirst、pulse_context 的内联循环、auradsp_ffi 的引擎候选循环），
// 候选顺序或错误处理漂移时无人察觉。统一到这里：行为与旧实现等价
// （依次尝试、记住最后一个错误、全失败抛 StateError 并在消息里带上
// [what] 与完整候选清单；引擎侧的 loadedPath 簿记经 onOpened 回调）。
import 'dart:ffi';

abstract final class NativeLibraryLoader {
  /// 依次尝试 [names]，返回第一个成功打开的库；[onOpened] 在成功时
  /// 以命中的候选名回调（供引擎加载器记录 loadedPath 这类簿记）。
  static DynamicLibrary openFirst(
    List<String> names, {
    required String what,
    void Function(String name)? onOpened,
  }) {
    Object? last;
    for (final n in names) {
      try {
        final lib = DynamicLibrary.open(n);
        onOpened?.call(n);
        return lib;
      } catch (e) {
        last = e;
      }
    }
    throw StateError('$what not found (${names.join(', ')}): $last');
  }
}
