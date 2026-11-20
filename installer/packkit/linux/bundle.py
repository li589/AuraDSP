"""Linux bundle 的校验、加工与收尾（对应原 pack.sh 的 62–102 行）。

三件事按固定顺序做，顺序本身是有原因的：

  1. **校验原 bundle**——在任何复制之前拒绝残包。原实现先 cp 再查，坏
     bundle 会白拷几百 MB。
  2. **复制到 out 下的临时副本再加工**——资源合并会删目录、写文件，直接
     加工 `build/linux/.../bundle` 会污染构建产物，下次打包要重新
     `flutter build`。副本放 `--out` 下（同一文件系统，cp 不做跨盘拷贝）。
  3. **资源档位 → 默认层**——顺序不可颠倒：`--resources none` 会删掉
     `resources/`，而默认层写的是 `defaults/`，互不影响；但默认层生成器
     会跑 `flutter test`，放在资源合并之后可以保证「合并失败就不必再花
     几分钟跑测试」。
"""

from __future__ import annotations

import shutil
import tempfile
from contextlib import contextmanager
from pathlib import Path

from ..common import die, log
from ..defaults import apply_defaults
from ..paths import LINUX_BUNDLE, LINUX_BUNDLE_REQUIRED, PACKS_DIR
from ..resources import apply_resources

# 缺件时的提示语（逐条与原 pack.sh 对齐：CI 与排障手册按这些句子检索）
_HINTS = {
    "auradsp_app": "bundle 不完整（缺 auradsp_app）",
    "lib/libauradsp_engine.so": "bundle 缺引擎 libauradsp_engine.so（先跑 sync_artifacts）",
    "lib/plugin_host_x64": "bundle 缺 plugin_host_x64",
    "lib/plugin_host_x86": "bundle 缺 plugin_host_x86（32 位桥）；"
                           "构建引擎时需 AURADSP_BUILD_HOST_X86=ON",
}


def check_bundle(bundle: Path) -> None:
    """四件载荷缺一即拒打包（2026-11-10 起 32 位桥不再降级为警告）。"""
    if not bundle.is_dir():
        raise die(f"bundle 目录不存在: {bundle}")
    for rel in LINUX_BUNDLE_REQUIRED:
        target = bundle / rel
        # auradsp_app 要求可执行；库文件只要求存在（权限由打包时规范化）
        ok = target.is_file() and (rel != "auradsp_app" or target.stat().st_mode & 0o111)
        if not ok:
            raise die(f"{_HINTS[rel]}（路径: {target}）")


@contextmanager
def staged_bundle(bundle: Path, out_dir: Path, resources: str,
                  packs_dir: Path, what_if: bool):
    """产出加工好的 bundle 目录；退出时清理临时副本。

    what-if 下不复制，直接返回原 bundle（仅供 --what-if 的清单推演）。
    """
    bundle = bundle or LINUX_BUNDLE
    check_bundle(bundle)
    log(f"bundle: {bundle}")
    log(f"out:    {out_dir}")

    if what_if:
        log("what-if: 跳过 staging 副本与资源合并")
        yield bundle
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(dir=out_dir, prefix=".pack-staging."))
    try:
        work = stage_root / "bundle"
        shutil.copytree(bundle, work, symlinks=True)
        apply_resources(work, resources, packs_dir, what_if=False)
        log(f"resources: 档位 {resources}（已在 staging 副本合并）")
        apply_defaults(work, what_if=False, strict=False)
        yield work
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


def default_packs_dir() -> Path:
    return PACKS_DIR
