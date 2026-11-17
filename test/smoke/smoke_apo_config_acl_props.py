"""smoke_apo_config_acl_props.py — r43 两缺陷的源码形状门禁（纯源码，两平台可跑）。

背景（2026-11-17 宾机实证定罪）：r42 的 APO 附加在宾机上先报
endpoint_props_failed、随后全机无声。两根因都在 apo_config.cpp：

  1. ACL 接管整表替换：TakeOwnershipRepair 以
     SetEntriesInAclW(2, ea, nullptr, ...) 构建全新 DACL 并
     RegSetKeySecurity 整表替换端点键/FxProperties 键的 DACL，
     把 Audiosrv / AudioEndpointBuilder / TrustedInstaller 等
     服务 ACE 全部剥掉。被接管的端点恰为系统默认端点时，音频
     引擎读不到其端点键 → GetDefault 报 NOT_FOUND、所有端点
     建图失败 → 全机无声（托盘红叉、设置有列表但放不出声）。
  2. props 删除误判：WriteEndpointProps 的 clear 路径删除本就
     不存在的 pid3/pid4 值，ERROR_FILE_NOT_FOUND 被当作失败，
     使 r42 起恒传 clear 的附加必报 endpoint_props_failed。

本门禁钉住修复后的不变量（源码形状，防回归）：
  A. 全文件任何 SetEntriesInAclW 调用都不得以 nullptr 作原
     DACL 参数（整表替换即红）。
  B. TakeOwnershipRepair 必须先 RegGetKeySecurity 读回原
     DACL，并以合并方式 SetEntriesInAclW(2, ea, oldDacl, ...)。
  C. WriteEndpointProps 必须把删值的 ERROR_FILE_NOT_FOUND
     映射为 ERROR_SUCCESS。
  D. 反向自检：把缺陷 1/2 的旧写法样本喂给检查器，必须判红
     （防检查器本身失效假绿）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers',
                   '03_system_apo', 'apo_config.cpp')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name +
          ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


def func_body(text, sig):
    """取函数体：自签名行起至下一处顶格 '}' + 段落注释分隔。"""
    i = text.find(sig)
    if i < 0:
        return ''
    j = text.find('\n}\n', i)
    return text[i:j] if j > i else text[i:]


def acl_replace_offenders(text):
    """返回以 nullptr 作原 DACL 的 SetEntriesInAclW 调用处数。"""
    bad = 0
    for m in re.finditer(r'SetEntriesInAclW\s*\(', text):
        seg = text[m.start():m.start() + 120]
        # 第三个参数（原 DACL）若为 nullptr 即整表替换。
        args = seg[seg.find('(') + 1:]
        parts = [p.strip() for p in args.split(',')]
        if len(parts) >= 3 and parts[2].startswith('nullptr'):
            bad += 1
    return bad


def main():
    with open(SRC, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    check('A 无 SetEntriesInAclW(nullptr 原 DACL) 整表替换',
          acl_replace_offenders(text) == 0,
          'found %d' % acl_replace_offenders(text))

    body = func_body(text, 'bool TakeOwnershipRepair(const std::wstring& fxSub) {')
    check('B1 TakeOwnershipRepair 在场', bool(body))
    check('B2 接管前 RegGetKeySecurity 读回原 DACL',
          'RegGetKeySecurity' in body)
    check('B3 接管以合并方式授予（oldDacl 入参）',
          'SetEntriesInAclW(2, ea, oldDacl' in body)

    wbody = func_body(text, 'int WriteEndpointProps(const Endpoint& ep, bool clearAll,')
    check('C1 WriteEndpointProps 在场', bool(wbody))
    check('C2 props clear 删除不存在值视为成功',
          'ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS' in wbody)

    # D 反向自检：旧写法样本必须被检查器判红。
    bad_sample = ('bool TakeOwnershipRepair(const std::wstring& s) {\n'
                  '    SetEntriesInAclW(2, ea, nullptr, &dacl);\n}\n')
    check('D1 反向自检：整表替换样本判红',
          acl_replace_offenders(bad_sample) == 1)
    bad_body = func_body(bad_sample, 'bool TakeOwnershipRepair')
    check('D2 反向自检：无读回原 DACL 判红',
          'RegGetKeySecurity' not in bad_body)

    print('RESULT: ' + ('FAIL (%d)' % len(FAIL) if FAIL else 'PASS'))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
