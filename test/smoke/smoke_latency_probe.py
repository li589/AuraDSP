"""smoke_latency_probe.py — 组件延迟实测的契约守卫。

覆盖四条：
  1. `auradsp_probe_component` 对需要外部资源的组件（convolver/ddc/liveprog）
     仍返回 -1「不可测」，**绝不返回 0 并编造一个 0ms**；
  2. 新的 `auradsp_probe_component_with_resource` 存在，且无资源路径时
     与旧函数行为一致（仍是 -1，不因新增符号而放宽）；
  3. 无需资源的组件（bass/eq/...）实测成功并给出非负样本数；
  4. 2026-10-19 新增：
     - `auradsp_probe_component_current` 存在；haas（纯延迟线）按传入的
       当前延迟实测（12ms→576、5ms→240 @48k），spatial 实测为 0ms
       （链上无前瞻，ITD 是耳间差而非链延迟）。

仓库内没有随附的 .vdc/.wav 测试资源（`Get-ChildItem test -Include *.vdc,*.wav`
为空），因此「带真实资源测出非零延迟」这一条不在此覆盖，
需要依赖使用者本机已加载的资源。
"""
import ctypes
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

FAIL = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAIL.append(label)


def main():
    lib = ctypes.CDLL(DLL)

    lib.auradsp_probe_component.restype = ctypes.c_int32
    lib.auradsp_probe_component.argtypes = [ctypes.c_char_p, ctypes.c_double,
                                           ctypes.POINTER(ctypes.c_uint32)]
    lib.auradsp_probe_component_with_resource.restype = ctypes.c_int32
    lib.auradsp_probe_component_with_resource.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_double,
        ctypes.POINTER(ctypes.c_uint32)]
    lib.auradsp_probe_component_current.restype = ctypes.c_int32
    lib.auradsp_probe_component_current.argtypes = [
        ctypes.c_char_p, ctypes.c_double, ctypes.c_double,
        ctypes.POINTER(ctypes.c_uint32)]

    out = ctypes.c_uint32(0)

    print('\n=== 1) 无资源组件：实测应成功 ===')
    for comp in (b'bass', b'eq', b'shelf'):
        out.value = 0
        rc = lib.auradsp_probe_component(comp, ctypes.c_double(48000.0),
                                         ctypes.byref(out))
        check(rc == 0 and out.value >= 0,
              '%s 实测成功 (rc=%d, samples=%d)' % (comp.decode(), rc, out.value))

    print('\n=== 2) 需资源组件：不带资源必须是 -1「不可测」，不能是 0 ===')
    for comp in (b'convolver', b'ddc', b'liveprog'):
        out.value = 0
        rc = lib.auradsp_probe_component(comp, ctypes.c_double(48000.0),
                                         ctypes.byref(out))
        check(rc == -1,
              '%s 无资源返回 -1（而非伪造 0ms），实得 rc=%d' % (comp.decode(), rc))

    print('\n=== 3) 新符号存在，且 null 资源路径时行为与旧函数一致 ===')
    for comp in (b'ddc', b'convolver'):
        out.value = 0
        rc = lib.auradsp_probe_component_with_resource(comp, None,
                                                       ctypes.c_double(48000.0),
                                                       ctypes.byref(out))
        check(rc == -1,
              '%s 传 NULL 资源仍为 -1（不因新符号而放宽），实得 rc=%d'
              % (comp.decode(), rc))

    out.value = 0
    rc = lib.auradsp_probe_component_with_resource(b'bass', None,
                                                   ctypes.c_double(48000.0),
                                                   ctypes.byref(out))
    check(rc == 0, 'bass 传 NULL 资源仍走旧逻辑并实测成功 (rc=%d)' % rc)

    print('\n=== 4) 未知组件仍返回 -1 ===')
    out.value = 0
    rc = lib.auradsp_probe_component(b'__nope__', ctypes.c_double(48000.0),
                                     ctypes.byref(out))
    check(rc == -1, '未知组件返回 -1 (rc=%d)' % rc)

    print('\n=== 5) haas 纯延迟线：按当前延迟实测（逐声道首非零取最大） ===')
    for arg, expect in ((12.0, 576), (5.0, 240), (3.0, 144), (0.0, 0)):
        out.value = 0
        rc = lib.auradsp_probe_component_current(b'haas', ctypes.c_double(arg),
                                                 ctypes.c_double(48000.0),
                                                 ctypes.byref(out))
        check(rc == 0 and abs(out.value - expect) <= 1,
              'haas @%gms → samples=%d (expect≈%d), rc=%d'
              % (arg, out.value, expect, rc))

    print('\n=== 6) spatial：诚实测出 0ms（链上无前瞻，ITD 是耳间差） ===')
    out.value = 0
    rc = lib.auradsp_probe_component(b'spatial', ctypes.c_double(48000.0),
                                     ctypes.byref(out))
    check(rc == 0 and out.value == 0,
          'spatial 实测成功且为 0 样本 (rc=%d, samples=%d)' % (rc, out.value))

    print()
    if FAIL:
        print('FAILED (%d):' % len(FAIL))
        for f in FAIL:
            print('  - ' + f)
        return 1
    print('>>> 延迟探针契约验证通过 <<<')
    return 0


if __name__ == '__main__':
    sys.exit(main())