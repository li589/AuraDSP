# -*- coding: utf-8 -*-
"""smoke_vaio_channel_mode.py — AuraVAIO 桥声道模式协商契约冒烟。

验证 vaio_set_param / vaio_get_param 对 channels.countMode / channels.count 的契约：
1. 未启动引擎时的影子状态：默认 auto(0)、有效档位为合法值；
2. countMode=1（手动）后，channels.count 取 2/4/6/8 立即改变有效档位并回读一致；
3. 手动模式下非法档位（如 5）返回 -1，且不改变当前有效档位；
4. countMode=0（auto）后有效档位回到驱动环声道数；auto 下写 channels.count
   只更新手动影子，不得改变当前有效档位；
5. float / 整型两条取值路径结果一致。

说明：本脚本只断言真实 DLL 的对外契约。交织重映射（RemapInterleavedAudio）是
桥内部的 RT 实现，无法从 C ABI 观测，不在 Python 侧仿写自证；其正确性由
真实驱动回环（smoke_vaio_bridge.py）与人工试听保证。
"""
import ctypes
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CANDS = [
    os.environ.get("AURADSP_VAIO_BRIDGE_DLL", ""),
    # 优先取最新构建产物；test/ 下的副本可能早于本次构建
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release",
                 "auravaio_bridge.dll"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Debug",
                 "auravaio_bridge.dll"),
    os.path.join(ROOT, "test", "auravaio_bridge.dll"),
]
CANDS = [p for p in CANDS if p]

path = next((p for p in CANDS if os.path.exists(p)), None)
if not path:
    print("SKIP（auravaio_bridge.dll 不存在，未构建 windows-drivers）")
    sys.exit(0)

print(f"[SMOKE_VAIO_CHANNEL_MODE] Using bridge: {path}")

b = ctypes.CDLL(path)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridge_compat import alias_common  # noqa: E402

alias_common(b, "vaio")

b.vaio_set_param.restype = ctypes.c_int
b.vaio_set_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.vaio_get_param.restype = ctypes.c_int
b.vaio_get_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]

VALID = (2, 4, 6, 8)
fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def get_int(pid):
    v = ctypes.c_int32(-1)
    rc = b.vaio_get_param(pid, 0, ctypes.byref(v))
    return rc, v.value


def get_float(pid):
    v = ctypes.c_float(-1.0)
    rc = b.vaio_get_param(pid, 1, ctypes.byref(v))
    return rc, v.value


def set_int(pid, val):
    v = ctypes.c_int32(val)
    return b.vaio_set_param(pid, 0, ctypes.byref(v))


def set_float(pid, val):
    v = ctypes.c_float(val)
    return b.vaio_set_param(pid, 1, ctypes.byref(v))


# 0. 基线：进程内新加载的桥必须是 auto 模式
check("reset to auto mode", set_int(b"channels.countMode", 0) == 0)
rc, mode = get_int(b"channels.countMode")
check("countMode readback == 0", rc == 0 and mode == 0, f"rc={rc} mode={mode}")
rc, ch = get_int(b"channels.count")
check("default channels.count is a valid tier", rc == 0 and ch in VALID, f"ch={ch}")

# 1. 手动模式：有效档位立即跟随 channels.count
check("set countMode=1", set_int(b"channels.countMode", 1) == 0)
for want in (6, 4, 8, 2):
    rc = set_int(b"channels.count", want)
    check(f"set channels.count={want}", rc == 0, f"rc={rc}")
    rc, got = get_int(b"channels.count")
    check(f"manual channels.count readback == {want}", rc == 0 and got == want, f"got={got}")

# 2. 非法档位拒绝且不改变当前有效值（上一步有效值为 2）
rc = set_int(b"channels.count", 5)
check("reject channels.count=5", rc == -1, f"rc={rc}")
rc, got = get_int(b"channels.count")
check("invalid write leaves effective tier intact", rc == 0 and got == 2, f"got={got}")

# 3. float 取值路径与整型一致
check("set channels.count=6 via float", set_float(b"channels.count", 6.0) == 0)
rc, gotf = get_float(b"channels.count")
check("float channels.count readback == 6", rc == 0 and abs(gotf - 6.0) < 1e-6, f"got={gotf}")

# 4. 回到 auto：有效档位回到驱动环声道数
check("set countMode=0", set_int(b"channels.countMode", 0) == 0)
rc, before = get_int(b"channels.count")
check("auto channels.count is a valid tier", rc == 0 and before in VALID, f"got={before}")
# auto 下写 channels.count 只更新手动影子，不得改变当前有效档位
rc = set_int(b"channels.count", 4 if before != 4 else 8)
check("auto mode accepts channels.count", rc == 0, f"rc={rc}")
rc, after = get_int(b"channels.count")
check("auto mode effective tier unchanged by manual write",
      rc == 0 and after == before, f"before={before} after={after}")

if fails:
    print(f"\nFAILED {len(fails)} checks: {fails}")
    sys.exit(1)

print("\nALL VAIO CHANNEL MODE CHECKS PASSED")
sys.exit(0)
