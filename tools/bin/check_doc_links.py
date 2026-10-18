#!/usr/bin/env python3
"""check_doc_links.py - AuraDSP 文档相对链接检查。

范围：
  - 根目录 README.md / AGENT.md / CLAUDE.md
  - docs/ 下所有 .md（跳过第三方只读镜像 docs/参考技术手册/ 与 forensics 原始材料）
  - engine/AGENT.md、core/desktop/windows-drivers/README.md

规则：
  - 只检查 markdown 行内链接与图片链接的相对路径；
  - 跳过 http(s)://、mailto:、纯锚点；
  - 支持 file:/// 绝对路径（去掉 #Lxx 片段后按本地路径检查）；
  - 跳过 fenced code block 内的示例链接；
  - 不检查锚点是否存在（跨文件 #anchor 只校验文件）。
"""
from __future__ import annotations

import os
import re
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCS = os.path.join(ROOT, "docs")
EXTRA = [
    os.path.join(ROOT, "README.md"),
    os.path.join(ROOT, "AGENT.md"),
    os.path.join(ROOT, "CLAUDE.md"),
    os.path.join(ROOT, "engine", "AGENT.md"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "README.md"),
]
SKIP_DIRS = {"参考技术手册", "android_guides_cn", "forensics"}
LINK_RE = re.compile(r"(!?\[[^\]]*\]\()([^)]+)(\))")


def iter_markdown():
    for path in EXTRA:
        if os.path.isfile(path):
            yield path
    for dirpath, dirs, files in os.walk(DOCS):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            if fn.lower().endswith(".md"):
                yield os.path.join(dirpath, fn)


def strip_code_fences(text: str) -> str:
    out = []
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else line)
    return "\n".join(out)


def resolve(src: str, raw: str):
    raw = raw.strip()
    if raw.startswith(("http://", "https://", "mailto:", "#")):
        return None
    if raw.startswith("file:///"):
        target = urllib.parse.unquote(raw[8:]).replace("/", "\\")
        return os.path.normpath(re.split(r"#", target)[0])
    target = urllib.parse.unquote(raw.split("#", 1)[0].strip())
    if not target:
        return None
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    return os.path.normpath(os.path.join(os.path.dirname(src), target))


def main() -> int:
    missing = []
    checked = 0
    for src in iter_markdown():
        try:
            text = open(src, encoding="utf-8").read()
        except OSError as exc:
            print(f"[READFAIL] {src}: {exc}")
            continue
        for m in LINK_RE.finditer(strip_code_fences(text)):
            raw = m.group(2)
            dst = resolve(src, raw)
            if dst is None:
                continue
            checked += 1
            if not os.path.exists(dst):
                missing.append((os.path.relpath(src, ROOT), raw, os.path.relpath(dst, ROOT)))

    print(f"checked {checked} relative links; missing {len(missing)}")
    for src, raw, dst in missing:
        print(f"MISSING  {src}  ->  {raw}  ({dst})")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
