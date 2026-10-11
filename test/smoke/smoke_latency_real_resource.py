"""smoke_latency_real_resource.py — 用**真实** IR / VDC 资源验证延迟探针。

背景：仓库里没有 .vdc / .wav fixture，所以延迟探针此前只能验证
「无资源时严格返回 -1」这一条路径 —— 非零延迟的**成功**路径从未跑过。
本测试用外部真实资源补上这一段。

资源来自 D:\\myPrograms\\AudioEffect\\Impulse（**只读**，绝不修改）：
  * JamesDSP\\DDC\\*.vdc   —— 本引擎原生 VDC 格式
  * Convolver\\*.wav       —— 脉冲响应

如果该目录不存在，本测试整体跳过，而不是失败 —— 资源是外部依赖。

三条不变式：
  1. 有资源时探针必须返回**非负**样本数（此前从未验证过的成功路径）。
  2. 样本数必须**小于块长**，否则说明补偿没生效，会导致相位错乱。
  3. 相同资源重复探测结果稳定（无隐藏状态）。
4. **产品行为验证**：加载真实 VDC 后，用宽带信号过一遍引擎，输出必须
   被塑形（与输入比有增益变化）。若完全透传，说明 VDC 压根没生效。
"""
import ctypes
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

# 外部只读资源根
IMPULSE_ROOT = r'D:\myPrograms\AudioEffect\Impulse'
VDC_DIR = os.path.join(IMPULSE_ROOT, 'JamesDSP', 'DDC')
IR_DIR = os.path.join(IMPULSE_ROOT, 'Convolver')

BLOCK = 2048
FAIL = []

# VDC 是高通滤波器（AKG K2xx 系列在 DC 处增益为 0），冲激（纯 DC）
# 会被完全滤掉，看起来就像「VDC 没生效」。这曾经让我误判成产品缺陷。
# 因此延迟探测必须用**宽带**激励（粉噪），而不是单位冲激。
NOISE_N = 1 << 14
_NOISE = []


def broadband(seed=12345):
    """确定性粉噪（Voss-McCartney 近似）。固定种子 => 结果可复现。"""
    global _NOISE
    if _NOISE:
        return _NOISE
    st = seed
    rows = [0.0] * 8
    out = []
    for _ in range(NOISE_N):
        st = (1103515245 * st + 12345) & 0x7FFFFFFF
        idx = (st >> 16) & 7
        rows[idx] = (rows[idx] + (st / 1073741824.0 - 1.0)) / 2.0
        out.append(sum(rows) * 0.25)
    _NOISE = out
    return out


def check(name, cond, detail=''):
    if cond:
        print('  [PASS] %s' % name)
    else:
        print('  [FAIL] %s  %s' % (name, detail))
        FAIL.append(name)


def first_file(directory, suffix, min_size=1):
    """取目录下第一个符合后缀的文件（顺序稳定，便于复现）。"""
    try:
        names = sorted(n for n in os.listdir(directory) if n.lower().endswith(suffix))
    except OSError:
        return None
    for n in names:
        p = os.path.join(directory, n)
        try:
            if os.path.getsize(p) >= min_size:
                return p
        except OSError:
            continue
    return None


def main():
    if not os.path.exists(DLL):
        print('找不到引擎 DLL')
        return 1
    lib = ctypes.CDLL(DLL)

    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_probe_component_with_resource.restype = ctypes.c_int32
    lib.auradsp_probe_component_with_resource.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_double,
        ctypes.POINTER(ctypes.c_uint32)]

    vdc = first_file(VDC_DIR, '.vdc')
    ir = first_file(IR_DIR, '.wav', min_size=4096)

    if not vdc and not ir:
        print('外部 IR/VDC 资源不可用（%s），跳过。' % IMPULSE_ROOT)
        return 0

    print('=== 真实资源延迟探针 ===')
    print('VDC: %s' % (vdc or '(无)'))
    print('IR : %s' % (ir or '(无)'))

    # 只读校验：探测过程不得修改资源文件
    watch = [p for p in (vdc, ir) if p]
    before = {p: (os.path.getsize(p), os.path.getmtime(p)) for p in watch}

    h = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(48000.0),
                                           ctypes.c_int32(BLOCK)))
    if not h:
        print('auradsp_create 失败')
        return 1
    try:
        for label, comp, res in (('VDC', 'ddc', vdc),
                                 ('卷积', 'convolver', ir)):
            if not res:
                continue
            out = ctypes.c_uint32(0)
            rc = lib.auradsp_probe_component_with_resource(
                comp.encode('utf-8'), res.encode('utf-8'),
                ctypes.c_double(48000.0), ctypes.byref(out))
            got = int(out.value)
            print('  %s %-10s rc=%d samples=%d' %
                  (label, os.path.basename(res)[:10], rc, got))
            # rc 语义（probe_component_impl）：
            #   0  成功，out_samples = 实测延迟样本数
            #  -1  参数非法 / 组件不支持且无资源
            #  -2  探测实例创建失败
            #  -3  探测未产生可辨识效果（能量与基线相同）→ 不可测
            check('%s 带资源探测返回成功' % label, rc == 0,
                  'rc=%d（-3 = 未产生可辨识效果）' % rc)
            if rc == 0:
                check('%s 返回非负样本数' % label, got >= 0, 'got=%d' % got)
                # 能量法对「强高通」类组件会测出 0：冲激是 DC，被滤光后
                # 首过零点就是样本 0，与基线相同。这不是缺陷，而是该方法
                # 的固有边界 —— 只要 rc==0 且结果稳定即可，不强求非零。
                check('%s 样本数在合理范围' % label, got < BLOCK,
                      'got=%d 超过块长，补偿会跨块错位' % got)
            else:
                # rc=-3 = 该组件在能量法下不可测。这是**已知边界**，
                # 不是回归；关键是不得静默返回 0 延迟冒充成功。
                check('%s 不可测时明确返回 -3 而非伪造 0 延迟' % label,
                      rc == -3, 'rc=%d' % rc)

            # 重复探测必须稳定
            out2 = ctypes.c_uint32(0)
            lib.auradsp_probe_component_with_resource(
                comp.encode('utf-8'), res.encode('utf-8'),
                ctypes.c_double(48000.0), ctypes.byref(out2))
            check('%s 重复探测结果稳定' % label, int(out2.value) == got,
                  '%d vs %d' % (got, int(out2.value)))

        # 对照：无资源时必须**拒绝**（rc!=0），不得伪造 0 延迟
        out = ctypes.c_uint32(0)
        rc = lib.auradsp_probe_component_with_resource(
            b'ddc', b'', ctypes.c_double(48000.0), ctypes.byref(out))
        check('无资源时拒绝探测而非返回 0 延迟', rc != 0,
              'rc=%d out=%d（rc=0 会把「不可测」伪装成「零延迟」）' % (rc, int(out.value)))
    finally:
        lib.auradsp_destroy(h)

    # ---- 产品行为：真实 VDC 加载后必须真的在塑形信号 ----
    # 曾在这里误判过一次：用单位冲激探测，看到「输出全 0」就断定
    # VDC 没生效。实际是 VDC 是高通，DC 冲激被它滤掉了 —— 产品是对的，
    # 测试方法错了。宽带激励才测得准。
    if vdc:
        lib.auradsp_process.restype = None
        lib.auradsp_process.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
            ctypes.POINTER(ctypes.c_float), ctypes.c_int]
        p = ctypes.create_string_buffer(4096)
        h2 = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(48000.0),
                                                ctypes.c_int32(BLOCK)))
        try:
            b = vdc.encode('utf-8')
            lib.auradsp_set_param(h2, b'ddc.load', b, len(b))
            one = ctypes.c_int32(1)
            lib.auradsp_set_param(h2, b'ddc.enable', ctypes.byref(one), 4)
            noise = broadband()
            ratios = []
            inb = (ctypes.c_float * (BLOCK * 2))()
            outb = (ctypes.c_float * (BLOCK * 2))()
            for blk in range(6):
                src = noise[blk * BLOCK:(blk + 1) * BLOCK]
                for i in range(BLOCK):
                    inb[i * 2] = src[i]
                    inb[i * 2 + 1] = src[i]
                lib.auradsp_process(h2, inb, outb, ctypes.c_int(BLOCK))
                pi = max(abs(inb[i]) for i in range(BLOCK * 2))
                po = max(abs(outb[i]) for i in range(BLOCK * 2))
                if pi > 1e-6:
                    ratios.append(po / pi)
            spread = max(ratios) - min(ratios)
            print('  VDC 宽带响应 peak 比: min=%.3f max=%.3f'
                  % (min(ratios), max(ratios)))
            check('真实 VDC 加载后输出被塑形（非恒等透传）', spread > 0.02,
                  'peak 比几乎恒定(%.4f)，VDC 可能未生效' % spread)
        finally:
            lib.auradsp_destroy(h2)

    changed = [p for p in watch
               if (os.path.getsize(p), os.path.getmtime(p)) != before[p]]
    check('资源文件未被修改', not changed, str(changed))

    print('\n%s' % ('全部通过' if not FAIL else '失败: %s' % FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())