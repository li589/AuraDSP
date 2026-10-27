# -*- coding: utf-8 -*-
"""smoke_vm_parallel.py — Z17 组间并行处理验收（不依赖 Voicemeeter 在线）。

驱动 vm_parallel_test.exe：两个同初态 PumpCtx 喂同一段确定性输入块序列，
分别走串行/并行路径（唯一实现 ProcessGroupVm），逐块位级比对输出缓冲 +
遥测终值精确相等 + 末块语义断言（变换/透传/mask/空指针组）+ 墙钟验证
（8 组 × 250µs 假插件成本：并行应 <60% 串行）+ B2 straggler 场景（worker
卡死 → fan-in 2ms 截止 → 冻结 → 恢复，回调墙钟有界 / 无引擎重入 /
parallelOn 不被 RT 改动 / 恢复后逐位一致）。

机器无关性：位级/语义断言与核数无关；单核（workers==0）时并行退化为串行，
exe 自动跳过墙钟与 straggler 断言只报 note——门禁仍应 PASS（降级路径本身
被验证）。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'vm_parallel_test.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


check('vm_parallel_test.exe exists', os.path.exists(EXE), EXE)
if not os.path.exists(EXE):
    print('VMPARALLEL FAILURES:', FAIL)
    sys.exit(1)

try:
    r = subprocess.run([EXE], capture_output=True, text=True, timeout=180)
except subprocess.TimeoutExpired:
    check('exe finished (no deadlock)', False, 'timeout 180s — fan-in 挂死？')
    print('VMPARALLEL FAILURES:', FAIL)
    sys.exit(1)

check('exit code 0', r.returncode == 0,
      'rc=%d err=%s' % (r.returncode, r.stderr.strip()[:200]))
try:
    d = json.loads(r.stdout.strip().splitlines()[-1])
    check('valid JSON dict', isinstance(d, dict))
except (ValueError, IndexError) as ex:
    check('valid JSON dict', False, str(ex)[:120])
    d = None

if d is not None:
    if not d.get('ran'):
        print('NOTE parallel skipped: %s' % d.get('note', '?'))
    else:
        # 位级一致 + 语义断言 + 遥测相等（exe 内 5 场景汇总）
        check('all scenarios ok (bit-exact/semantics/telemetry)', d.get('allOk') is True,
              'detail=%s' % d.get('detail', ''))
        check('perf assert ok', d.get('perfOk') is True,
              'note=%s' % (d.get('note', ''),))
        cores = d.get('cores', 0)
        workers = d.get('workers', 0)
        check('worker pool sane', isinstance(workers, int) and 0 <= workers <= 7,
              'workers=%s cores=%s' % (workers, cores))
        if cores >= 2:
            check('multi-core machine has workers', workers >= 1,
                  'workers=%s cores=%s' % (workers, cores))
        else:
            print('NOTE single-core: workers=%s，并行退化串行（exe 自跳墙钟断言）' % workers)
        ser = d.get('serUs', 0)
        par = d.get('parUs', 0)
        if workers >= 1:
            check('parallel wall < serial (real speedup)',
                  isinstance(ser, (int, float)) and isinstance(par, (int, float))
                  and par < ser,
                  'ser=%s par=%s' % (ser, par))

        # ---- B2：straggler 场景（worker 卡死 → fan-in 截止 → 冻结 → 恢复）----
        if d.get('stRan'):
            check('straggler all ok', d.get('stOk') is True,
                  'note=%s' % (d.get('stNote', ''),))
            # 核心断言：fan-in 2ms 截止——回调墙钟有界（pre-B2 的 4×10^8
            # 自旋 ≈ 4-12s / 卡死自愈 5s，反向验证据此判红）。4ms 期望值
            # （RT 自认领 ~4 组 × 500µs + 2ms 截止），100ms 留 25× 裕量。
            mx = d.get('stMaxCbMs', 0)
            check('straggler fan-in bounded (max callback <100ms)',
                  isinstance(mx, (int, float)) and 0 < mx < 100.0,
                  'maxCbMs=%s' % (mx,))
            check('straggler no engine re-entry', d.get('stReentered') is False)
            check('straggler parallelOn intact (RT not mutate)',
                  d.get('stParOn') == 1)
            check('straggler hung group resumed', d.get('stResume') is True)
        else:
            print('NOTE straggler skipped: %s' % d.get('stNote', '?'))

if FAIL:
    print('VMPARALLEL FAILURES:', FAIL)
    sys.exit(1)
print('VMPARALLEL ALL PASSED')
