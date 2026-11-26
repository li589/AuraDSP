#!/usr/bin/env python3
"""APO 中转纪律契约（2026-11-23 后续小项轮）：
  1. ApoTransit 提供孤儿回收 collectOrphans；
  2. ApoParamPublisher.flushAll 的字符串全量写与 onString 同
     口径走中转（修复前 flushAll 直写镜像原始路径——切入
     APO/会话恢复时文件效果被宿主围栏拒绝、静默失效）；
  3. 两发布者暴露当前引用集，隔离体在 'apopublish' 后节流
     触发回收。
源码级断言（发布者在 FFI 映射上工作，无轻量运行时夹具）。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def finish(name):
    if failures:
        for f in failures:
            print("  FAIL " + f)
        print(name + ": FAIL")
        return 1
    print(name + ": PASS")
    return 0


LIB = ROOT / "app" / "auradsp_app" / "lib" / "engine"


def read(name):
    return (LIB / name).read_text(encoding="utf-8")


def func_span(src, signature):
    """从函数签名起按大括号配平截取函数体（跳过命名参数括号）。"""
    i = src.index(signature)
    paren = src.index("(", i)
    paren_depth = 0
    j = None
    for k in range(paren, len(src)):
        if src[k] == "(":
            paren_depth += 1
        elif src[k] == ")":
            paren_depth -= 1
            if paren_depth == 0:
                j = src.index("{", k)
                break
    if j is None:
        raise AssertionError("unbalanced parameters: " + signature)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[i:k + 1]
    raise AssertionError("unbalanced: " + signature)


def main():
    transit = read("apo_transit.dart")
    check("collectOrphans" in transit, "ApoTransit.collectOrphans exists")
    check("minAge" in transit, "collectOrphans has the age safety margin")

    apo = read("audio_isolate_apo.dart")
    flush = func_span(apo, "void flushAll()")
    check("_convertFileEffect" in flush,
          "flushAll converts file-effect paths through the transit")
    check("ParamId.convIrPath" in flush and "ParamId.ddcLoad" in flush,
          "flushAll conversion covers IR + DDC")
    onstr = func_span(apo, "void onString(String id, String text)")
    check("_convertFileEffect" in onstr,
          "onString converts through the transit helper")
    conv = func_span(apo, "String? _convertFileEffect(String id, String text)")
    check("transitFileEffect" in conv and "ApoFileTransitResult" in transit,
          "file-effect conversion preserves a structured transit failure")
    check("_updateTransitError" in conv and "'evt': 'apotelemetry'" in apo and
          "'transitFileError': true" in apo,
          "ACL/source/copy conversion failures reach the existing UI telemetry path")
    check("transitFileErrorOf" in apo,
          "telemetry polling retains transit errors instead of clearing them with an empty host error")
    check("if (effective == null)" in conv and
          "_fileEffectConvertCache.remove(id)" in conv,
          "failed file-effect transit is not cached as a successful empty value")
    check("if (effective == null)" in conv and
          "_fileEffectTransit.remove(id)" in conv,
          "failed file-effect transit drops the stale publication reference")

    check("static bool _ensureRoot(String? rootOverride)" in transit,
          "root preparation reports failure to every publication path")
    ensure_root = func_span(transit, "_ensureRoot(String? rootOverride)")
    check("grantDirReadToLocalService" in ensure_root and
          "if (!createWindowsSystemPort()" in ensure_root,
          "ACL grant failure prevents transit-root readiness")
    check(ensure_root.index("_rootReady = true") >
          ensure_root.index("grantDirReadToLocalService"),
          "root readiness is set only after a successful ACL grant")
    sync_transit = func_span(transit, "static ApoFileTransitResult transitFileEffect(")
    async_transit = func_span(transit, "static Future<String?> transitPathForAsync(")
    check("if (!_ensureRoot(rootOverride))" in sync_transit and
          "transit root creation/LocalService ACL grant failed" in sync_transit and
          "if (!_ensureRoot(rootOverride)) return null;" in async_transit,
          "file-effect publication fails closed and reports root preparation failure")

    check("u32[1] >= 8" in apo and "lastFileError" in apo and
          "enginePathHash" in apo and "engineLoadGen" in apo and
          "convReady" in apo and "ddcReady" in apo,
          "telemetry reader exposes the v8 engine/file-effect diagnostics")
    check("fileStatusValid" in apo,
          "telemetry reader explicitly gates v8 file status for old hosts")
    check("referencedTransitPaths" in apo,
          "param publisher exposes its referenced transit set")
    check("currentTransitPaths" in apo,
          "plugin publisher tracks its current transit set")

    iso = read("audio_isolate.dart")
    check("maybeCollectApoOrphans" in iso, "isolate wires the GC trigger")
    check("ApoTransit.collectOrphans" in iso, "isolate calls collectOrphans")
    pub = iso.index("case 'apopublish':")
    check("maybeCollectApoOrphans();" in iso[pub:pub + 800],
          "GC runs after the apopublish full publish")
    return finish("smoke_apo_transit_contract")


if __name__ == "__main__":
    sys.exit(main())
