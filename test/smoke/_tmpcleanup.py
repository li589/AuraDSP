#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_tmpcleanup.py — smoke 测试临时目录的健壮清理（B5 E4）。

背景：Windows 上临时目录可能被杀软实时扫描/索引器或尚未收尾的异步写句柄
短暂占用（errno 32 "另一个程序正在使用此文件"）。一次性 rmtree 失败即
泄漏一个 %TEMP% 目录——插件测试曾因此在 %TEMP% 遗留 116 个
auradsp_plugin_test*/aura_gate_* 目录（方案 D 类/E4）。

策略与 Dart 侧 plugin_manager_test.dart 的 tearDown 一致：
有限重试（默认 40 × 50ms = 2s）后放弃；清理失败**打印告警**而不是静默
pass——静默 pass 正是历史泄漏无人发现的原因。
"""

import shutil
import sys
import time


def remove_tree_with_retry(path, tries=40, delay=0.05):
    """删除目录树；有限重试后仍失败返回 False（调用方应告警）。"""
    if not path:
        return True
    for i in range(tries):
        try:
            shutil.rmtree(path, ignore_errors=False)
            return True
        except (OSError, PermissionError):
            # ignore_errors=False 保留异常细节；这里统一按瞬态重试。
            shutil.rmtree(path, ignore_errors=True)
            if not _exists(path):
                return True
            time.sleep(delay)
    # 最后再兜底一次（ignore_errors），并按存在性判定。
    shutil.rmtree(path, ignore_errors=True)
    return not _exists(path)


def _exists(path):
    import os
    return os.path.exists(path)


def warn_if_failed(path, ok, label):
    if not ok:
        print(f"[WARN] 临时目录清理失败（{label}）：{path}",
              file=sys.stderr)
