// audio_bridge.dart — 统一桥契约（ab_*）的 Dart 侧调用（P5）。
//
// 2026-10-30 过渡期清理完成：三桥只导出 ab_*，Dart 直接按常量 'ab' 绑定，
// 不再探测 ab_abi_version、也不再回落旧前缀。App 与桥同包发布，无需双向兼容。
// 插件槽面仍按旧前缀绑定（BridgePluginFfi），不在本契约内。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _AbStartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AbStartDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// 统一启动：configJson 承载桥专属宿主参数（ASIO driver/bufSize/outPair/
/// channels；VAIO endpoint；VM 忽略）。ab_start 是三桥唯一启动入口。
int abStart(DynamicLibrary dylib, String engineDll, String params,
    String configJson) {
  final fn = dylib.lookupFunction<_AbStartC, _AbStartDart>('ab_start');
  final ep = engineDll.toNativeUtf8();
  final pp = params.toNativeUtf8();
  final cp = configJson.toNativeUtf8();
  try {
    return fn(ep.cast(), pp.cast(), cp.cast());
  } finally {
    malloc.free(ep);
    malloc.free(pp);
    malloc.free(cp);
  }
}
