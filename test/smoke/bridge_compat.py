# -*- coding: utf-8 -*-
"""bridge_compat.py — 过渡期清理后的测试侧兼容层（仅 test/smoke 使用）。

2026-10-30 起三桥只导出 ab_*（方案 §8.4）；Python 冒烟脚本仍按旧前缀书写，
保留其历史可读性。本模块把公共面别名到 ab_*，并把旧 start 签名翻译成
ab_start(engine, params, config_json)。**产品代码不要引用本文件。**
"""
import json

COMMON = ("detect", "stop", "status", "set_param", "set_param_str",
          "get_param", "get_param_str", "viz_read", "test_start",
          "test_stop", "bypass")


def _text(v):
    if v is None:
        return ""
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode("utf-8", "replace")
    return str(v)


def alias_common(mod, prefix):
    """mod.<prefix>_<suffix> = mod.ab_<suffix>（同一 ctypes 函数对象）。"""
    for suffix in COMMON:
        setattr(mod, prefix + "_" + suffix, getattr(mod, "ab_" + suffix))


def start_vm(mod):
    """旧 vb_start(engine, params) → ab_start(engine, params, "{}")。"""
    return lambda engine_dll, params_json: mod.ab_start(
        engine_dll, params_json, b"{}")


def start_asio(mod):
    """旧 asio_start / asio_start_ex → ab_start + config_json。

    旧 5 参入口等价 channels=2；6 参入口显式给 channels。
    """

    def start(driver, engine_dll, params_json, buf_size=0, out_pair=0,
              channels=None):
        ch = 2 if channels is None else channels
        cfg = json.dumps({
            "driver": _text(driver),
            "bufSize": int(buf_size),
            "outPair": int(out_pair),
            "channels": int(ch),
        })
        return mod.ab_start(engine_dll, params_json, cfg.encode("utf-8"))

    return start


def start_vaio(mod):
    """旧 vaio_start(engine, params, endpoint_substr) → ab_start + config_json。"""

    def start(engine_dll, params_json, endpoint_substr=b""):
        cfg = json.dumps({"endpoint": _text(endpoint_substr)})
        return mod.ab_start(engine_dll, params_json, cfg.encode("utf-8"))

    return start
