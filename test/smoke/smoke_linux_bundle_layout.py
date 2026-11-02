# -*- coding: utf-8 -*-
"""smoke_linux_bundle_layout — Linux 发布 bundle 布局门禁（S3 补强）。

S3 的打包规则（app/auradsp_app/linux/CMakeLists.txt）要求
`flutter build linux` 产物 bundle 至少包含：
  - 可执行文件 auradsp_app
  - lib/libauradsp_engine.so（引擎，bundle 内相对加载）
  - lib/libflutter_linux_gtk.so（Flutter 运行时在位，证明是完整 bundle）
  - resources/manifest.json + resources/ddc/ + resources/liveprog/
bundle 目录不存在（未构建 App）时自 SKIP 退出 0（仓库惯例）；
convolver 子集在 assets/ 无源时两边同跳过，不在此断言。
"""
import os
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
BUNDLE = os.path.join(ROOT, "app", "auradsp_app", "build", "linux",
                      "x64", "release", "bundle")

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    if not os.path.isdir(BUNDLE):
        print(f"SKIP: bundle 不存在（{BUNDLE}），先 flutter build linux")
        return 0
    def has(*parts):
        return os.path.exists(os.path.join(BUNDLE, *parts))

    check(has("auradsp_app"), "可执行文件 auradsp_app 在位")
    check(has("lib", "libauradsp_engine.so"), "lib/ 内引擎 .so 在位")
    check(has("lib", "libflutter_linux_gtk.so"), "Flutter 运行时在位")
    check(has("resources", "manifest.json"), "resources/manifest.json 在位")
    check(has("resources", "ddc"), "resources/ddc/ 在位")
    check(has("resources", "liveprog"), "resources/liveprog/ 在位")
    print("smoke_linux_bundle_layout: " + ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
