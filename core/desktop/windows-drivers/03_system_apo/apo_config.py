#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apo_config.py — AuraAPO 端点安装/备份/卸载 + 音频服务重启 + 心跳握手。

设计来源：EAPO DeviceAPOInfo 流程（备份哨兵/三模式互斥/服务重启/降级重试），
实现全部自写。写注册表 + 重启音频服务，需要管理员（本工具不提权，用法见 README）。

安全 rails：
  * 物理设备（名中无 Voicemeeter/Virtual）必须加 --force，否则拒绝。
  * 所有变更先落备份：HKLM\\SOFTWARE\\AuraDSP\\Child APOs\\{endpoint}（JSON 侧车）
    + .reg 全量导出（out/apo-backups/）。卸载按备份精确还原；FxProperties 原本
    不存在则删键（!KEY 语义）。
  * 缺省只写 SFX(,5)+EFX(,7)（EAPO 默认模式），不动 LFX/GFX/MFX（减破坏面）；
    缺省 ProcessingModes 时补默认模式；删 DisableEnhancements（否则 APO 永不加载）。
  * 未签名 DLL 开发环：testenv-on 备份并置 DisableProtectedAudioDG=1，
    testenv-off 原值恢复（均重启 AudioSrv 生效）。

用法：
  python apo_config.py status
  python apo_config.py testenv-on|testenv-off --yes
  python apo_config.py install "Voicemeeter In 5" --yes [--force]
  python apo_config.py uninstall --yes
  python apo_config.py verify-heartbeat [--timeout 15]
"""
import ctypes
import json
import os
import subprocess
import sys
import time
import winreg

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))))))
OUT = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out')
BACKUP_DIR = os.path.join(OUT, 'apo-backups')
DLL = os.path.join(OUT, 'Release', 'AuraApo.dll')

OUR_CLSID = '{415AD8ED-7A45-4F4F-AC69-043830EBC174}'
FX_BASE = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'
PROC_MODES = '{d3993a3f-99c2-4402-b5ec-a92a0367664b}'
DISABLE_ENH = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e}'
FRIENDLY = '{b725f130-47ef-101a-a5f1-02608c9eebac}'
DEFAULT_MODE = '{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}'
MM_BASE = r'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
WARE_ROOT = r'SOFTWARE\AuraDSP\Child APOs'
TESTENV_KEY = r'SOFTWARE\Microsoft\Windows\CurrentVersion\Audio'
TESTENV_VAL = 'DisableProtectedAudioDG'

FAIL = []


def die(msg, code=1):
    print('FATAL ' + msg)
    sys.exit(code)


def sh(args, timeout=120):
    return subprocess.run(args, capture_output=True, text=True, errors='replace',
                          timeout=timeout)


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def reg_read(root, sub, name):
    try:
        with winreg.OpenKey(root, sub) as k:
            v, t = winreg.QueryValueEx(k, name)
            return v, t
    except OSError:
        return None, None


def reg_write_sz(root, sub, name, data):
    with winreg.CreateKey(root, sub) as k:
        winreg.SetValueEx(k, name, 0, winreg.REG_SZ, data)


def short_guid(long_id):
    for pre in ('{0.0.0.00000000}.', '{0.0.1.00000000}.'):
        if long_id.startswith(pre):
            return long_id[len(pre):]
    return long_id


def find_endpoints(substr):
    """用 apo_inspect 的输出定位端点（复用已验证的枚举）。"""
    exe = os.path.join(OUT, 'Release', 'apo_inspect.exe')
    r = sh([exe])
    if r.returncode != 0:
        die('apo_inspect failed: ' + r.stderr.strip()[:200])
    try:
        d = json.loads(r.stdout.strip().splitlines()[-1])
    except ValueError as ex:
        die('apo_inspect bad JSON: %s' % ex)
    hits = [e for e in d.get('endpoints', [])
            if substr.lower() in (e.get('name') or '').lower()
            or substr.lower() in (e.get('id') or '').lower()]
    return hits


def backup_fx(direction, long_id):
    short = short_guid(long_id)
    fx = '%s\\%s\\%s\\FxProperties' % (MM_BASE, direction.title(), short)
    stamp = time.strftime('%Y%m%d_%H%M%S')
    safe = ''.join(c if c.isalnum() else '_' for c in short)[:16]
    reg_file = os.path.join(BACKUP_DIR, 'fx_%s_%s.reg' % (safe, stamp))
    os.makedirs(BACKUP_DIR, exist_ok=True)
    # 全量导出（精确还原用；键不存在则记 !KEY）。
    r = sh(['reg', 'export',
            r'HKLM\%s' % fx.replace('\\', '\\'), reg_file, '/y'])
    existed = (r.returncode == 0 and os.path.exists(reg_file))
    if not existed and os.path.exists(reg_file):
        os.remove(reg_file)
        reg_file = None
    meta = {'endpoint': long_id, 'direction': direction,
            'had_key': existed, 'reg_file': reg_file, 'backup_at': stamp}
    meta_path = os.path.join(
        BACKUP_DIR, 'fx_%s_%s.json' % (safe, stamp))
    with open(meta_path, 'w', encoding='utf-8') as f:
        json.dump(meta, f, indent=2)
    print('backup: had_key=%s meta=%s' % (existed, meta_path))
    return meta

def restore_fx(meta):
    if not meta.get('had_key'):
        # !KEY：删整个 FxProperties（实验性安装还原，EAPO 同式）。
        sub = '%s\\%s\\%s\\FxProperties' % (
            MM_BASE, meta['direction'].title(), short_guid(meta['endpoint']))
        try:
            winreg.DeleteKey(winreg.HKEY_LOCAL_MACHINE, sub)
            print('restore: deleted FxProperties (!KEY)')
        except OSError as ex:
            print('restore: delete skipped (%s)' % ex)
        return True
    reg_file = meta.get('reg_file')
    if not reg_file or not os.path.exists(reg_file):
        print('restore: backup .reg missing, REFUSE to guess')
        return False
    # reg import 在本机实测 rc=1（.reg 含多字节值 + 续行 hex），改程序化还原：
    # 解析 .reg → 清空 FxProperties → 逐值写回（2026-10-14 手工验证通过）。
    return _restore_from_reg(reg_file, meta)


def _restore_from_reg(reg_file, meta):
    import re as _re
    import struct as _st
    data = open(reg_file, 'rb').read()
    for enc in ('utf-16', 'utf-8-sig', 'utf-8'):
        try:
            text = data.decode(enc)
            break
        except Exception:
            continue
    fx_sub = '%s\\%s\\%s\\FxProperties' % (
        MM_BASE, meta['direction'].title(), short_guid(meta['endpoint']))
    # 找 .reg 里该 key 段的值行
    lines = text.splitlines()
    in_key = False
    pending = []
    values = []
    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            continue
        m = _re.match(r'^\[HKEY_LOCAL_MACHINE\\([^\]]+)\]$', line)
        if m:
            in_key = (m.group(1) == fx_sub)
            pending = []
            continue
        if not in_key:
            continue
        if line.rstrip().endswith('\\'):
            pending.append(line.rstrip()[:-1])
            continue
        if pending:
            pending.append(line.strip())
            values.append(' '.join(x.strip() for x in pending))
            pending = []
        else:
            values.append(line.strip())
    if not values:
        print('restore: no values parsed from .reg')
        return False

    def parse_val(full):
        m = _re.match(r'^"(.*?)"\s*=\s*(.*)$', full)
        if not m:
            return None
        name, payload = m.group(1), m.group(2)
        if payload.startswith('hex(7):'):
            return name, winreg.REG_MULTI_SZ, bytes.fromhex(
                payload[7:].replace(' ', '').replace(',', ''))
        if payload.startswith('hex(2):'):
            return name, winreg.REG_EXPAND_SZ, bytes.fromhex(
                payload[7:].replace(' ', '').replace(',', ''))
        if payload.startswith('hex:'):
            return name, winreg.REG_BINARY, bytes.fromhex(
                payload[4:].replace(' ', '').replace(',', ''))
        if payload.startswith('dword:'):
            return name, winreg.REG_DWORD, int(payload[6:], 16)
        if payload.startswith('"'):
            return name, winreg.REG_SZ, payload[1:payload.rfind('"')]
        return name, winreg.REG_SZ, payload

    with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, fx_sub) as k:
        for _ in range(128):
            try:
                winreg.DeleteValue(k, winreg.EnumValue(k, 0)[0])
            except OSError:
                break
        for full in values:
            pv = parse_val(full)
            if pv is None:
                continue
            name, typ, payload = pv
            if typ == winreg.REG_DWORD:
                winreg.SetValueEx(k, name, 0, typ, payload)
            elif typ == winreg.REG_MULTI_SZ:
                s = payload.decode('utf-16-le', errors='replace').rstrip('\x00')
                winreg.SetValueEx(k, name, 0, typ, [x for x in s.split('\x00') if x])
            elif typ == winreg.REG_SZ:
                s = payload if isinstance(payload, str) else payload.decode(
                    'utf-16-le', errors='replace').rstrip('\x00')
                winreg.SetValueEx(k, name, 0, typ, s)
            else:
                winreg.SetValueEx(k, name, 0, typ, payload)
    print('restore: programmatic restore done (%d values)' % len(values))
    return True


def latest_meta():
    cands = sorted(
        [os.path.join(BACKUP_DIR, f) for f in os.listdir(BACKUP_DIR)
         if f.startswith('fx_') and f.endswith('.json')]) if os.path.isdir(BACKUP_DIR) else []
    if not cands:
        return None
    with open(cands[-1], encoding='utf-8') as f:
        return json.load(f)


def restart_audio():
    """重启 AudioSrv（含依赖倒序起停，EAPO ServiceHelper 同式，30s 超时）。"""
    deps = []
    r = sh(['sc', 'enumdepend', 'Audiosrv'])
    for line in (r.stdout or '').splitlines():
        line = line.strip()
        if line.startswith('SERVICE_NAME:'):
            deps.append(line.split(':', 1)[1].strip())
    print('audio dependents: %s' % deps)
    for svc in deps:
        sh(['sc', 'stop', svc], timeout=30)
    r = sh(['sc', 'stop', 'Audiosrv'], timeout=30)
    print('stop Audiosrv rc=%d' % r.returncode)
    time.sleep(2)
    r = sh(['sc', 'start', 'Audiosrv'], timeout=30)
    print('start Audiosrv rc=%d' % r.returncode)
    if r.returncode != 0:
        print(r.stdout[-500:] if r.stdout else '')
        return False
    time.sleep(2)
    for svc in deps:
        sh(['sc', 'start', svc], timeout=30)
    return True


def read_heartbeat(timeout=15):
    """读心跳映射：magic 对 + seq 走动才算活（存在≠处理）。"""
    import ctypes.wintypes
    k32 = ctypes.windll.kernel32
    k32.OpenFileMappingW.restype = ctypes.c_void_p
    k32.OpenFileMappingW.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_wchar_p]
    k32.MapViewOfFile.restype = ctypes.c_void_p
    k32.MapViewOfFile.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_uint32, ctypes.c_size_t]
    k32.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
    k32.CloseHandle.argtypes = [ctypes.c_void_p]
    deadline = time.time() + timeout
    first = None
    while time.time() < deadline:
        h = k32.OpenFileMappingW(0x0004, False, 'Global\\AuraAPO_Heartbeat')
        if h:
            try:
                v = k32.MapViewOfFile(h, 0x0004, 0, 0, 32)
                if v:
                    try:
                        raw = ctypes.string_at(v, 32)
                        import struct
                        magic, ver, seq, sr, frames, nbs, pid = struct.unpack(
                            '<IIIIQIII', raw)
                        if magic == 0x41554248 and ver == 1:
                            if first is None:
                                first = (seq, frames)
                            elif seq != first[0] and frames > first[1]:
                                return {'alive': True, 'seq': seq, 'frames': frames,
                                        'sr': sr, 'nbs': nbs, 'pid': pid}
                    finally:
                        k32.UnmapViewOfFile(v)
            finally:
                k32.CloseHandle(h)
        time.sleep(0.5)
    return {'alive': bool(first), 'first': first}

def cmd_status():
    print('admin:', is_admin())
    v, _ = reg_read(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, TESTENV_VAL)
    print('DisableProtectedAudioDG:', v if v is not None else '(absent=enforced)')
    hb = read_heartbeat(timeout=3)
    print('heartbeat:', hb)
    # COM 注册检查（HKCR 两键）。
    for sub in (r'SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\%s' % OUR_CLSID,
                r'SOFTWARE\Classes\CLSID\%s\InprocServer32' % OUR_CLSID):
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, sub):
                print('reg present:', sub.split('\\')[-2] if 'CLSID' in sub else 'AudioProcessingObjects')
        except OSError:
            print('reg MISSING:', sub)


def cmd_testenv(on):
    v, _ = reg_read(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, TESTENV_VAL)
    print('testenv current:', v)
    os.makedirs(BACKUP_DIR, exist_ok=True)
    if on:
        with open(os.path.join(BACKUP_DIR, 'testenv.json'), 'w', encoding='utf-8') as f:
            json.dump({'DisableProtectedAudioDG': v}, f)
        with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY) as k:
            winreg.SetValueEx(k, TESTENV_VAL, 0, winreg.REG_DWORD, 1)
        print('testenv: set 1 (unsigned APO 可载；重启服务生效）')
    else:
        prev = None
        meta = os.path.join(BACKUP_DIR, 'testenv.json')
        if os.path.exists(meta):
            with open(meta, encoding='utf-8') as f:
                prev = json.load(f).get('DisableProtectedAudioDG')
        if prev is None:
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, 0,
                                    winreg.KEY_SET_VALUE) as k:
                    winreg.DeleteValue(k, TESTENV_VAL)
                print('testenv: value deleted (restore absent)')
            except OSError as ex:
                print('testenv: nothing to restore (%s)' % ex)
        else:
            with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY) as k:
                winreg.SetValueEx(k, TESTENV_VAL, 0, winreg.REG_DWORD, prev)
            print('testenv: restored %s' % prev)
    print('restarting audio...')
    print('audio restart ok:', restart_audio())


def cmd_install(substr, force):
    hits = find_endpoints(substr)
    if not hits:
        die('no endpoint matches %r' % substr)
    if len(hits) > 1:
        print('ambiguous:')
        for e in hits:
            print('  %s %s' % (e['id'], e.get('name')))
        die('refine substring')
    ep = hits[0]
    name = ep.get('name') or ''
    if not force and 'voicemeeter' not in name.lower() and 'virtual' not in name.lower():
        die('refusing physical endpoint without --force: %s' % name)
    direction = ep['direction']
    short = short_guid(ep['id'])
    print('target: %s %s' % (direction, name))
    # 0. COM 注册（缺则 regsvr32；幂等）。
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                            r'SOFTWARE\Classes\CLSID\%s\InprocServer32' % OUR_CLSID):
            print('com: already registered')
    except OSError:
        print('com: registering...')
        r = sh(['regsvr32', '/s', DLL])
        if r.returncode != 0:
            die('regsvr32 failed rc=%d' % r.returncode)
    # 1. 备份。
    meta = backup_fx(direction, ep['id'])
    # 2. 写 SFX+EFX（不动其它槽；缺省 ProcessingModes 补默认；删 DisableEnhancements）。
    fx = '%s\\%s\\%s\\FxProperties' % (MM_BASE, direction.title(), short)
    reg_write_sz(winreg.HKEY_LOCAL_MACHINE, fx, FX_BASE + ',5', OUR_CLSID)
    reg_write_sz(winreg.HKEY_LOCAL_MACHINE, fx, FX_BASE + ',7', OUR_CLSID)
    print('installed SFX+EFX slots')
    for slot in ('5', '6', '7'):
        v, t = reg_read(winreg.HKEY_LOCAL_MACHINE, fx, '%s,%s' % (PROC_MODES, slot))
        if v is None:
            with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, fx) as k:
                winreg.SetValueEx(k, '%s,%s' % (PROC_MODES, slot), 0,
                                  winreg.REG_MULTI_SZ, [DEFAULT_MODE])
            print('processingModes ,%s: added default' % slot)
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, fx, 0, winreg.KEY_SET_VALUE) as k:
            winreg.DeleteValue(k, '%s,5' % DISABLE_ENH)
        print('DisableEnhancements deleted (force enhancements on)')
    except OSError:
        pass
    # 3. 重启 + 心跳握手。
    print('restarting audio...')
    if not restart_audio():
        die('audio restart failed; Fx backup at %s' % BACKUP_DIR)
    hb = read_heartbeat(timeout=20)
    print('heartbeat:', hb)
    if not hb.get('alive'):
        print('WARN: heartbeat silent (unsigned refused? testenv-on first?). Fx backup kept.')
    else:
        print('INSTALL OK: APO processing (seq advancing)')


def cmd_uninstall():
    meta = latest_meta()
    if not meta:
        die('no backup found in %s' % BACKUP_DIR)
    print('restoring:', meta)
    if not restore_fx(meta):
        die('restore failed')
    print('restarting audio...')
    restart_audio()
    hb = read_heartbeat(timeout=5)
    print('heartbeat after uninstall (expect absent):', hb)


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help', 'help'):
        print(__doc__)
        return 0
    verb = argv[1]
    if verb == 'status':
        return cmd_status() or 0
    if verb not in ('testenv-on', 'testenv-off', 'install', 'uninstall',
                    'verify-heartbeat'):
        print(__doc__)
        return 2
    if not is_admin():
        die('admin required for %s' % verb)
    if '--yes' not in argv:
        die('refusing without --yes (system mutation)')
    if verb == 'testenv-on':
        cmd_testenv(True)
    elif verb == 'testenv-off':
        cmd_testenv(False)
    elif verb == 'install':
        if len(argv) < 3 or argv[2].startswith('--'):
            die('usage: install <name-substring> --yes [--force]')
        cmd_install(argv[2], '--force' in argv)
    elif verb == 'uninstall':
        cmd_uninstall()
    elif verb == 'verify-heartbeat':
        print(read_heartbeat(timeout=int(argv[argv.index('--timeout') + 1])
                             if '--timeout' in argv else 15))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
