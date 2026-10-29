// audio_bridge.dart — 统一桥契约（ab_*）的 Dart 侧解析与启动（P5）。
//
// 方案 §4.1/§4.2：三桥（VM/ASIO/VAIO）的公共导出面收敛为同一组 ab_* 符号，
// 过渡期旧前缀（vb_*/asio_*/vaio_*）保留一个版本。本文件只做两件事：
//   1. 探测桥是否导出 ab_abi_version → 公共面用 'ab' 还是旧前缀；
//   2. 提供统一形状的 ab_start 调用（各桥专属宿主参数走 configJson）。
// 插件槽面仍按旧前缀绑定（BridgePluginFfi），不在本契约内。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _AbiVersionC = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _AbStartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AbStartDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// 桥是否导出统一契约（ab_abi_version > 0）。缺失/0 = 老桥，调用方回落旧前缀。
bool supportsUnifiedContract(DynamicLibrary dylib) {
  try {
    final fn =
        dylib.lookupFunction<_AbiVersionC, _AbiVersionDart>('ab_abi_version');
    return fn() > 0;
  } on ArgumentError {
    return false; // 老桥：无统一契约导出
  }
}

/// 公共导出面该用哪个前缀：新桥 'ab'，老桥 [legacyPrefix]。
String resolveBridgePrefix(DynamicLibrary dylib, String legacyPrefix) =>
    supportsUnifiedContract(dylib) ? 'ab' : legacyPrefix;

/// 统一启动：configJson 承载桥专属宿主参数（ASIO driver/bufSize/outPair/
/// channels；VAIO endpoint；VM 忽略）。桥无 ab_start 时返回 null，
/// 调用方回落各自旧前缀 start（过渡期双路径，见方案 §4.1）。
int? unifiedStart(DynamicLibrary dylib, String engineDll, String params,
    String configJson) {
  _AbStartDart fn;
  try {
    fn = dylib.lookupFunction<_AbStartC, _AbStartDart>('ab_start');
  } on ArgumentError {
    return null;
  }
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
