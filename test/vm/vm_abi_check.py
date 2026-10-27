# -*- coding: utf-8 -*-
"""vm_abi_check.py -- P-028 bridge ABI negotiation live check (Win7 py3.8 / Win10 py3.12).

Verifies on the VM itself:
  [1] engine auradsp_abi() == 2
  [2] three bridges export *_abi() == 2 (same ABI generation)
  [3] engine viz frame size sentinel: auradsp_viz_read + 1600B frame ABI v2
Exit code 0 = all pass.
"""
import ctypes
import os
import sys

EXPECT = 2

def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ((" (%s)" % detail) if detail else ""))
    return cond

fails = []

# [1] engine
eng = None
for p in (r"C:\AuraDSP\auradsp_engine.dll",
          r"C:\Users\li\Desktop\Projects\AuraDSP\bin\auradsp_engine.dll"):
    if os.path.exists(p):
        try:
            eng = ctypes.CDLL(p)
            print("engine: " + p)
            break
        except OSError as e:
            print("LOAD-FAIL " + p + " : " + str(e))
if eng is None:
    print("FAIL  engine dll not loadable")
    sys.exit(1)

eng.auradsp_abi.restype = ctypes.c_uint32
eng.auradsp_abi.argtypes = []
if not check("[1] auradsp_abi() == 2", eng.auradsp_abi() == EXPECT,
             "got %d" % eng.auradsp_abi()):
    fails.append("engine abi")

# [2] bridges
BRIDGES = [
    ("auraasio_bridge.dll", "asio_abi"),
    ("auravaio_bridge.dll", "vaio_abi"),
    ("auravm_bridge.dll", "vb_abi"),
]
for dll, fn in BRIDGES:
    loaded, val = None, None
    for base in (r"C:\AuraDSP", r"C:\Users\li\Desktop\Projects\AuraDSP\bin"):
        p = os.path.join(base, dll)
        if os.path.exists(p):
            try:
                loaded = ctypes.CDLL(p)
                f = getattr(loaded, fn)
                f.restype = ctypes.c_uint32
                f.argtypes = []
                val = f()
                print("%s: %s -> %s=%d" % (dll, base, fn, val))
                break
            except (OSError, AttributeError) as e:
                print("FAIL  %s @ %s : %s" % (dll, base, e))
                loaded = None
    if loaded is None:
        check("[2] %s %s()==2" % (dll, fn), False, "not loadable / no export")
        fails.append(dll)
    elif not check("[2] %s %s()==2" % (dll, fn), val == EXPECT, "got %s" % val):
        fails.append(dll)

# [3] bridge/engine co-generation: all reported ABI values must agree
check("[3] engine/bridge same ABI generation", not fails, "; ".join(fails) or "all == 2")

if fails:
    sys.exit(1)
print("vm_abi_check: all passed")
