"""默认层 `defaults/` 生成（资源计划 Part D）。

生成器是 App 自己的契约测试 `test/defaults_emit_test.dart`：配置默认值由
`AppConfig` 代码本尊导出，生成物与代码默认永不漂移；presets 复制出厂资产。

两条被实证的通道纪律（2026-11-12 开发机）：

1. **产出目录走包根标记文件，不走环境变量**——Windows 上 Python →
   cmd → flutter.bat 的多层包裹会把 `AURADSP_EMIT_DEFAULTS` 弄丢（rc=0
   却不产出，生成器静默跳过）。文件通道确定可达，生成器双通道都认。
2. **stdout 落真实临时文件、不用 PIPE**——管道继承会让 flutter test 的
   测试子进程在加载阶段断连。
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from .common import die, log, warn
from .paths import APP_DIR


def apply_defaults(work_staging: Path, what_if: bool, strict: bool = True) -> bool:
    """生成 `defaults/`，返回是否成功。

    `strict` 区分两平台的历史口径：Windows 发行包必须带默认层（缺即失败），
    Linux 侧一直把缺失降级为警告（App 侧有代码默认兜底，不阻塞打包）。
    默认 True 保持 Windows 行为逐字不变。
    """
    if what_if:
        log("defaults: what-if 跳过生成")
        return True
    flutter = shutil.which("flutter")
    if flutter is None:
        if strict:
            raise die("生成 defaults/ 需要 flutter 在 PATH 中"
                      "（默认层由 App 代码经契约测试导出）")
        warn("无 flutter，跳过 defaults/ 生成（App 回退代码默认）")
        return False

    log("defaults: 经 App 契约测试生成默认层…")
    marker = APP_DIR / ".auradsp_emit_defaults"
    # 必须写绝对路径：work_staging 可能是相对路径（--mode staging 直传
    # args.staging），而生成器进程的 CWD 是 app_dir，相对路径会被解析到
    # 包内、产出落错地方（2026-11-12 实证）。
    marker.write_text(str((work_staging / "defaults").resolve()), encoding="utf-8")
    try:
        with tempfile.TemporaryFile(mode="w+b") as lf:
            r = subprocess.run(
                [flutter, "test", "test/defaults_emit_test.dart"],
                cwd=str(APP_DIR), stdout=lf, stderr=subprocess.STDOUT)
            if r.returncode != 0:
                lf.seek(0)
                tail = "\n".join(
                    lf.read().decode("utf-8", "replace").splitlines()[-15:])
                if strict:
                    raise die(f"defaults 生成失败（flutter test rc={r.returncode}）：\n{tail}")
                warn(f"defaults/ 生成失败（rc={r.returncode}），包将不带默认层")
                return False
    finally:
        marker.unlink(missing_ok=True)

    if not (work_staging / "defaults" / "manifest.json").is_file():
        if strict:
            raise die("defaults 生成未产出 manifest.json")
        warn("defaults 生成未产出 manifest.json，包将不带默认层")
        return False
    log("defaults: 默认层已生成（config.default.json + presets + manifest）")
    return True
