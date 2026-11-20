"""`--build`：从干净拉取到 bundle 就绪（原 pack.sh 52–61 行）。

四步固定顺序，每步都可能因环境缺件失败，因此逐条给出可执行的修复提示：

  cmake 预设 linux-x64（-DAURADSP_BUILD_HOST_X86=ON，32 位桥是发行必需）
    → cmake --build linux-x64-release
    → flutter build linux --release --no-tree-shake-icons
    → tools/sync_artifacts.py（把引擎 .so 与双宿主同步进 bundle/lib）

两个刻意的口径：

- **必须 `--no-tree-shake-icons`**：项目用动态 IconData，摇树会砍掉图标
  （CLAUDE.md 构建铁律）。
- **sync_artifacts 非零不致命**：它退出码 2 表示「有可选目标被跳过」
  （如 dist 分发目录不存在）。bundle 是否真的完整，以下一步的
  `bundle.check_bundle` 为准，而不是靠 sync 的返回值猜。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from ..common import die, log, warn
from ..paths import APP_DIR, ROOT, SYNC_ARTIFACTS


def _run(cmd: list[str], cwd: Path, what: str) -> None:
    log(f"{what}: {' '.join(cmd)}")
    r = subprocess.run(cmd, cwd=str(cwd))
    if r.returncode != 0:
        raise die(f"{what} 失败（rc={r.returncode}）")


def build_linux() -> None:
    if shutil.which("flutter") is None:
        raise die("找不到 flutter（先安装 Flutter 并加入 PATH）")
    if shutil.which("cmake") is None:
        raise die("找不到 cmake（引擎构建需要，装 cmake + ninja）")

    _run(["cmake", "--preset", "linux-x64", "-DAURADSP_BUILD_HOST_X86=ON"],
         ROOT, "configure")
    _run(["cmake", "--build", "--preset", "linux-x64-release"], ROOT, "engine")
    _run(["flutter", "build", "linux", "--release", "--no-tree-shake-icons"],
         APP_DIR, "flutter bundle")

    # sync 退出码 2 表示有可选目标被跳过，不算失败
    log(f"sync: {SYNC_ARTIFACTS}")
    r = subprocess.run([sys.executable, str(SYNC_ARTIFACTS)], cwd=str(ROOT))
    if r.returncode not in (0, 2):
        raise die(f"sync_artifacts 失败（rc={r.returncode}）")
    if r.returncode == 2:
        warn("sync_artifacts 有跳过项，以 bundle 完整性检查为准")
