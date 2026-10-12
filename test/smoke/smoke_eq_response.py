"""smoke_eq_response.py — C2：EQ 响应探针的数值正确性验证。

探针的用途是让 UI 画引擎真实产生的曲线，所以它必须满足：

  1. **平坦曲线 -> 全 0 dB**。0 dB 的锚点经 makima + 最小相位化后理论上
     仍是全通；若明显偏离，说明探针走错了链路或标定错了。
  2. **单点提升 -> 在该频率附近抬升**，且单调过渡，不出现发散。
  3. **低频截止样曲线 -> 20 Hz 附近深衰减，高频接近 0 dB**。
  4. 非法输入返回非 0，而不是崩溃或给出垃圾数据。
  5. **采样率一致时结果一致**（纯函数，无隐藏状态）。
  6. 与 UI 自己的 smoothstep 近似**确有差异** —— 这正是 C2 存在的原因；
     若两者完全相同，说明探针其实只是在复刻 UI 的近似，测试就该失败。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

lib = ctypes.CDLL(DLL)
lib.auradsp_probe_eq_response.restype = ctypes.c_int
lib.auradsp_probe_eq_response.argtypes = [
    ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
    ctypes.c_double,
    ctypes.POINTER(ctypes.c_float),
]

F_MIN, F_MAX = 20.0, 20000.0
N = 129
FAIL = []


def probe(curve, sr=48000, n=N, fmax=F_MAX):
    buf = (ctypes.c_float * n)()
    rc = lib.auradsp_probe_eq_response(sr, curve.encode('utf-8'), n, fmax, buf)
    return rc, list(buf)


def curve_db(curve, freqs, sr=48000):
    """在指定频率上取探针输出（对数等分取样后线性内插）。"""
    rc, db = probe(curve, sr)
    assert rc == 0, 'probe failed rc=%d' % rc
    lf0, lf1 = math.log(F_MIN), math.log(F_MAX)
    xs = [math.exp(lf0 + i / (N - 1) * (lf1 - lf0)) for i in range(N)]
    out = []
    for f in freqs:
        if f <= xs[0]:
            out.append(db[0]); continue
        if f >= xs[-1]:
            out.append(db[-1]); continue
        i = max(j for j in range(N - 1) if xs[j] <= f)
        t = (f - xs[i]) / (xs[i + 1] - xs[i])
        out.append(db[i] + t * (db[i + 1] - db[i]))
    return out


def check(name, cond, detail=''):
    if cond:
        print('  [PASS] %s' % name)
    else:
        print('  [FAIL] %s  %s' % (name, detail))
        FAIL.append(name)


print('=== C2 EQ 响应探针 ===')

# 1) 平坦曲线
flat = curve_db('20:0.0;20000:0.0', [20, 100, 1000, 10000, 20000])
worst = max(abs(v) for v in flat)
check('平坦曲线处处接近 0 dB', worst < 1.5, 'worst=%.3f dB -> %s' % (worst, flat))

# 2) 1 kHz 提升 12 dB
boost = curve_db('100:0.0;1000:12.0;10000:0.0', [30, 100, 1000, 10000])
check('1kHz 点在提升点抬升', 10.0 < boost[2] < 14.0,
      'got %.2f' % boost[2])
check('远离提升点回到 0 dB', abs(boost[0]) < 1.5 and abs(boost[3]) < 1.5,
      'low=%.2f high=%.2f' % (boost[0], boost[3]))

# 3) 低切样曲线：末端锚点在 10000Hz 为 0dB，因此高频应回到 0dB 附近。
# 不要用止于 2000Hz 的曲线验证高频：超出末端锚点的外推行为与锚点理想不同。
shelf = curve_db('20:-24.0;200:-12.0;2000:-6.0;10000:0.0', [20, 100, 1000, 10000])
check('低频被衰减', shelf[0] < -15.0, '20Hz=%.2f' % shelf[0])
check('高频回到末端锚点', abs(shelf[3]) < 3.0, '10k=%.2f' % shelf[3])
check('曲线单调抬升（无发散）',
      shelf[0] < shelf[1] < shelf[2],
      '%.2f/%.2f/%.2f' % (shelf[0], shelf[1], shelf[2]))

# 4) 非法输入
rc, _ = probe('20:0.0', n=N)  # 单点 -> 必须拒绝
check('单点曲线返回错误', rc != 0, 'rc=%d' % rc)
rc, _ = probe('20000:0.0;20:0.0', n=N)  # 逆序但合法，应成功
check('逆序输入被排序后接受', rc == 0, 'rc=%d' % rc)
rc, _ = probe('20:0.0;30000:0.0', n=N)  # 超出 Nyquist，应钳位而非报错
check('超 Nyquist 频点被钳位', rc == 0, 'rc=%d' % rc)

# 5) 纯函数性：同输入两次结果一致
_, a = probe('1000:6.0')
_, b = probe('1000:6.0')
check('重复调用结果一致（无隐藏状态）', a == b)

# 6) 采样率影响：44.1k 与 48k 在同一频率应有相近但不相同的响应
r48 = curve_db('100:0.0;1000:12.0;10000:0.0', [1000], sr=48000)[0]
r44 = curve_db('100:0.0;1000:12.0;10000:0.0', [1000], sr=44100)[0]
check('44.1k / 48k 响应接近（差 <2dB）', abs(r48 - r44) < 2.0,
      '48k=%.2f 44.1k=%.2f' % (r48, r44))

# 7) 与 UI 的 smoothstep 近似**应当不同** —— 这正是 C2 存在的理由
_, raw = probe('100:9.0;1000:-9.0', sr=48000)
lf0, lf1 = math.log(F_MIN), math.log(F_MAX)
xs = [math.exp(lf0 + i / (N - 1) * (lf1 - lf0)) for i in range(N)]
nodes_f, nodes_g = [100.0, 1000.0], [9.0, -9.0]


def ui_smoothstep(f):
    if f <= nodes_f[0]: return nodes_g[0]
    if f >= nodes_f[-1]: return nodes_g[-1]
    lf0_, lf1_ = math.log(nodes_f[0]), math.log(nodes_f[1])
    t = (math.log(f) - lf0_) / (lf1_ - lf0_)
    s = t * t * (3 - 2 * t)
    return nodes_g[0] + s * (nodes_g[1] - nodes_g[0])


diffs = [abs(raw[i] - ui_smoothstep(xs[i])) for i in range(N)]
peak = max(diffs)
print('  UI 近似 vs 引擎实测 最大偏差: %.2f dB' % peak)
check('实测与 UI 近似确有差异（C2 前提成立）', peak > 0.8,
      'peak=%.3f —— 若过小说明探针只是在复刻 UI 近似' % peak)

# 8) eqm: 工作模式头：无头 == 显式 eqm:1:0（向后兼容）；
#    换插值 / 换架构必须真实改变响应（否则 UI 选项是假控件）；
#    非法头回退默认不断言崩溃。
_, base = probe('100:0.0;1000:12.0;10000:0.0', sr=48000)
_, explicit = probe('eqm:1:0;100:0.0;1000:12.0;10000:0.0', sr=48000)
check('无头与显式 eqm:1:0 逐点一致（向后兼容）', base == explicit,
      'maxdiff=%.4f' % max(abs(a - b) for a, b in zip(base, explicit)))
_, pchip = probe('eqm:0:0;100:0.0;1000:12.0;10000:0.0', sr=48000)
d_interp = max(abs(a - b) for a, b in zip(base, pchip))
check('PCHIP 与 Makima 响应不同（插值选项真实生效）', d_interp > 0.5,
      'maxdiff=%.4f' % d_interp)
_, iir6 = probe('eqm:1:2;100:0.0;1000:12.0;10000:0.0', sr=48000)
d_arch = max(abs(a - b) for a, b in zip(base, iir6))
check('IIR6 与 FIR 响应不同（架构选项真实生效）', d_arch > 0.5,
      'maxdiff=%.4f' % d_arch)
_, badhead = probe('eqm:9:9;100:0.0;1000:12.0;10000:0.0', sr=48000)
check('非法 eqm 头回退默认（不断言崩溃、结果一致）', base == badhead,
      'maxdiff=%.4f' % max(abs(a - b) for a, b in zip(base, badhead)))

print('\n=== %d/%d 通过 ===' % (16 - len(FAIL), 16) if not FAIL else
      '\n失败: %s' % FAIL)
sys.exit(1 if FAIL else 0)