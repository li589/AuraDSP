#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apo_config.py — AuraAPO 端点安装/注册表原子保护/卸载/服务重启与心跳握手。

设计参考：
  - EqualizerAPO: Child APO 注册表隔离机制 (HKLM\\SOFTWARE\\AuraDSP\\Child APOs\\{guid})、
    !KEY / !VALUE 哨兵语义、复合还原。
  - virtual-surround-sound: ,0 关联 (PKEY_FX_Association)、,13/,14 复合槽 (Composite MULTI_SZ)、
    AudioEndpointBuilder + Audiosrv 重启同步、LPAC 权限穿透。
  - ViPER4Windows: 原子双向心跳检测 (AuraAPO_Heartbeat)。

安全守则：
  - 关键操作必须保护注册表：变更前先落双层备份（注册表 Child APOs 快照 + 磁盘 .reg/.json 文件）。
  - 卸载按快照精确还原原始厂商 APO（Realtek/Dolby/Intel等），绝不破坏系统音频。
  - 支持 Windows 10/11 复合槽模式 (--mode composite)，实现与现有 OEM APO 和谐共存。
  - 支持 UAC 自提权 (--elevate) 与机器可读 JSON 输出 (--json)。
"""
import ctypes
import json
import os
import re
import subprocess
import sys
import time
import winreg

if sys.platform == 'win32' and hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


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
NULL_GUID = '{00000000-0000-0000-0000-000000000000}'

MM_BASE = r'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
CHILD_APO_ROOT = r'SOFTWARE\AuraDSP\Child APOs'
TESTENV_KEY = r'SOFTWARE\Microsoft\Windows\CurrentVersion\Audio'
TESTENV_VAL = 'DisableProtectedAudioDG'

SENTINEL_NOKEY = '!KEY'
SENTINEL_NOVALUE = '!VALUE'

ALL_SLOT_KEYS = [
    FX_BASE + ',0',   # PKEY_FX_Association
    FX_BASE + ',1',   # LFX
    FX_BASE + ',2',   # GFX
    FX_BASE + ',5',   # SFX
    FX_BASE + ',6',   # MFX
    FX_BASE + ',7',   # EFX
    FX_BASE + ',13',  # Composite Multi-SFX (Win10 1803+)
    FX_BASE + ',14',  # Composite Multi-MFX (Win10 1803+)
    FX_BASE + ',15',  # Composite Multi-EFX
    DISABLE_ENH + ',5',
    PROC_MODES + ',5',
    PROC_MODES + ',6',
    PROC_MODES + ',7',
]


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def run_elevated():
    """重新拉起自身以请求 Windows UAC 管理员权限。"""
    script = os.path.abspath(__file__)
    py_exe = sys.executable or 'python'
    # 移除 --elevate 避免递归
    args = [a for a in sys.argv[1:] if a != '--elevate']
    args_str = ' '.join(f'"{a}"' if ' ' in a else a for a in args)
    cmd = f'Start-Process "{py_exe}" -Verb RunAs -Wait -ArgumentList \'"{script}" {args_str}\''
    r = subprocess.run(['powershell', '-Command', cmd], capture_output=True, text=True)
    sys.exit(r.returncode)


def sh(args, timeout=120):
    return subprocess.run(args, capture_output=True, text=True, errors='replace',
                          timeout=timeout)


def short_guid(long_id):
    if not long_id:
        return ''
    m = re.search(r'\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}', long_id)
    return m.group(0) if m else long_id


def reg_read(root, sub, name):
    try:
        with winreg.OpenKey(root, sub) as k:
            v, t = winreg.QueryValueEx(k, name)
            return v, t
    except OSError:
        return None, None


def ensure_com_registered():
    """保证 AuraApo.dll COM 类和 AudioProcessingObjects 注册表项已正确注册（幂等）。"""
    apo_sub = r'AudioEngine\AudioProcessingObjects\%s' % OUR_CLSID
    clsid_sub = r'CLSID\%s\InprocServer32' % OUR_CLSID
    has_apo, _ = reg_read(winreg.HKEY_CLASSES_ROOT, apo_sub, 'FriendlyName')
    has_clsid, _ = reg_read(winreg.HKEY_CLASSES_ROOT, clsid_sub, '')
    if has_apo and has_clsid:
        return True
    if os.path.exists(DLL):
        sh(['regsvr32', '/s', DLL])
        has_apo, _ = reg_read(winreg.HKEY_CLASSES_ROOT, apo_sub, 'FriendlyName')
        has_clsid, _ = reg_read(winreg.HKEY_CLASSES_ROOT, clsid_sub, '')
        return bool(has_apo and has_clsid)
    return False


def find_endpoints(substr=''):
    """使用 apo_inspect.exe 获取系统所有活跃音频端点。"""
    exe = os.path.join(OUT, 'Release', 'apo_inspect.exe')
    if not os.path.exists(exe):
        exe = os.path.join(OUT, 'apo_inspect.exe')
    if not os.path.exists(exe):
        return []
    r = sh([exe])
    if r.returncode != 0:
        return []
    try:
        d = json.loads(r.stdout.strip().splitlines()[-1])
        endpoints = d.get('endpoints', [])
        if not substr:
            return endpoints
        sub = substr.lower()
        return [e for e in endpoints
                if sub in (e.get('name') or '').lower()
                or sub in (e.get('friendlyName') or '').lower()
                or sub in (e.get('id') or '').lower()]
    except Exception:
        return []


def get_installed_child_apos():
    """列出当前已在 HKLM\\SOFTWARE\\AuraDSP\\Child APOs 挂载的端点。"""
    installed = []
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, CHILD_APO_ROOT) as root_key:
            num_subkeys = winreg.QueryInfoKey(root_key)[0]
            for i in range(num_subkeys):
                guid = winreg.EnumKey(root_key, i)
                sub_path = f'{CHILD_APO_ROOT}\\{guid}'
                info = {'short_guid': guid}
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, sub_path) as k:
                    num_vals = winreg.QueryInfoKey(k)[1]
                    for j in range(num_vals):
                        vn, vv, _ = winreg.EnumValue(k, j)
                        info[vn] = vv
                installed.append(info)
    except OSError:
        pass
    return installed


def backup_endpoint(ep, mode='sfx-efx'):
    """双层备份：写入 HKLM\\SOFTWARE\\AuraDSP\\Child APOs\\{guid} + 导出 .reg/.json。"""
    long_id = ep['id']
    direction = ep['direction'].title()
    short = short_guid(long_id)
    fx_sub = f'{MM_BASE}\\{direction}\\{short}\\FxProperties'
    child_sub = f'{CHILD_APO_ROOT}\\{short}'
    stamp = time.strftime('%Y%m%d_%H%M%S')
    os.makedirs(BACKUP_DIR, exist_ok=True)

    had_key = False
    slot_snapshot = {}

    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, fx_sub) as k:
            had_key = True
            for key_name in ALL_SLOT_KEYS:
                try:
                    val, val_type = winreg.QueryValueEx(k, key_name)
                    slot_snapshot[key_name] = {'val': val, 'type': val_type}
                except OSError:
                    slot_snapshot[key_name] = {'val': SENTINEL_NOVALUE, 'type': winreg.REG_SZ}
    except OSError:
        had_key = False
        for key_name in ALL_SLOT_KEYS:
            slot_snapshot[key_name] = {'val': SENTINEL_NOKEY, 'type': winreg.REG_SZ}

    # 1. 写入注册表 Child APOs 快照
    with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, child_sub) as k:
        winreg.SetValueEx(k, 'Version', 0, winreg.REG_SZ, '1')
        winreg.SetValueEx(k, 'EndpointId', 0, winreg.REG_SZ, long_id)
        winreg.SetValueEx(k, 'DeviceName', 0, winreg.REG_SZ, ep.get('name') or ep.get('friendlyName') or '')
        winreg.SetValueEx(k, 'Direction', 0, winreg.REG_SZ, direction)
        winreg.SetValueEx(k, 'InstallMode', 0, winreg.REG_SZ, mode)
        winreg.SetValueEx(k, 'HadFxPropertiesKey', 0, winreg.REG_DWORD, 1 if had_key else 0)
        winreg.SetValueEx(k, 'BackupTimestamp', 0, winreg.REG_SZ, stamp)

        for kn, info in slot_snapshot.items():
            val = info['val']
            val_type = info['type']
            if isinstance(val, list):
                winreg.SetValueEx(k, kn, 0, winreg.REG_MULTI_SZ, val)
            elif isinstance(val, int):
                winreg.SetValueEx(k, kn, 0, winreg.REG_DWORD, val)
            else:
                winreg.SetValueEx(k, kn, 0, winreg.REG_SZ, str(val))

    # 2. 导出磁盘 .reg 和 .json 快照（双重安全防护）
    safe_name = ''.join(c if c.isalnum() else '_' for c in short)[:16]
    reg_file = os.path.join(BACKUP_DIR, f'fx_{safe_name}_{stamp}.reg')
    json_file = os.path.join(BACKUP_DIR, f'fx_{safe_name}_{stamp}.json')

    if had_key:
        sh(['reg', 'export', f'HKLM\\{fx_sub}', reg_file, '/y'])

    meta = {
        'endpoint': long_id,
        'short_guid': short,
        'direction': direction,
        'had_key': had_key,
        'reg_file': reg_file if had_key and os.path.exists(reg_file) else None,
        'backup_at': stamp,
        'install_mode': mode,
        'slots': {k: v['val'] for k, v in slot_snapshot.items()}
    }
    with open(json_file, 'w', encoding='utf-8') as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    return meta


def restore_endpoint(short_id):
    """从注册表快照精确还原指定端点，若注册表快照缺失则回退到磁盘快照。"""
    child_sub = f'{CHILD_APO_ROOT}\\{short_id}'
    stored_info = {}

    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, child_sub) as k:
            num_vals = winreg.QueryInfoKey(k)[1]
            for i in range(num_vals):
                vn, vv, vt = winreg.EnumValue(k, i)
                stored_info[vn] = {'val': vv, 'type': vt}
    except OSError:
        pass

    # 若注册表未存，尝试从磁盘 JSON 文件匹配
    if not stored_info and os.path.isdir(BACKUP_DIR):
        cands = [os.path.join(BACKUP_DIR, f) for f in os.listdir(BACKUP_DIR)
                 if f.startswith('fx_') and f.endswith('.json')]
        for c in sorted(cands, reverse=True):
            try:
                with open(c, encoding='utf-8') as f:
                    d = json.load(f)
                    if d.get('short_guid') == short_id or short_id in d.get('endpoint', ''):
                        stored_info = {
                            'Direction': {'val': d.get('direction', 'Render'), 'type': winreg.REG_SZ},
                            'HadFxPropertiesKey': {'val': 1 if d.get('had_key') else 0, 'type': winreg.REG_DWORD},
                            'InstallMode': {'val': d.get('install_mode', 'sfx-efx'), 'type': winreg.REG_SZ},
                        }
                        for sk, sv in d.get('slots', {}).items():
                            stored_info[sk] = {'val': sv, 'type': winreg.REG_MULTI_SZ if isinstance(sv, list) else winreg.REG_SZ}
                        break
            except Exception:
                continue

    if not stored_info:
        return False, f"未找到端点 {short_id} 的备份数据"

    direction = stored_info.get('Direction', {}).get('val', 'Render')
    had_key = stored_info.get('HadFxPropertiesKey', {}).get('val', 1) == 1
    install_mode = stored_info.get('InstallMode', {}).get('val', 'sfx-efx')
    fx_sub = f'{MM_BASE}\\{direction}\\{short_id}\\FxProperties'

    if not had_key:
        # !KEY：原来不存在 FxProperties，直接删除该子键
        try:
            winreg.DeleteKey(winreg.HKEY_LOCAL_MACHINE, fx_sub)
        except OSError:
            pass
    else:
        # 逐槽恢复原始值
        try:
            with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, fx_sub) as k:
                if install_mode == 'composite':
                    # 复合槽：从 ,13/,14 的 MULTI_SZ 列表中移除 OUR_CLSID
                    for slot in (FX_BASE + ',13', FX_BASE + ',14'):
                        orig_val = stored_info.get(slot, {}).get('val')
                        if orig_val in (SENTINEL_NOKEY, SENTINEL_NOVALUE, None):
                            try:
                                winreg.DeleteValue(k, slot)
                            except OSError:
                                pass
                        elif isinstance(orig_val, list):
                            clean_list = [x for x in orig_val if x.upper() != OUR_CLSID.upper()]
                            if clean_list:
                                winreg.SetValueEx(k, slot, 0, winreg.REG_MULTI_SZ, clean_list)
                            else:
                                try:
                                    winreg.DeleteValue(k, slot)
                                except OSError:
                                    pass
                else:
                    # 经典槽：还原各个具体槽位
                    for kn in ALL_SLOT_KEYS:
                        if kn not in stored_info:
                            continue
                        info = stored_info[kn]
                        val = info['val']

                        if val in (SENTINEL_NOKEY, SENTINEL_NOVALUE):
                            try:
                                winreg.DeleteValue(k, kn)
                            except OSError:
                                pass
                        elif isinstance(val, list):
                            winreg.SetValueEx(k, kn, 0, winreg.REG_MULTI_SZ, val)
                        elif isinstance(val, int):
                            winreg.SetValueEx(k, kn, 0, winreg.REG_DWORD, val)
                        elif isinstance(val, str):
                            winreg.SetValueEx(k, kn, 0, winreg.REG_SZ, val)
        except OSError as ex:
            return False, f"写入 FxProperties 失败: {ex}"

    # 清理注册表 Child APO 快照记录
    try:
        winreg.DeleteKey(winreg.HKEY_LOCAL_MACHINE, child_sub)
    except OSError:
        pass

    # 若 Child APOs 已经没有子键，清理根项
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, CHILD_APO_ROOT) as k:
            if winreg.QueryInfoKey(k)[0] == 0:
                winreg.DeleteKey(winreg.HKEY_LOCAL_MACHINE, CHILD_APO_ROOT)
    except OSError:
        pass

    return True, f"端点 {short_id} 恢复完成"


def restart_audio():
    """重启 AudioEndpointBuilder + Audiosrv（依赖倒序起停，刷新属性缓存）。"""
    # 1. 停止 Audiosrv
    deps = []
    r = sh(['sc', 'enumdepend', 'Audiosrv'])
    for line in (r.stdout or '').splitlines():
        line = line.strip()
        if line.startswith('SERVICE_NAME:'):
            deps.append(line.split(':', 1)[1].strip())

    for svc in deps:
        sh(['sc', 'stop', svc], timeout=15)
    sh(['sc', 'stop', 'Audiosrv'], timeout=20)
    time.sleep(1)

    # 2. 停止 AudioEndpointBuilder 以清除端点属性存储缓存
    sh(['sc', 'stop', 'AudioEndpointBuilder'], timeout=20)
    time.sleep(1)

    # 3. 倒序启动 AudioEndpointBuilder -> Audiosrv -> 依赖服务
    r = sh(['sc', 'start', 'AudioEndpointBuilder'], timeout=25)
    if r.returncode != 0:
        time.sleep(2)
        sh(['sc', 'start', 'AudioEndpointBuilder'], timeout=25)

    time.sleep(1)
    r = sh(['sc', 'start', 'Audiosrv'], timeout=25)
    if r.returncode != 0:
        time.sleep(2)
        r = sh(['sc', 'start', 'Audiosrv'], timeout=25)

    time.sleep(1)
    for svc in deps:
        sh(['sc', 'start', svc], timeout=15)

    return r.returncode == 0


def read_heartbeat(timeout=5):
    """读取 Global\\AuraAPO_Heartbeat 共享映射（魔数/版本/seq递增校验）。"""
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
    import struct

    while time.time() < deadline:
        h = k32.OpenFileMappingW(0x0004, False, 'Global\\AuraAPO_Heartbeat')
        if h:
            try:
                v = k32.MapViewOfFile(h, 0x0004, 0, 0, 32)
                if v:
                    try:
                        raw = ctypes.string_at(v, 32)
                        magic, ver, seq, sr, frames, nbs, pid = struct.unpack('<IIIIQII', raw)
                        if magic == 0x41554248 and ver == 1:
                            if first is None:
                                first = (seq, frames)
                            elif seq != first[0] and frames >= first[1]:
                                return {
                                    'alive': True,
                                    'seq': seq,
                                    'frames': frames,
                                    'sr': sr,
                                    'nbs': nbs,
                                    'pid': pid
                                }
                    finally:
                        k32.UnmapViewOfFile(v)
            finally:
                k32.CloseHandle(h)
        time.sleep(0.3)

    return {'alive': bool(first), 'first': first}


def cmd_status(as_json=False, timeout=None):
    admin = is_admin()
    v, _ = reg_read(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, TESTENV_VAL)
    hb_timeout = 0.4 if (timeout is None and as_json) else (timeout if timeout is not None else 1.5)
    hb = read_heartbeat(timeout=hb_timeout)
    installed = get_installed_child_apos()

    apo_reg, _ = reg_read(winreg.HKEY_CLASSES_ROOT,
                          r'AudioEngine\AudioProcessingObjects\%s' % OUR_CLSID,
                          'FriendlyName')
    clsid_reg, _ = reg_read(winreg.HKEY_CLASSES_ROOT,
                            r'CLSID\%s\InprocServer32' % OUR_CLSID, '')

    data = {
        'admin': admin,
        'testenv': v,
        'heartbeat': hb,
        'com_registered': bool(apo_reg and clsid_reg),
        'installed_endpoints': installed,
    }

    if as_json:
        print(json.dumps(data, ensure_ascii=False))
        return 0

    print("=== AuraDSP System APO 状态报告 ===")
    print(f"管理员权限: {admin}")
    print(f"未签名驱动加载环境 (DisableProtectedAudioDG): {v if v is not None else '(absent=enforced)'}")
    print(f"COM 组件注册: {'已就绪' if data['com_registered'] else '未注册'}")
    print(f"实时音频心跳: {'活跃处理中' if hb.get('alive') else '静默 (无音频流或未激活)'}")
    if hb.get('alive'):
        print(f"  采样率={hb.get('sr')}Hz, 序列号={hb.get('seq')}, 累计帧数={hb.get('frames')}, audiodg_PID={hb.get('pid')}")
    print(f"已挂载端点数: {len(installed)}")
    for ep in installed:
        print(f"  - [{ep.get('Direction', 'Render')}] {ep.get('DeviceName', '未知')} ({ep.get('short_guid')}) 模式:{ep.get('InstallMode')}")
    return 0


def cmd_install(substr, mode='sfx-efx', force=False, as_json=False):
    if not is_admin():
        if as_json:
            print(json.dumps({'ok': False, 'error': 'admin_required'}))
            return 1
        print("FATAL: 安装 System APO 需要管理员权限。请使用管理员身份运行或加 --elevate 参数。")
        return 1

    hits = find_endpoints(substr)
    if not hits:
        msg = f"未找到匹配 '{substr}' 的音频端点"
        if as_json:
            print(json.dumps({'ok': False, 'error': 'no_endpoint', 'message': msg}))
        else:
            print(f"FATAL: {msg}")
        return 1

    if len(hits) > 1:
        msg = f"匹配到多个端点 ({len(hits)}个)，请提供更精确的名称子串"
        if as_json:
            print(json.dumps({'ok': False, 'error': 'ambiguous', 'message': msg, 'candidates': hits}))
        else:
            print(f"FATAL: {msg}:")
            for h in hits:
                print(f"  - {h.get('name')} (ID: {h.get('id')})")
        return 1

    ep = hits[0]
    name = ep.get('name') or ep.get('friendlyName') or ''
    is_virtual = ('voicemeeter' in name.lower()) or ('virtual' in name.lower()) or ('cable' in name.lower())
    if not is_virtual and not force:
        msg = f"目标为物理声卡设备 '{name}'。为保护系统原生驱动，必须显式指定 --force 才能挂载"
        if as_json:
            print(json.dumps({'ok': False, 'error': 'physical_device_requires_force', 'message': msg}))
        else:
            print(f"WARN: {msg}")
        return 2

    # 1. 确保 COM 注册就绪
    ensure_com_registered()

    # 2. 确保 DisableProtectedAudioDG = 1（未签名 DLL 能够被 audiodg 加载）
    v, _ = reg_read(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, TESTENV_VAL)
    if v != 1:
        with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY) as k:
            winreg.SetValueEx(k, TESTENV_VAL, 0, winreg.REG_DWORD, 1)

    # 3. 执行双层原子备份（注册表 Child APOs + 磁盘文件）
    meta = backup_endpoint(ep, mode=mode)

    # 4. 挂载 APO 到目标设备 FxProperties
    direction = ep['direction'].title()
    short = short_guid(ep['id'])
    fx_sub = f'{MM_BASE}\\{direction}\\{short}\\FxProperties'

    with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, fx_sub) as k:
        # PKEY_FX_Association 关联 GUID 必须为全零 GUID
        winreg.SetValueEx(k, FX_BASE + ',0', 0, winreg.REG_SZ, NULL_GUID)

        if mode == 'composite':
            # 复合槽挂载（Win10 1803+ 规范：追加到 MULTI_SZ 列表中，不覆盖现有 OEM APO）
            for slot_key in (FX_BASE + ',13', FX_BASE + ',14'):
                existing_list, _ = reg_read(winreg.HKEY_LOCAL_MACHINE, fx_sub, slot_key)
                if isinstance(existing_list, list):
                    if OUR_CLSID not in existing_list:
                        existing_list.append(OUR_CLSID)
                else:
                    existing_list = [OUR_CLSID]
                winreg.SetValueEx(k, slot_key, 0, winreg.REG_MULTI_SZ, existing_list)
        elif mode == 'sfx-only':
            winreg.SetValueEx(k, FX_BASE + ',5', 0, winreg.REG_SZ, OUR_CLSID)
        else:
            # 默认全链路拓扑挂载：SFX (,5) + MFX (,6) + EFX (,7)
            winreg.SetValueEx(k, FX_BASE + ',5', 0, winreg.REG_SZ, OUR_CLSID)
            winreg.SetValueEx(k, FX_BASE + ',6', 0, winreg.REG_SZ, OUR_CLSID)
            winreg.SetValueEx(k, FX_BASE + ',7', 0, winreg.REG_SZ, OUR_CLSID)

        # 补齐默认信号处理模式支持 (DEFAULT PROCESSING MODE)
        for slot in ('5', '6', '7'):
            pm_key = f'{PROC_MODES},{slot}'
            cur_modes, _ = reg_read(winreg.HKEY_LOCAL_MACHINE, fx_sub, pm_key)
            if not cur_modes or DEFAULT_MODE not in cur_modes:
                winreg.SetValueEx(k, pm_key, 0, winreg.REG_MULTI_SZ, [DEFAULT_MODE])

        # 删除 DisableEnhancements 标志（强制系统启用音频增强）
        try:
            winreg.DeleteValue(k, f'{DISABLE_ENH},5')
        except OSError:
            pass

    # 5. 重启系统音频服务以生效
    restart_ok = restart_audio()

    result = {
        'ok': True,
        'endpoint_id': ep['id'],
        'short_guid': short,
        'name': name,
        'mode': mode,
        'backup': meta,
        'audio_restarted': restart_ok
    }
    if as_json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(f"成功将 AuraAPO 挂载到 '{name}' ({short})")
        print(f"挂载模式: {mode}, 音频服务重启: {'成功' if restart_ok else '重试中'}")
    return 0


def cmd_uninstall(target=None, as_json=False):
    if not is_admin():
        if as_json:
            print(json.dumps({'ok': False, 'error': 'admin_required'}))
            return 1
        print("FATAL: 卸载 System APO 需要管理员权限。请使用管理员身份运行或加 --elevate 参数。")
        return 1

    installed = get_installed_child_apos()
    if not installed:
        msg = "未发现任何挂载了 AuraAPO 的端点"
        if as_json:
            print(json.dumps({'ok': True, 'restored': [], 'message': msg}))
        else:
            print(msg)
        return 0

    to_restore = []
    if not target or target.lower() in ('all', '*'):
        to_restore = installed
    else:
        target_sub = target.lower()
        to_restore = [ep for ep in installed
                      if target_sub in ep.get('short_guid', '').lower()
                      or target_sub in ep.get('DeviceName', '').lower()
                      or target_sub in ep.get('EndpointId', '').lower()]

    if not to_restore:
        msg = f"未找到匹配 '{target}' 的已安装端点"
        if as_json:
            print(json.dumps({'ok': False, 'error': 'not_found', 'message': msg}))
        else:
            print(f"WARN: {msg}")
        return 1

    restored_list = []
    for ep in to_restore:
        short = ep['short_guid']
        ok, msg = restore_endpoint(short)
        restored_list.append({'short_guid': short, 'ok': ok, 'message': msg})

    # 若所有端点均已卸载，清理全局未签名驱动开关
    rem = get_installed_child_apos()
    if not rem:
        testenv_backup = os.path.join(BACKUP_DIR, 'testenv.json')
        prev = None
        if os.path.exists(testenv_backup):
            try:
                with open(testenv_backup, encoding='utf-8') as f:
                    prev = json.load(f).get('DisableProtectedAudioDG')
            except Exception:
                pass
        if prev is None:
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, 0, winreg.KEY_SET_VALUE) as k:
                    winreg.DeleteValue(k, TESTENV_VAL)
            except OSError:
                pass
        else:
            with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY) as k:
                winreg.SetValueEx(k, TESTENV_VAL, 0, winreg.REG_DWORD, prev)

    restart_ok = restart_audio()

    result = {
        'ok': True,
        'restored': restored_list,
        'audio_restarted': restart_ok,
        'remaining_count': len(get_installed_child_apos())
    }
    if as_json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        for r in restored_list:
            print(f"还原结果: {r['short_guid']} -> {r['message']}")
        print(f"音频服务重启: {'成功' if restart_ok else '失败'}")
    return 0


def main(argv):
    if '--elevate' in argv and not is_admin():
        run_elevated()
        return 0

    as_json = '--json' in argv

    if len(argv) < 2 or argv[1] in ('-h', '--help', 'help'):
        if as_json:
            print(json.dumps({'error': 'help_requested'}))
        else:
            print(__doc__)
        return 0

    verb = argv[1].lower()

    if verb == 'status':
        timeout = None
        if '--timeout' in argv:
            try:
                timeout = float(argv[argv.index('--timeout') + 1])
            except Exception:
                pass
        return cmd_status(as_json=as_json, timeout=timeout)

    if verb == 'verify-heartbeat':
        timeout = 5
        if '--timeout' in argv:
            try:
                timeout = float(argv[argv.index('--timeout') + 1])
            except Exception:
                pass
        hb = read_heartbeat(timeout=timeout)
        if as_json:
            print(json.dumps(hb, ensure_ascii=False))
        else:
            print("心跳检测结果:", hb)
        return 0

    if verb == 'testenv-on':
        if not is_admin():
            print("FATAL: 需要管理员权限")
            return 1
        with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY) as k:
            winreg.SetValueEx(k, TESTENV_VAL, 0, winreg.REG_DWORD, 1)
        restart_audio()
        if as_json:
            print(json.dumps({'ok': True, 'DisableProtectedAudioDG': 1}))
        else:
            print("已启用未签名驱动加载环境 (DisableProtectedAudioDG=1)")
        return 0

    if verb == 'testenv-off':
        if not is_admin():
            print("FATAL: 需要管理员权限")
            return 1
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, TESTENV_KEY, 0, winreg.KEY_SET_VALUE) as k:
                winreg.DeleteValue(k, TESTENV_VAL)
        except OSError:
            pass
        restart_audio()
        if as_json:
            print(json.dumps({'ok': True, 'DisableProtectedAudioDG': 0}))
        else:
            print("已恢复签名驱动保护策略")
        return 0

    if verb == 'install':
        if len(argv) < 3 or argv[2].startswith('--'):
            print("用法: python apo_config.py install <端点名子串> [--mode sfx-efx|composite|sfx-mfx] [--yes] [--force] [--json]")
            return 2
        if '--yes' not in argv:
            print("FATAL: 修改底层驱动配置需提供 --yes 确认参数")
            return 1
        target = argv[2]
        mode = 'sfx-efx'
        if '--mode' in argv:
            mode = argv[argv.index('--mode') + 1]
        elif '--composite' in argv:
            mode = 'composite'
        return cmd_install(target, mode=mode, force=('--force' in argv), as_json=as_json)

    if verb == 'uninstall':
        if '--yes' not in argv:
            print("FATAL: 卸载底层驱动配置需提供 --yes 确认参数")
            return 1
        target = None
        if len(argv) > 2 and not argv[2].startswith('--'):
            target = argv[2]
        return cmd_uninstall(target=target, as_json=as_json)

    print(f"未知子命令: {verb}")
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
