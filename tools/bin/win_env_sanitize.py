#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""win_env_sanitize.py — 归一化 Windows 环境变量里的大小写重复键

背景
----
某些宿主环境（CI 包装器、沙箱代理、多层进程逐层拼接 PATH）会让原生环境块
里同时出现 `PATH` / `path` / `Path` 多个大小写变体。Windows 查找环境变量
本身大小写不敏感，但 **.NET Framework** 的 `ProcessStartInfo.EnvironmentVariables`
内部是 `StringDictionary`（Hashtable + 大小写不敏感比较器），把原生块按原样
灌进去时第二个 "path" 会撞键并抛：

    System.ArgumentException: 已添加项目。字典中的相关关键字: 'path'

这条异常发生在 `ToolTask.GetProcessStartInfo` 内部，于是 **CL.exe 根本没被
拉起**。在 MSBuild 日志里它表现为一条 MSB6001，编译目标既没产出、也**没有**
让上层脚本失败——最坏情况是构建脚本只检查"文件存在"就宣布就绪，
于是**静默产出陈旧二进制**。本仓库就踩过：引擎 DLL 时间戳停在两天前，
而构建脚本打印"核心引擎就绪"。

修法
----
读原生环境块（ctypes `GetEnvironmentStringsW`），先在**双 NUL 终止符处
截断**，再按大小写不敏感合并重复键：

  * 截断（2026-11-11 补修）：探测循环把整段定长缓冲解码后只查「终止符
    存在」却不截断，终止符之后的堆内存被当成环境条目一并解析。堆布局
    benign 时块外恰为零字节、无从察觉；SSH 派生进程里块外是多份环境块
    拷贝等非零残留，幻影条目可达数千条，合并后的环境块超过 CreateProcess
    的 32K 上限，子进程以 `OSError: [WinError 87]` 起不来。解析必须以
    终止符为界（`parse_block`），探测也以字节级对齐扫描为准
    （`find_block_end`）。

  * `PATH` 取所有变体的**并集**（保持出现顺序、去重）——三份取值通常各含
    一部分目录，丢掉任何一份都会让工具链找不到；
  * 其余变量保留**首次出现**的那一份（与 Windows 查找语义一致）。

然后用这份干净环境启动目标命令。合并过程会打印明细，便于事后审计。

用法
----
    python tools/bin/win_env_sanitize.py --report
    python tools/bin/win_env_sanitize.py cmake --build --preset windows-x64-release
    python tools/bin/win_env_sanitize.py --no-merge-path cmake --version
    python tools/bin/win_env_sanitize.py --verbose --log out.log cmake --build ...

    --log FILE   把子进程的**原始字节**写入文件（stdout/stderr 合流）。
                MSBuild 输出可能含非本地代码页字符，经 shell 管道会被转码炸掉
                （UnicodeEncodeError: 'gbk' codec...），直写文件可绕开。
    --verbose    逐条打印合并明细（默认只给摘要，宿主可能复制上百个变量）。

退出码透传子命令的退出码；子命令不存在时返回 127。
"""
import ctypes
import ctypes.wintypes as wintypes
import os
import subprocess
import sys


def find_block_end(data):
    """返回双 NUL 终止符在原始字节中的起始偏移，未找到返回 -1。

    环境块是 UTF-16LE：条目以单个 NUL 字符分隔，块以双 NUL 结尾，
    即字节层的 `00 00 00 00`。该序列也可能在奇数偏移处偶然出现
    （某个字符的低字节为 0x00 等），故只认偶数偏移（字符对齐）。
    块内条目本身不可能含 NUL 字符，所以首个对齐命中即终止符。
    """
    needle = b"\x00\x00\x00\x00"
    pos = 0
    while True:
        idx = data.find(needle, pos)
        if idx < 0:
            return -1
        if idx % 2 == 0:
            return idx
        pos = idx + 1


def parse_block(data):
    """把原生环境块字节解析为 (name, value) 列表，保持出现顺序。

    在双 NUL 终止符处截断——终止符之后的字节是进程堆上的残留内存，
    不是环境内容（2026-11-11 定罪：未截断时 SSH 派生进程里幻影条目
    可达数千条，合并环境块超 32K 后 CreateProcess 报 WinError 87）。
    无终止符时按整段解析（read_raw_block 的探测循环保证调用前已确认
    终止符在缓冲内；整段解析只作防御性兜底）。
    """
    end = find_block_end(data)
    if end >= 0:
        data = data[:end]
    text = data.decode("utf-16-le", errors="replace")
    entries = []
    for chunk in text.split("\x00"):
        if not chunk:
            continue
        name, sep, value = chunk.partition("=")
        entries.append((name, value if sep else ""))
    return entries


def read_raw_block():
    """返回原生环境块里的 (name, value) 列表，保持出现顺序。"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    # 必须用 c_void_p 接收：wintypes.LPWSTR 是 c_wchar_p，ctypes 会把它
    # 直接转成 Python 字符串，丢掉指针语义，后面再 wstring_at 就会炸。
    k32.GetEnvironmentStringsW.restype = ctypes.c_void_p
    k32.GetEnvironmentStringsW.argtypes = []
    k32.FreeEnvironmentStringsW.restype = ctypes.c_int
    k32.FreeEnvironmentStringsW.argtypes = [ctypes.c_void_p]

    ptr = k32.GetEnvironmentStringsW()
    if not ptr:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        # 原生块是 UTF-16、以双 NUL 结尾；wstring_at 会在首个 NUL 处截断，
        # 必须整块拷出来再切分。但环境块没有公开长度，一次性读太大会在
        # 块尾越界触发访问违例，所以按块探测：缓冲内出现双 NUL 终止符
        # 即止，越界就折半重来。注意缓冲会大于真实块长，终止符之后的
        # 字节是堆残留，解析时由 parse_block 截断，绝不能一并切分
        # （旧实现只查存在、不截断，幻影条目由此而来）。
        size = 65536
        while True:
            try:
                raw = ctypes.create_string_buffer(size)
                ctypes.memmove(raw, ptr, size)
                data = raw.raw
            except OSError:
                size //= 2
                if size < 4096:
                    raise
                continue
            if find_block_end(data) >= 0:
                break
            size *= 2
            if size > (1 << 22):
                raise RuntimeError("环境块长度探测失败（超过 4MB 上限）")
    finally:
        k32.FreeEnvironmentStringsW(ptr)

    return parse_block(data)


def split_path(value):
    return [p for p in value.split(";") if p]


def merge_entries(entries, merge_path=True):
    """返回 (干净环境 dict, 合并明细 list)。"""
    order = []
    merged = {}
    detail = []

    for name, value in entries:
        key = name.upper()
        if key not in merged:
            merged[key] = value
            order.append(key)
            continue

        if key == "PATH" and merge_path:
            seen = split_path(merged[key])
            extra = []
            for p in split_path(value):
                if p.lower() not in {s.lower() for s in seen}:
                    seen.append(p)
                    extra.append(p)
            if extra:
                merged[key] = ";".join(seen)
                detail.append("PATH 变体 %s 追加 %d 个目录" % (name, len(extra)))
            else:
                detail.append("PATH 变体 %s 无新增目录" % name)
        else:
            detail.append("变量 %s 重复，保留首次出现的值" % name)

    env = {}
    for key in order:
        env[key] = merged[key]

    # 连带关闭 MSBuild 节点复用：脏环境下启动的 worker 节点会在内存里存活
    # 约 15 分钟，之后的构建即便环境已修好，也会复用这些"带病"的节点，
    # 表现为 **cmake 立即以 exit=1 失败且没有任何输出**（比首个错误更难查）。
    # 关掉节点复用后每次构建都用干净的编译器进程。
    env["MSBUILDDISABLENODEREUSE"] = "1"
    return env, detail


def report():
    entries = read_raw_block()
    counts = {}
    for name, _ in entries:
        counts.setdefault(name.upper(), []).append(name)
    dups = {k: v for k, v in counts.items() if len(v) > 1}
    print("原生环境块条目数: %d" % len(entries))
    if not dups:
        print("无大小写重复键 —— 环境本已干净")
        return 0
    print("发现 %d 组大小写重复键:" % len(dups))
    for k, v in dups.items():
        print("  %s -> %s" % (k, ", ".join(v)))
    env, detail = merge_entries(entries)
    print("合并明细:")
    for d in detail:
        print("  - %s" % d)
    print("清理后 PATH 前 120 字符: %s" % env.get("PATH", "")[:120])
    return 1


def resolve_command(argv, env):
    """在 PATH + PATHEXT 下解析可执行文件。

    Windows 的 CreateProcess 只在搜索 PATH 时补 `.exe`，而 `flutter` 这类
    工具是 `.bat` 垫片 —— 直接 spawn 会 FileNotFoundError。Python 的
    subprocess 不做 PATHEXT 展开，所以这里自己解析：命中 `.bat`/`.cmd`
    就改用 `cmd.exe /d /s /c` 启动。

    返回 (可执行 argv, 是否为批处理)。
    """
    exe = argv[0]
    if os.path.dirname(exe) or os.path.exists(exe):
        return list(argv), False

    pathext = (env.get("PATHEXT") or ".COM;.EXE;.BAT;.CMD").split(";")
    for d in (env.get("PATH") or "").split(os.pathsep):
        if not d:
            continue
        for ext in pathext:
            cand = os.path.join(d, exe + ext)
            if os.path.isfile(cand):
                return [cand] + list(argv[1:]), ext.upper() in (".BAT", ".CMD")
    return list(argv), False


def run_child(argv, env, log_path):
    """启动子进程；批处理经 cmd.exe 转发。返回退出码。"""
    resolved, is_batch = resolve_command(argv, env)
    if is_batch:
        comspec = env.get("COMSPEC") or "cmd.exe"
        # cmd 的 /c 约定：整条命令行外面再套一层引号，内层路径再套一层，
        # 即 cmd.exe /c ""C:\带空格\flutter.BAT" args"。
        # 不能用 list 形式传参——list2cmdline 会把内层引号再转义成 \"，
        # cmd 会把它当字面量，批处理就找不到。
        quoted = " ".join(subprocess.list2cmdline([a]) for a in resolved[1:])
        cmdline = '"%s" /d /s /c ""%s" %s"' % (comspec, resolved[0], quoted)
        print("[run] 批处理转发: %s" % resolved[0])
        if log_path:
            with open(log_path, "wb") as log:
                proc = subprocess.run(cmdline, shell=True, env=env,
                                      stdout=log, stderr=subprocess.STDOUT)
            print("[log] 已写入 %s" % log_path)
            return proc.returncode
        return subprocess.run(cmdline, shell=True, env=env).returncode

    if log_path:
        with open(log_path, "wb") as log:
            proc = subprocess.run(resolved, env=env, stdout=log,
                                  stderr=subprocess.STDOUT)
        print("[log] 已写入 %s" % log_path)
        return proc.returncode
    return subprocess.run(resolved, env=env).returncode


def main(argv):
    args = argv[1:]
    merge_path = True
    log_path = None
    verbose = False
    while args and args[0].startswith("-"):
        flag = args[0]
        if flag == "--report":
            return report()
        if flag == "--no-merge-path":
            merge_path = False
        elif flag == "--verbose":
            verbose = True
        elif flag == "--log":
            args = args[1:]
            if not args:
                print("--log 需要一个文件路径参数", file=sys.stderr)
                return 2
            log_path = args[0]
        else:
            print("未知参数: %s" % flag, file=sys.stderr)
            return 2
        args = args[1:]
    if not args:
        print(__doc__)
        return 2

    entries = read_raw_block()
    env, detail = merge_entries(entries, merge_path=merge_path)
    # 明细可能上百行（宿主会复制**每个**变量），默认只给摘要，
    # 否则构建日志会被淹没；需要逐条审计时加 --verbose。
    if verbose:
        for d in detail:
            print("[env] %s" % d)
    else:
        n_dup = len(detail)
        print("[env] 已归一化 %d 处大小写重复键（PATH 取并集，其余保留首次值）"
              % n_dup)
    print("[run] argv=%r" % (args,))

    # 日志走原始字节直写：MSBuild 的输出可能含非本地代码页字符，
    # 经 PowerShell 管道会被转码炸掉（UnicodeEncodeError: 'gbk' codec...）。
    try:
        return run_child(args, env, log_path)
    except FileNotFoundError:
        print("命令不存在: %s" % args[0], file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv))
