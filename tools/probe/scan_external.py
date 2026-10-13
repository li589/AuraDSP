"""scan_external.py — 只读扫描外部插件目录，绝不修改被扫描目录。

用途：把 D:\\myPrograms\\AudioEffect（只读）里的 VST 扫进 AuraDSP 的插件缓存，
供 smoke 与 UI 测试使用。

**硬性约束**：
  - 只读。扫描后校验被扫描目录的文件数与总大小未变，任何写入都会被发现。
  - 缓存写到 %APPDATA%/AuraDSP/plugins/plugin_cache.json，不碰源目录。

用法：
  python tools/probe/scan_external.py --dirs D:\\myPrograms\\AudioEffect\\VST --dry-run
  python tools/probe/scan_external.py --dirs D:\\myPrograms\\AudioEffect\\VST
"""
import argparse
import ctypes
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')
CACHE = os.path.join(os.environ.get('APPDATA', ''), 'AuraDSP', 'plugins',
                     'plugin_cache.json')
JSON_FIELDS = ('id', 'name', 'vendor', 'version', 'category', 'format',
               'path', 'isCompatible', 'errorMessage')


def fingerprint(paths):
    """目录指纹：文件数 + 总字节数 + 最新修改时间。扫描后必须完全一致。"""
    n = 0
    total = 0
    newest = 0.0
    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            continue
        n += 1
        total += st.st_size
        if st.st_mtime > newest:
            newest = st.st_mtime
    return n, total, newest


def scan(extra_dirs, sample_rate=48000.0, block=2048, deep=True):
    lib = ctypes.CDLL(DLL)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_plugin_scan.restype = ctypes.c_int32
    lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_int32]
    lib.auradsp_plugin_get_count.restype = ctypes.c_int32
    lib.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
    lib.auradsp_plugin_get_item.restype = ctypes.c_int32
    lib.auradsp_plugin_get_item.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                            ctypes.c_char_p, ctypes.c_int32]

    handle = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(sample_rate),
                                                ctypes.c_int32(block)))
    if not handle:
        raise RuntimeError('auradsp_create 失败')
    try:
        # 注意：引擎的 extra_dirs 是**分号分隔**的纯路径列表，
        # 不是 JSON 数组（PluginHostManager::scanPlugins 用 getline(..., ';') 解析）。
        # 传 JSON 会让整个数组被当成单个不存在的路径而被静默丢弃。
        dirs_arg = ';'.join(extra_dirs).encode('utf-8')
        lib.auradsp_plugin_scan(handle, dirs_arg, 1 if deep else 0)
        count = lib.auradsp_plugin_get_count(handle)
        buf = ctypes.create_string_buffer(65536)
        out = []
        for i in range(count):
            if lib.auradsp_plugin_get_item(handle, i, buf, 65536) <= 0:
                continue
            try:
                raw = json.loads(buf.value.decode('utf-8', 'replace'))
            except ValueError:
                continue
            out.append({k: raw.get(k) for k in JSON_FIELDS})
        return out
    finally:
        lib.auradsp_destroy(handle)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dirs', nargs='*', default=[],
                    help='额外的只读插件目录')
    ap.add_argument('--dry-run', action='store_true', help='只报告，不写缓存')
    ap.add_argument('--sample-rate', type=float, default=48000.0)
    ap.add_argument('--block', type=int, default=2048)
    ap.add_argument('--shallow', action='store_true',
                    help='不递归子目录（快，但会漏掉分层安装的插件）')
    args = ap.parse_args()

    if not os.path.exists(DLL):
        print('找不到引擎 DLL：%s' % DLL)
        return 1
    missing = [d for d in args.dirs if not os.path.isdir(d)]
    if missing:
        print('目录不存在：%s' % ', '.join(missing))
        return 1

    before = {}
    for d in args.dirs:
        before[d] = fingerprint(
            [os.path.join(r, f)
             for r, _, fs in os.walk(d) for f in fs])

    items = scan(args.dirs, args.sample_rate, args.block, deep=not args.shallow)
    ok = [i for i in items if i.get('isCompatible')]
    mono_hint = [i for i in items
                 if i.get('isCompatible') and '(mono)' in (i.get('name') or '').lower()]

    print('扫描到 %d 个插件，兼容 %d 个' % (len(items), len(ok)))
    by_fmt = {}
    for i in ok:
        by_fmt[i.get('format')] = by_fmt.get(i.get('format'), 0) + 1
    print('按格式：%s' % by_fmt)
    if mono_hint:
        print('monо 插件候选（可用于覆盖 m_inChannels==1 分支）：')
        for i in mono_hint[:10]:
            print('  %s  <- %s' % (i.get('name'), i.get('path')))

    # 只读校验：被扫描目录必须一字未动
    changed = []
    for d in args.dirs:
        after = fingerprint(
            [os.path.join(r, f)
             for r, _, fs in os.walk(d) for f in fs])
        if after != before[d]:
            changed.append((d, before[d], after))
    if changed:
        for d, b, a in changed:
            print('[FAIL] 目录被修改！%s\n  before=%s\n  after =%s'
                  % (d, b, a))
        return 2
    print('只读校验通过：%d 个目录均未被修改' % len(args.dirs))

    if args.dry_run:
        print('（--dry-run，未写缓存）')
        return 0

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, 'w', encoding='utf-8') as f:
        json.dump({'plugins': items}, f, ensure_ascii=False, indent=2)
    print('已写入缓存：%s（%d 条）' % (CACHE, len(items)))
    return 0


if __name__ == '__main__':
    sys.exit(main())