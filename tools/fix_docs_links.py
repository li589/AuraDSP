#!/usr/bin/env python3
"""P0 docs 重组：修复跨文档相对链接（映射表驱动，幂等，可反复跑）。

规则（所有搬迁都恰好深一层：docs/f -> docs/XX/f）：
  1. 裸 basename（在搬迁表）：root 文件 -> `XX/base`；同目录 -> `base`；他目录 -> `../XX/base`
  2. `sub/base.md`（无前导 ../）：已搬迁文件 -> 加一层 `../`；root 文件不动
  3. `../x`：已搬迁文件 -> 加一层 `../../x`；root 文件不动（../AGENT.md 等合法）
http/#/mailto 原样保留。
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, 'docs')

MOVED = {
    '项目初衷.md': '00-总览', '产品架构总览.md': '00-总览', '项目架构与开发规范.md': '00-总览',
    'APP-架构与设计方案.md': '10-架构', 'APP-插件与信号图扩展规划.md': '10-架构',
    'UI-六页架构与M3.5重排序方案.md': '10-架构', 'M0-Android音频政策专项调研.md': '10-架构',
    'Windows通用底层音频驱动与四模式架构方案-2026-10-13.md': '10-架构',
    '外置参数持久化记忆与预设系统v2方案.md': '10-架构',
    '音频资产盘点与资源包构建实施方案-2026-10-11.md': '10-架构',
    'AuraDSP_UI设计规范与交互标准手册.md': '10-架构', 'source-参考项目审理报告.md': '10-架构',
    'UI与音频效果深度重构与体验优化方案.md': '10-架构',
    '插件宿主重构与状态总览-2026-10-11.md': '10-架构',
    '插件模块深度改良方案-2026-10-12.md': '10-架构',
    'UI交互精细化整改与问题修复开工Spec-2026-10-13.md': '20-执行',
    '串扰消除卡片与混响热修复开工Spec-2026-10-13.md': '20-执行',
    '代码审查与整改Spec-2026-10-13.md': '20-执行',
    '任意响应EQ开工Spec-2026-10-13.md': '20-执行',
    '蝰蛇系三效果器开工Spec-2026-10-13.md': '20-执行',
    'UI优化与视觉统一性实施方案-2026-10-11.md': '20-执行',
    '用户痛点深度重构与后续演进实施计划-2026-10-11.md': '20-执行',
    '用户反馈问题修复计划-2026-10-10.md': '20-执行',
    'Spike2-AIDL效果库验证报告.md': '30-审查',
    'VDC-资源线与加载链路体检报告-2026-10-12.md': '30-审查',
    '代码审查报告-2026-10-12.md': '30-审查',
    '全天代码审查报告-2026-10-12.md': '30-审查',
    '全天代码审计计划-2026-10-12.md': '30-审查',
    '代码审查计划-2026-10-12.md': '30-审查',
    '相关组件设计逻辑与复用审查报告-2026-10-12.md': '30-审查',
    '脚本页面与脚本功能检查升级报告-2026-10-13.md': '30-审查',
    'EasyEffects×Viper效果器差距分析-2026-10-13.md': '30-审查',
    'UI自动化测试基建与经验沉淀.md': '30-审查',
    '阶段性回顾-2026-10-09.md': '40-回顾',
    '阶段性回顾-2026-10-10.md': '40-回顾',
}

link_re = re.compile(r'\]\(([^)]+)\)')


def fix_file(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    rel = os.path.relpath(path, DOCS).replace('\\', '/')
    curdir = os.path.dirname(rel)  # '' = docs 根
    moved = curdir != ''
    changed = 0

    def repl(mo):
        nonlocal changed
        target = mo.group(1)
        if target.startswith(('http://', 'https://', '#', 'mailto:')):
            return mo.group(0)
        if not target.endswith('.md'):
            return mo.group(0)
        # 先剥掉全部前导 ../（自愈之前跑坏的 ../../），再按当前位置重算
        stripped = target
        while stripped.startswith('../'):
            stripped = stripped[3:]
        # 先剥掉全部前导 ../（自愈之前跑坏的 ../../），再逐级试存在性
        stripped = target
        while stripped.startswith('../'):
            stripped = stripped[3:]
        base = os.path.basename(stripped)
        cands = []
        if base in MOVED:
            # 搬迁文件：语义位置优先（存在性可能被旧残留误导）
            dest = MOVED[base]
            if curdir == '':
                cands.append(f'{dest}/{base}')
            elif curdir == dest:
                cands.append(base)
            else:
                cands.append(f'../{dest}/{base}')
        # 存在性级联：原样 -> 上跳一级 -> 上跳两级
        cands.extend([stripped, f'../{stripped}', f'../../{stripped}'])
        here = os.path.join(DOCS, curdir) if curdir else DOCS
        for cand in cands:
            if os.path.exists(os.path.normpath(os.path.join(here, cand))):
                if cand != target:
                    changed += 1
                    return f']({cand})'
                return mo.group(0)
        return mo.group(0)  # 都不存在：不动（可能是外部/待补）

    new_text = link_re.sub(repl, text)
    if changed:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_text)
    return changed


total = 0
files = []
for dp, _, fl in os.walk(DOCS):
    for fn in fl:
        if fn.endswith('.md'):
            files.append(os.path.join(dp, fn))
for p in sorted(files):
    c = fix_file(p)
    if c:
        print(f'  {os.path.relpath(p, ROOT)}: {c}')
        total += c
print(f'total fixed: {total}')
