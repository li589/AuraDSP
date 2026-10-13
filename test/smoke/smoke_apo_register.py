"""smoke_apo_register.py — 自研 APO 注册往返验收。

验收标准（机器无关）：
  1. AuraApo.dll 存在；PE 导出表含 DllCanUnloadNow/DllGetClassObject/
     DllRegisterServer/DllUnregisterServer（纯 Python 解析，无需 dumpbin）。
  2. 非管理员 → 记 note 跳过注册往返（改系统状态，非提权不碰）。
  3. 管理员 → regsvr32 注册→断言 HKCR 两键→反注册→断言键消失（自清洁）。
"""
import ctypes
import os
import struct
import subprocess
import sys
import winreg

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'AuraApo.dll')
CLSID = '{415AD8ED-7A45-4F4F-AC69-043830EBC174}'

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


def pe_exports(path):
    """最小 PE 导出表解析（PE32+ DLL），返回导出名集合。

    数据目录基址取 optsize-128（本工具链实测；dumpbin 交叉验证），
    并回退试 +96（规范值），以结构校验（名数/地址/ASCII）裁定，防链接器 quirk。
    """
    with open(path, 'rb') as f:
        data = f.read()
    if data[0:2] != b'MZ':
        return set()
    pe_off = struct.unpack('<I', data[0x3C:0x40])[0]
    if data[pe_off:pe_off + 4] != b'PE\x00\x00':
        return set()
    num_sec = struct.unpack('<H', data[pe_off + 6:pe_off + 8])[0]
    opt_off = pe_off + 24
    magic = struct.unpack('<H', data[opt_off:opt_off + 2])[0]
    if magic != 0x20B:
        return set()
    opt_size = struct.unpack('<H', data[pe_off + 20:pe_off + 22])[0]
    secoff = opt_off + opt_size
    secs = []
    for i in range(num_sec):
        o = secoff + i * 40
        vsz, vaddr, rawsz, rawptr = struct.unpack('<IIII', data[o + 8:o + 24])
        secs.append((vaddr, max(vsz, rawsz), rawptr))
    image_end = max(v + s for v, s, _ in secs)


    def raw(rva):
        for vaddr, span, rawptr in secs:
            if vaddr <= rva < vaddr + span:
                return rawptr + (rva - vaddr)
        return None


    def try_base(dd_off):
        exp_rva = struct.unpack('<I', data[dd_off:dd_off + 4])[0]
        base = raw(exp_rva)
        if base is None:
            return None
        n_names = struct.unpack('<I', data[base + 24:base + 28])[0]
        if not (0 < n_names <= 512):
            return None
        addr_names = struct.unpack('<I', data[base + 32:base + 36])[0]
        names = set()
        for i in range(n_names):
            p = raw(addr_names + i * 4)
            if p is None:
                return None
            rva = struct.unpack('<I', data[p:p + 4])[0]
            q = raw(rva)
            if q is None:
                return None
            end = data.find(b'\x00', q)
            if end < 0 or end - q > 256:
                return None
            try:
                nm = data[q:end].decode('ascii')
            except UnicodeDecodeError:
                return None
            if not nm or not all(c.isprintable() or c == '_' for c in nm):
                return None
            names.add(nm)
        return names

    for dd_off in (opt_off + opt_size - 128, opt_off + 96):
        names = try_base(dd_off)
        if names:
            return names
    return set()


check('AuraApo.dll exists', os.path.exists(DLL), DLL)
if not os.path.exists(DLL):
    print('APOREG FAILURES:', FAIL)
    sys.exit(1)

exps = pe_exports(DLL)
for fn in ('DllCanUnloadNow', 'DllGetClassObject', 'DllRegisterServer',
           'DllUnregisterServer'):
    check('exports %s' % fn, fn in exps)

is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
if not is_admin:
    print('NOTE not admin: skip regsvr32 round-trip (system mutation)')
else:
    apo_key = r'SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\%s' % CLSID
    clsid_key = r'SOFTWARE\Classes\CLSID\%s\InprocServer32' % CLSID

    def key_exists(sub):
        try:
            k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, sub)
            winreg.CloseKey(k)
            return True
        except OSError:
            return False

    r = subprocess.run(['regsvr32', '/s', DLL], capture_output=True, timeout=120)
    check('regsvr32 register rc=0', r.returncode == 0, 'rc=%d' % r.returncode)
    check('AudioProcessingObjects key present', key_exists(apo_key))
    check('CLSID InprocServer32 present', key_exists(clsid_key))
    r = subprocess.run(['regsvr32', '/s', '/u', DLL], capture_output=True, timeout=120)
    check('regsvr32 unregister rc=0', r.returncode == 0, 'rc=%d' % r.returncode)
    check('APO key gone', not key_exists(apo_key))
    check('CLSID key gone', not key_exists(clsid_key))

print()
if FAIL:
    print('APOREG FAILURES:', FAIL)
    sys.exit(1)
print('apo_register: all checks passed')
