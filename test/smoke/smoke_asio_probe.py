"""smoke_asio_probe.py — ASIO 驱动枚举与能力探测验收（04_asio_engine Phase 1）。

验收标准（机器无关，无音频零风险）：
  1. asio_probe.exe 存在（需先构建 core/desktop/windows-drivers）。
  2. 枚举集合 == 注册表 HKLM\\SOFTWARE\\ASIO（64 位视图）驱动名集合
     （SDK 语义：驱动名 = 子键 Description 值，缺失时回退子键名，
     见 ASIOSDK host/pc/asiolist.cpp newDrvStruct；probe 输出 UTF-8，
     winreg 给 Unicode，直接比对）。
  3. 每个条目 clsid 为 {8-4-4-4-12} 形态。
  4. ok 的驱动能力字段自洽：outChannels>0 / prefBuf>0 / sampleRate>0 /
     out0TypeName 已知；open 失败的条目必须带 err 说明（如实记录，不算失败）。
  5. 至少一个驱动 ok（否则本机无可用 ASIO 驱动，记 note 跳过而非失败）。
"""
import json
import os
import re
import subprocess
import sys
import winreg

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'asio_probe.exe')
ASIO_KEY = r'SOFTWARE\ASIO'
CLSID_RE = re.compile(r'^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + (('  ' + detail) if (detail and not cond) else ''))
    if not cond:
        FAIL.append(name)


def registry_names():
    """HKLM\\SOFTWARE\\ASIO 各子键的 Description 值（64 位视图，与 x64 probe 一致）。

    与 SDK 枚举语义对齐（asiolist.cpp newDrvStruct：ASIODRV_DESC 优先，
    缺失回退子键名）——probe 的 name 就是 Description，故对账必须同基准。
    """
    names = []
    try:
        k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, ASIO_KEY, 0,
                           winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
    except OSError:
        return names
    try:
        i = 0
        while True:
            sub = winreg.EnumKey(k, i)
            i += 1
            try:
                with winreg.OpenKey(k, sub, 0, winreg.KEY_READ) as sk:
                    name, _ = winreg.QueryValueEx(sk, 'Description')
            except OSError:
                name = sub  # SDK 回退语义：无 Description 用子键名
            names.append(name)
    except OSError:
        pass
    finally:
        winreg.CloseKey(k)
    return names


def main():
    print('== smoke_asio_probe ==')
    if not os.path.exists(EXE):
        print('NOTE  asio_probe.exe 不存在（未构建 windows-drivers），跳过')
        print('asio_probe: SKIPPED (not built)')
        return 0
    if sys.platform != 'win32':
        print('NOTE  非 Windows，跳过')
        return 0

    try:
        r = subprocess.run([EXE], capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        check('asio_probe 120s 内退出', False, 'timeout')
        print()
        print('ASIO_PROBE FAILURES:', FAIL)
        return 1

    check('asio_probe 退出码 0', r.returncode == 0, 'rc=%d' % r.returncode)
    try:
        data = json.loads(r.stdout.decode('utf-8'))
    except Exception as e:
        check('stdout 为合法 UTF-8 JSON', False, repr(e))
        print()
        print('ASIO_PROBE FAILURES:', FAIL)
        return 1
    check('stdout 为合法 UTF-8 JSON', True)

    drivers = data.get('drivers', [])
    reg = set(registry_names())
    probe_names = set(d.get('name', '') for d in drivers)

    check('枚举集合 == 注册表集合', probe_names == reg,
          'probe=%s reg=%s' % (sorted(probe_names), sorted(reg)))
    check('count 字段一致', data.get('count') == len(drivers),
          'count=%s len=%d' % (data.get('count'), len(drivers)))

    clsid_ok = all(CLSID_RE.match(d.get('clsid', '')) for d in drivers)
    check('全部 clsid 形态合法', clsid_ok)

    ok_count = 0
    caps_ok = True
    err_ok = True
    for d in drivers:
        if d.get('ok'):
            ok_count += 1
            if not (d.get('outChannels', 0) > 0 and d.get('prefBuf', 0) > 0
                    and d.get('sampleRate', 0) > 0
                    and d.get('out0TypeName', 'Unknown') != 'Unknown'):
                caps_ok = False
                print('      字段异常:', d.get('name'), d)
        else:
            if not d.get('err'):
                err_ok = False
                print('      失败条目缺 err:', d.get('name'))
    check('ok 驱动能力字段自洽', caps_ok)
    check('失败条目均带 err 说明', err_ok)
    print('      （%d 个驱动 ok，%d 个 open 失败）'
          % (ok_count, len(drivers) - ok_count))

    if ok_count == 0:
        print('NOTE  本机无可用 ASIO 驱动（全部 open 失败），能力断言跳过')
        print('asio_probe: all checks passed (no openable driver on this machine)')
        return 0

    print()
    if FAIL:
        print('ASIO_PROBE FAILURES:', FAIL)
        return 1
    print('asio_probe: all checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
