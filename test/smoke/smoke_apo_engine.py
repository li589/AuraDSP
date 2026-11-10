# smoke_apo_engine.py — APO 真处理端到端冒烟的 runner 包装（设计 P4）
#
# 本体是原生宿主 apo_engine_test.exe（进程内 COM 直驱 CAuraApo，
# 断言参数通道→引擎真处理全链，见其源头注）。本包装只负责定位
# 并转达退出码：宿主或纪律版引擎 DLL 缺失（未做 Windows 构建）
# → SKIP。CI 的实跑点在 J5b 的专用 step（同一 exe），本包装供
# 本机 runner 全套时同口径覆盖。
import os
import subprocess
import sys

# Windows 控制台多为 cp1252：中文标签 print 会 UnicodeEncodeError
# 让门自杀（2026-11-10 J5 实测）；放宽为 replace 只损字形不损裁定。
try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release')
EXE = os.path.join(OUT, 'apo_engine_test.exe')
ENGINE = os.path.join(OUT, 'auradsp_engine_apo.dll')
APO = os.path.join(OUT, 'AuraApo.dll')


def main():
    missing = [p for p in (EXE, ENGINE, APO) if not os.path.exists(p)]
    if missing:
        print('smoke_apo_engine: SKIP (missing %s)' %
              ', '.join(os.path.basename(p) for p in missing))
        return 0
    r = subprocess.run([EXE], capture_output=True, text=True, timeout=300)
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    print('smoke_apo_engine: ' + ('PASS' if r.returncode == 0 else 'FAIL'))
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
