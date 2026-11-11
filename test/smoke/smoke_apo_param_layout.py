# smoke_apo_param_layout.py — APO 共享参数块布局漂移门（设计 D4）
#
# 三方一致性：① 生成器 --check（引擎表 → C/Dart 序号表不漂移）；
# ② 手写 ApoShared.h 的布局常量与生成器常量交叉断言；
# ③ 生成产物自身的哨兵（计数、首末 id、字符串槽表）。
import os
import re
import subprocess
import sys

# Windows 控制台多为 cp1252：中文标签 print 会 UnicodeEncodeError
# 让门自杀（2026-11-10 J5 实测）；放宽为 replace 只损字形不损裁定。
try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAIL = []


def check(cond, label):
    print(('  PASS ' if cond else '  FAIL ') + label)
    if not cond:
        FAIL.append(label)


def read(p):
    with open(os.path.join(ROOT, p), encoding='utf-8') as f:
        return f.read()


def main():
    # ① 生成器漂移检查（实跑 --check，以其退出码为准）
    r = subprocess.run(
        [sys.executable, os.path.join(ROOT, 'tools', 'gen_apo_param_layout.py'), '--check'],
        capture_output=True, text=True)
    check(r.returncode == 0, 'gen_apo_param_layout --check 无漂移')
    for line in r.stdout.splitlines():
        print('    ' + line)

    c_h = read('core/desktop/windows-drivers/03_system_apo/ApoParamIndex.h')
    dart = read('app/auradsp_app/lib/engine/apo_param_index.dart')
    shared = read('core/desktop/windows-drivers/03_system_apo/ApoShared.h')

    # ③ 产物哨兵
    check('#define APO_NUM_PARAM_COUNT 339' in c_h, 'C 表数值参数计数 339')
    check('const int kApoNumParamCount = 339;' in dart, 'Dart 表数值参数计数 339')
    # 全面复审 S3（APO-1）：追加段哨兵——自定义 setter 家族入块、
    # 存量首槽不移位、块版本三方全等（ApoShared 手写 vs 两生成产物）。
    check("'channels.mode': 335" in dart and "'viz.fftSize': 338" in dart,
          'S3 追加段入块（channels.mode@335 … viz.fftSize@338）')
    check('APO_PARAM_BLOCK_VERSION 2' in c_h
          and 'const int kApoParamBlockVersion = 2;' in dart
          and '#define APO_PARAMS_VERSION 2u' in shared,
          '参数块版本 v2 三方全等')
    sha_c = re.search(r'sha256\[:16\]=(\w+)', c_h)
    sha_d = re.search(r'sha256\[:16\]=(\w+)', dart)
    check(sha_c and sha_d and sha_c.group(1) == sha_d.group(1),
          'C/Dart 两产物同源摘要一致')
    check('liveprog.param64' in c_h and 'liveprogmc.param64' in c_h,
          '动态参数族扩到 param64')
    check("'eq.curve': 0" in dart and "'liveprog.code': 2" in dart,
          'Dart 字符串槽序 eq.curve/arbmag/liveprog.code/graph.order')

    # ② ApoShared.h 与生成布局的常量交叉断言
    m = re.search(r'struct ApoParamBlockHeader \{([^}]*)\}', shared)
    check(m is not None and 'writeSeq' in m.group(1) and 'bypass' in m.group(1)
          and 'strUsed[4]' in m.group(1), 'ApoShared 参数头含 seqlock/bypass/strUsed[4]')
    check('sizeof(ApoParamBlockHeader) == 64' in shared, '参数头 64B 静态断言在位')
    check('APO_BLOCK_HEADER_BYTES 64' in c_h, '生成布局头 64B 与手写头一致')
    check('APO_BLOCK_MASK_OFFSET 64' in c_h and
          'const int kApoBlockValuesOffset = 128;' in dart,
          '有效位图区在位（mask@64，values@128）')
    check('AURA_APO_PARAMS_NAME' in shared and 'AURA_APO_TELEMETRY_NAME' in shared,
          '两块共享对象名已登记')
    check('seatState' in shared and 'spectrum[32]' in shared,
          'telemetry 含座位状态与 spectrum[32]')

    print('smoke_apo_param_layout: ' + ('FAIL' if FAIL else 'PASS'))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
