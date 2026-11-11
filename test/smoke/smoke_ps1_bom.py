# smoke_ps1_bom.py — 随包 PowerShell 脚本 BOM 编码门禁
# （资源计划 Stage 0 / §8.4 定罪，2026-11-12）。
#
# pack.py 生成的 register_asio.ps1 旧实现以无 BOM 的 UTF-8 落盘，
# 脚本内含中文字符串；PowerShell 5.1 对无 BOM 的 .ps1 按系统
# ANSI（中文 Windows = GBK）解码，字节错位吞掉字符串结束引号，
# 解析期 ParserError（TerminatorExpectedAtEndOfString）——脚本
# 永不执行，ASIO 注册/反注册在中文 Windows 上双向恒失败、状态
# 永不改变（开发机实测复现）。随包 install_vaio.ps1 同为无 BOM
# + 大量中文，靠字节运气未爆。
#
# 本门纯 Python、两平台可跑，钉三件事：
#   1. 随包 .ps1 源文件（向导模板 + 驱动侧安装/注册脚本）必须
#      带 UTF-8 BOM，或全文纯 ASCII（PS 5.1 两种都安全）；
#   2. pack.py 生成 register_asio.ps1 的落盘路径必须字节级补
#      BOM（源码断言），模板 .ps1 拷贝路径同理；
#   3. 打包产物若在场（dist staging），其 driver/*.ps1 实测带
#      BOM（不在场则 SKIP 该项，不假绿）。
import os
import sys

try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BOM = b"\xef\xbb\xbf"

SHIPPED_PS1 = [
    "installer/windows/custom_installer/driver/install_vaio.ps1",
    "core/desktop/windows-drivers/01_vaio_driver/install_driver.ps1",
    "core/desktop/windows-drivers/04_asio_driver/register_driver.ps1",
]

failures = []
checks = 0


def check(ok, label):
    global checks
    checks += 1
    if not ok:
        failures.append(label)
    print(("PASS " if ok else "FAIL ") + label)


def bom_or_ascii(path):
    data = open(path, "rb").read()
    if data.startswith(BOM):
        return True
    return all(b < 0x80 for b in data)


for rel in SHIPPED_PS1:
    p = os.path.join(ROOT, rel)
    check(os.path.isfile(p), f"随包脚本存在: {rel}")
    if os.path.isfile(p):
        check(bom_or_ascii(p), f"BOM 或纯 ASCII: {rel}")

pack_src = open(os.path.join(ROOT, "installer/windows/pack.py"),
                encoding="utf-8").read()
check('b"\\xef\\xbb\\xbf" + REGISTER_ASIO_PS1.encode("utf-8")' in pack_src,
      "pack.py: register_asio.ps1 字节级补 BOM 落盘")
check('name.lower().endswith(".ps1")' in pack_src,
      "pack.py: 模板 .ps1 拷贝路径含 BOM 补齐分支")

staging = os.path.join(ROOT, "dist", "AuraDSP-Windows-x64", "driver")
if os.path.isdir(staging):
    for name in os.listdir(staging):
        if name.lower().endswith(".ps1"):
            check(bom_or_ascii(os.path.join(staging, name)),
                  f"staging 产物带 BOM: driver/{name}")
else:
    print("SKIP staging 产物检查（dist staging 不在场）")

print(f"--- {checks - len(failures)}/{checks} checks passed ---")
if failures:
    print("FAILED:", *failures, sep="\n  ")
    sys.exit(1)
print("ALL OK")
