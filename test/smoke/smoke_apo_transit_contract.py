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
    """从函数签名起按大括号配平截取函数体。"""
    i = src.index(signature)
    j = src.index("{", i)
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
    conv = func_span(apo, "String _convertFileEffect(String id, String text)")
    check("transitPathFor" in conv, "conversion helper calls transitPathFor")
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
