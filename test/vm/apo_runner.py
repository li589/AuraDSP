# -*- coding: utf-8 -*-
"""ASCII-safe wrapper for apo_config on VMs (ssh codepage bypass).

Usage:
  python apo_runner.py endpoints
  python apo_runner.py install  \\u626c\\u58f0\\u5668   (escaped substring, real unicode inside)
  python apo_runner.py uninstall \\u626c\\u58f0\\u5668
  python apo_runner.py heartbeat
All non-ASCII output is backslash-escaped so ssh transport stays clean.
"""
import sys, json, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import apo_config as ac


def esc(s):
    if s is None:
        return ''
    if isinstance(s, bytes):
        s = s.decode('utf-8', 'replace')
    return s.encode('ascii', 'backslashreplace').decode('ascii')


def dec(arg):
    """Decode a \\uXXXX-escaped ASCII argument into real unicode."""
    return arg.encode('ascii', 'backslashreplace').decode('unicode_escape')


def main():
    if len(sys.argv) < 2:
        print('usage: endpoints|install|uninstall|heartbeat ...')
        return 2
    cmd = sys.argv[1]
    if cmd == 'endpoints':
        out = []
        for e in ac.find_endpoints():
            out.append({
                'dir': e.get('dir'),
                'name': esc(e.get('name')),
                'friendly': esc(e.get('friendlyName')),
                'id': esc((e.get('id') or '')[:48]),
            })
        print(json.dumps(out, ensure_ascii=True))
        return 0
    if cmd in ('install', 'uninstall'):
        if len(sys.argv) < 3:
            print(json.dumps({'ok': False, 'error': 'missing_substr'}))
            return 2
        sub = dec(sys.argv[2])
        force = '--force' in sys.argv
        mode = 'sfx-efx'
        if '--mode' in sys.argv:
            mode = sys.argv[sys.argv.index('--mode') + 1]
        if cmd == 'install':
            r = ac.cmd_install(sub, mode=mode, force=force, as_json=True)
        else:
            r = ac.cmd_uninstall(sub, as_json=True)
        print(esc(r) if isinstance(r, str) else json.dumps(r, ensure_ascii=True, default=esc))
        return 0
    if cmd == 'heartbeat':
        r = ac.read_heartbeat(float(sys.argv[2]) if len(sys.argv) > 2 else 5)
        print(json.dumps(r, ensure_ascii=True, default=esc))
        return 0
    print(json.dumps({'ok': False, 'error': 'unknown_cmd:' + esc(cmd)}))
    return 2


if __name__ == '__main__':
    sys.exit(main())
