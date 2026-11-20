"""便携包 `AuraDSP-v<ver>-x86_64.AppImage`（规格：03 §3）。

三条铁律都在这一个文件里执行，改任何一条都会破坏发行合规：

1. **工具链钉版**：appimagetool 与 type2 runtime 的版本 + SHA256 写在
   `appimage/tools.pins`，运行时逐个校验；缺文件才下载，下载后必须校验
   通过才 `chmod +x`。禁止用 rolling 的 continuous 版本。
2. **不捆绑宿主音频栈**：AppDir 里出现 `libpulse*` / `libasound*` 立即中止
   ——音频必须走目标机自己的 PulseAudio/PipeWire 套接字，否则音量控制与
   虚拟声卡重定向全部失效（03 §1）。
3. **runtime 显式指定**：`--runtime-file` 传本地校验过的 runtime，不依赖
   工具内置的旧 runtime。

与原 shell 实现的两处差异（都是有意的）：

- 下载用标准库 `urllib` 而非 `curl`：少一个外部依赖，且能给出明确的
  HTTP 错误码；坏文件校验失败后**删除**，避免坏缓存长期潜伏。
- `ARCH=x86_64` 仍显式传入：AppDir 里带 i386 载荷（32 位桥），
  appimagetool 不显式给 ARCH 会拒绝打包。
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..common import die, log
from ..paths import ICONS_DIR, LINUX_APPRUN, LINUX_SHARED, LINUX_TOOLS_PINS
from . import perms, textio

# 内容铁律：这些前缀一律不得出现在 AppDir 内
FORBIDDEN_PREFIXES = ("libpulse", "libasound")

USER_AGENT = "auradsp-pack/1.0 (+https://github.com/li589/AuraDSP)"


@dataclass(frozen=True)
class PinnedTool:
    name: str
    version: str
    sha256: str
    url: str


def read_pins(pins: Path | None = None) -> dict[str, PinnedTool]:
    """解析 tools.pins：`<name> <version> <sha256> <url>`，`#` 开头为注释。"""
    path = pins or LINUX_TOOLS_PINS
    if not path.is_file():
        raise die(f"工具钉版表缺失: {path}")
    out: dict[str, PinnedTool] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 4:
            raise die(f"tools.pins 第 {lineno} 行格式错误（需 4 列）: {raw!r}")
        name, version, sha, url = parts
        if len(sha) != 64:
            raise die(f"tools.pins 第 {lineno} 行 SHA256 长度不是 64: {sha!r}")
        out[name] = PinnedTool(name, version, sha.lower(), url)
    return out


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp, \
                tmp.open("wb") as out:
            shutil.copyfileobj(resp, out, 1 << 20)
    except urllib.error.HTTPError as exc:
        tmp.unlink(missing_ok=True)
        raise die(f"下载失败 HTTP {exc.code}: {url}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        tmp.unlink(missing_ok=True)
        raise die(f"下载失败（{exc}）: {url}\n"
                  "  离线环境请预先按 tools.pins 把文件放入缓存目录") from exc
    tmp.replace(dest)


def fetch_pinned(tool: PinnedTool, cache_dir: Path) -> Path:
    """确保缓存里有校验通过的工具，返回其路径。"""
    cache_dir.mkdir(parents=True, exist_ok=True)
    dest = cache_dir / Path(tool.url).name
    if not dest.is_file():
        log(f"downloading {tool.name} {tool.version} …")
        _download(tool.url, dest)
    actual = _sha256(dest)
    if actual != tool.sha256:
        # 删掉坏文件：留着会让每次构建都失败且难以自愈
        dest.unlink(missing_ok=True)
        raise die(f"{tool.name} SHA256 校验失败（期望 {tool.sha256}，"
                  f"实际 {actual}）；已删除坏缓存 {dest}")
    perms.make_executable(dest)
    log(f"tool ok: {tool.name} {tool.version} (sha256 verified)")
    return dest


def check_no_host_audio_libs(appdir: Path) -> None:
    """铁律自检：AppDir 内不得出现宿主音频库。"""
    hits = [
        p.relative_to(appdir).as_posix()
        for p in appdir.rglob("*")
        if p.name.startswith(FORBIDDEN_PREFIXES)
    ]
    if hits:
        raise die("AppDir 混入 libpulse/libasound，违反 03 §1 铁律: "
                  + ", ".join(hits[:5]))


def assemble_appdir(bundle: Path, workdir: Path) -> Path:
    """按 03 §3.1 组装 AppDir（不做权限规范化，由调用方统一做）。"""
    appdir = workdir / "AuraDSP.AppDir"
    (appdir / "usr/lib").mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, appdir / "usr/lib/auradsp", symlinks=True)
    shutil.copyfile(LINUX_APPRUN, appdir / "AppRun")
    textio.copy_text_lf(LINUX_SHARED / "auradsp.desktop",
                        appdir / "auradsp.desktop")
    icon = ICONS_DIR / "auradsp-app-256.png"
    if not icon.is_file():
        raise die(f"缺 256px 图标: {icon}")
    shutil.copyfile(icon, appdir / "auradsp.png")
    (appdir / ".DirIcon").symlink_to("auradsp.png")
    return appdir


def build(bundle: Path, version: str, out_dir: Path,
          cache_dir: Path | None = None) -> Path:
    # appimagetool 本体是静态二进制，但它内部会调 `file` 判类型——缺了会在
    # 最后一步炸（实测报 "file command is missing but required"）。这里提前
    # 拒绝，避免白等一次 16MB 的 AppDir 组装。
    if shutil.which("file") is None:
        raise die("appimagetool 需要 file 命令（apt-get install file）；"
                  "缺它时打包会在最后一步失败")
    tools = read_pins()
    for required in ("appimagetool", "type2-runtime"):
        if required not in tools:
            raise die(f"tools.pins 缺 {required}")

    cache = cache_dir or Path(
        os.environ.get("AURADSP_TOOLS_CACHE",
                       Path.home() / ".cache" / "auradsp-pack-tools"))
    appimagetool = fetch_pinned(tools["appimagetool"], cache)
    runtime = fetch_pinned(tools["type2-runtime"], cache)

    workdir = Path(tempfile.mkdtemp())
    try:
        appdir = assemble_appdir(bundle, workdir)
        stats = perms.normalize_tree(appdir)
        log(f"权限规范化: {perms.describe(stats)}")
        # AppRun 是 shell 脚本（非 ELF），规范化会把它压成 644，必须恢复
        perms.make_executable(appdir / "AppRun")
        check_no_host_audio_libs(appdir)

        out_dir.mkdir(parents=True, exist_ok=True)
        target = out_dir / f"AuraDSP-v{version}-x86_64.AppImage"
        env = dict(os.environ)
        env["ARCH"] = "x86_64"
        # 容器/CI 无 FUSE 时靠它运行工具本体
        env["APPIMAGE_EXTRACT_AND_RUN"] = "1"
        r = subprocess.run(
            [str(appimagetool), "--runtime-file", str(runtime),
             str(appdir), str(target)],
            env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise die(f"appimagetool 失败（rc={r.returncode}）："
                      f"{(r.stderr or r.stdout).strip()[:400]}")
        perms.make_executable(target)
        log(f"built: {target}")
        return target
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def preflight(cache_dir: Path | None = None) -> tuple[list[str], list[str]]:
    """发布预检用：`(blocking, notes)`，都不下载。

    blocking = 真阻塞（钉版表坏了、appimagetool 的 file 依赖缺失）；
    notes    = 只是「首次会下载」，不该拦住发布。
    """
    blocking: list[str] = []
    notes: list[str] = []

    if shutil.which("file") is None:
        blocking.append("缺 file 命令（appimagetool 硬依赖，apt-get install file）")

    try:
        tools = read_pins()
    except SystemExit as exc:
        return [str(exc)], notes

    cache = cache_dir or Path(
        os.environ.get("AURADSP_TOOLS_CACHE",
                       Path.home() / ".cache" / "auradsp-pack-tools"))
    for name, tool in tools.items():
        dest = cache / Path(tool.url).name
        if not dest.is_file():
            notes.append(f"{name} 未缓存（首次构建会下载）")
        elif _sha256(dest) != tool.sha256:
            notes.append(f"{name} 缓存哈希不符，会重新下载")
    return blocking, notes
