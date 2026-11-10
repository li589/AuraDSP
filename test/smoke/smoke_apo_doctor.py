# smoke_apo_doctor.py — apo_config doctor 只读自检的 runner 包装
# （计划书 Part II W3）。
#
# doctor 的检查结论随机器环境变（CI 裸机上 testenv/注册必然
# FAIL），故本门只验**契约结构**：doctor --json 能跑通、输出可
# 解析、六项检查齐名且字段形状正确。结论本身（ok true/false）
# 不是门禁对象。exe 缺失（未做 Windows 构建）→ SKIP。
import json
import os
import subprocess
import sys

# Windows 控制台多为 cp1252：放宽 print 编码（同门族纪律）。
try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release')
EXE = os.path.join(OUT, 'apo_config.exe')
EXPECTED = {
    'testenv', 'com_registration', 'apo_dll', 'engine_dll',
    'fx_writable', 'snapshot_versions',
}


def main():
    if not os.path.exists(EXE):
        print('smoke_apo_doctor: SKIP (missing apo_config.exe)')
        return 0
    # doctor 的 JSON detail 含中文（UTF-8 直出）；text=True 会按
    # 控制台 cp1252 解码子进程输出而自爆（J5b 首跑实测），故按
    # 字节捕获、显式 UTF-8 解码。
    r = subprocess.run([EXE, 'doctor', '--json'], capture_output=True,
                       timeout=120)
    try:
        doc = json.loads(r.stdout.decode('utf-8', errors='replace'))
    except Exception as e:
        print('smoke_apo_doctor: FAIL (unparseable output: %s)' % e)
        return 1
    fails = []
    if not isinstance(doc.get('ok'), bool):
        fails.append('ok not bool')
    checks = doc.get('checks')
    if not isinstance(checks, list):
        fails.append('checks not list')
        checks = []
    names = set()
    for c in checks:
        if isinstance(c, dict):
            names.add(c.get('name'))
            if not isinstance(c.get('ok'), bool):
                fails.append('check %s ok not bool' % c.get('name'))
            if not isinstance(c.get('detail'), str):
                fails.append('check %s detail not str' % c.get('name'))
    missing = EXPECTED - names
    if missing:
        fails.append('missing checks: %s' % ','.join(sorted(missing)))
    for f in fails:
        print('smoke_apo_doctor: FAIL (%s)' % f)
    print('smoke_apo_doctor: ' + ('FAIL' if fails else 'PASS') +
          ' (doctor ok=%s, checks=%d)' % (doc.get('ok'), len(checks)))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
