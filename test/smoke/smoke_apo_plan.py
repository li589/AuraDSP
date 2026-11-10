# smoke_apo_plan.py — apo_config 安装计划矩阵单测的 runner 包装
# （计划书 Part II W1）。
#
# 本体是纯逻辑宿主 apo_plan_test.exe（模式 × --only × 端点方向 ×
# OS 代际 → 写/清理集合矩阵，见其源头注）。本包装只负责定位并
# 转达退出码：宿主缺失（未做 Windows 构建）→ SKIP。CI 的实跑点
# 在 J5b 的专用 step（同一 exe），本包装供本机 runner 同口径覆盖。
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
EXE = os.path.join(OUT, 'apo_plan_test.exe')


def main():
    if not os.path.exists(EXE):
        print('smoke_apo_plan: SKIP (missing apo_plan_test.exe)')
        return 0
    r = subprocess.run([EXE], capture_output=True, text=True, timeout=120)
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    print('smoke_apo_plan: ' + ('PASS' if r.returncode == 0 else 'FAIL'))
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
