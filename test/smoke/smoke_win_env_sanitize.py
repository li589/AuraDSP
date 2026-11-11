# smoke_win_env_sanitize.py — win_env_sanitize 环境块截断门禁
# （2026-11-11 定罪修复）。
#
# tools/bin/win_env_sanitize.py 旧实现读原生环境块时只查「双 NUL
# 终止符存在」却不截断，终止符之后的堆残留被当成环境条目解析：
# SSH 派生进程里幻影条目实测 350–4378 条，合并环境块超 CreateProcess
# 的 32K 上限后子进程以 WinError 87 起不来（build_windows.ps1 与
# pack.py 向导构建均中招；交互会话堆布局 benign 故长期未暴露）。
#
# 本门纯 Python、两平台可跑：read_raw_block 依赖 Win32 API 无法在
# Linux 执行，故把字节→条目的解析（parse_block / find_block_end）
# 以合成缓冲实测，并以源码断言钉住 read_raw_block 走截断路径。
import importlib.util
import os
import sys

# Windows 控制台多为 cp1252：放宽 print 编码（同门族纪律）。
try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOD_PATH = os.path.join(ROOT, 'tools', 'bin', 'win_env_sanitize.py')


def load_module():
    spec = importlib.util.spec_from_file_location('win_env_sanitize', MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_block(entries):
    """按原生布局拼环境块字节：条目以单 NUL 分隔、双 NUL 结尾。"""
    text = '\x00'.join('%s=%s' % (k, v) for k, v in entries)
    return text.encode('utf-16-le') + b'\x00\x00\x00\x00'


def main():
    fails = []

    def check(cond, label):
        if cond:
            print('  ok: %s' % label)
        else:
            fails.append(label)
            print('  FAIL: %s' % label)

    mod = load_module()

    real = [('Path', 'C:\\Windows;C:\\Tools'),
            ('AURADSP_REAL', '1'),
            ('OS', 'Windows_NT')]
    block = build_block(real)

    # 1) 终止符之后堆残留（另一份块拷贝 + 幻影条目）不得被解析。
    garbage = build_block([('PHANTOM', 'x'),
                           ('PATH', 'C:\\phantom'),
                           ('AURADSP_REAL', '2')])
    garbage += b'\x01\x02\x03\x04' * 64
    entries = mod.parse_block(block + garbage)
    check(entries == real,
          'parse_block truncates at terminator (got %r)' % (entries,))

    # 2) 净化结果不得带幻影：PATH 不含 phantom、条目数与真值一致，
    #    合并环境块长度在 CreateProcess 32K 上限内。
    env, _detail = mod.merge_entries(entries)
    check('PHANTOM' not in env, 'merged env has no PHANTOM key')
    check('phantom' not in env.get('PATH', ''),
          'merged PATH has no phantom dir')
    check(env.get('AURADSP_REAL') == '1',
          'first occurrence wins for non-PATH dup (AURADSP_REAL=1)')
    block_chars = sum(len(k) + len(v) + 2 for k, v in env.items()) + 1
    check(block_chars <= 32767,
          'merged env block within 32K limit (%d chars)' % block_chars)

    # 3) 大小写重复键的既有语义不变：PATH 取并集、其余保留首次值。
    dup = [('Path', 'C:\\a;C:\\b'), ('PATH', 'C:\\b;C:\\c'),
           ('Temp', 'one'), ('TEMP', 'two')]
    env2, _ = mod.merge_entries(mod.parse_block(build_block(dup)))
    check(env2.get('PATH') == 'C:\\a;C:\\b;C:\\c',
          'PATH variants merged as union (got %r)' % env2.get('PATH'))
    check(env2.get('TEMP') == 'one', 'non-PATH dup keeps first value')

    # 4) find_block_end 只认偶数偏移（字符对齐）：奇数偏移的同形
    #    字节序列不得误判为终止符；无终止符返回 -1。
    odd_first = b'\xff' + b'\x00\x00\x00\x00' + b'\xff' + b'\x00\x00\x00\x00'
    check(mod.find_block_end(odd_first) == 6,
          'find_block_end skips odd-offset match (got %d)'
          % mod.find_block_end(odd_first))
    check(mod.find_block_end(b'\x41\x00\x42\x00') == -1,
          'find_block_end returns -1 without terminator')
    check(mod.find_block_end(block) == len(block) - 4,
          'find_block_end locates real terminator')

    # 5) 无终止符时按整段解析（防御性兜底口径钉住，防静默改义）。
    bare = 'ONLY=1'.encode('utf-16-le')
    check(mod.parse_block(bare) == [('ONLY', '1')],
          'parse_block without terminator parses whole buffer')

    # 6) 源码接线：read_raw_block 必须经 find_block_end 探测 +
    #    parse_block 截断（Linux 上无法实跑 Win32 路径，以此钉住）。
    with open(MOD_PATH, encoding='utf-8') as f:
        src = f.read()
    check('find_block_end(data) >= 0' in src,
          'read_raw_block probes with find_block_end')
    check('return parse_block(data)' in src,
          'read_raw_block returns parse_block(data)')

    if fails:
        print('smoke_win_env_sanitize: FAIL (%d)' % len(fails))
        return 1
    print('smoke_win_env_sanitize: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
