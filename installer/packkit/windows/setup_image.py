"""Setup 单体 EXE：拼装与自检。

文件布局（实施设计 §3）：

    [ bootstrapper.exe ][ ZIP-W ][ ZIP-P ][ 80B 尾块 ]

- ZIP-W（向导运行时）必须 **STORED**：引导壳零第三方依赖，只解 stored；
  内含 `wizard_manifest.json`，登记载荷 sha256 与向导文件清单（二级校验）。
- ZIP-P（产品载荷）用 deflate（向导侧用 archive 包解压）。
- 尾块 `<8sIIQQQQ32s>`：magic / fmtVer / flags / W@off+len / P@off+len /
  payload sha256，共 80 字节。`--verify` 就是按尾块独立复算一遍。
"""

from __future__ import annotations

import io
import json
import struct
import zipfile
from pathlib import Path

from ..common import log
from ..hashing import sha256_bytes, sha256_file

FOOTER_MAGIC = b"AURASTP1"
FOOTER_FMT = "<8sIIQQQQ32s"  # magic, fmtVer, flags, offW, lenW, offP, lenP, sha256P
FOOTER_SIZE = struct.calcsize(FOOTER_FMT)
assert FOOTER_SIZE == 80, FOOTER_SIZE
FOOTER_VERSION = 1


def payload_file_manifest(payload_bytes: bytes) -> list[dict[str, object]]:
    """从构建时的真实 ZIP-P 生成受信完整文件清单。"""
    entries: list[dict[str, object]] = []
    seen: set[str] = set()
    with zipfile.ZipFile(io.BytesIO(payload_bytes)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename.replace("\\", "/")
            if not name.startswith("payload/"):
                raise ValueError(f"payload entry lacks payload/ prefix: {info.filename}")
            rel = name[len("payload/"):]
            parts = rel.split("/")
            if (not rel or rel.startswith("/") or ":" in rel
                    or any(part in ("", ".", "..") for part in parts)):
                raise ValueError(f"invalid payload entry path: {info.filename}")
            key = rel.casefold()
            if key in seen:
                raise ValueError(f"duplicate payload entry: {rel}")
            seen.add(key)
            content = zf.read(info)
            if len(content) != info.file_size:
                raise ValueError(f"payload entry size mismatch: {rel}")
            entries.append({"path": rel, "size": len(content),
                            "sha256": sha256_bytes(content)})
    return entries


def build_wizard_zip(
    wizard_src: Path, dest_zip: Path, ver: dict[str, str], payload_bytes: bytes,
) -> None:
    """打 ZIP-W：向导、ZIP-P 摘要及构建期完整文件清单，一律 STORED。"""
    files = sorted(p for p in wizard_src.rglob("*") if p.is_file())
    manifest = {
        "product": "AuraDSP",
        "version": ver["AURADSP_VERSION"],
        "fullVersion": ver["AURADSP_FULL_VERSION"],
        "payloadSha256": sha256_bytes(payload_bytes),
        "payloadFiles": payload_file_manifest(payload_bytes),
        "files": {f.relative_to(wizard_src).as_posix(): sha256_file(f)
                  for f in files},
    }
    manifest_path = dest_zip.parent / "wizard_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_STORED) as zf:
        for f in files:
            zf.write(f, f.relative_to(wizard_src).as_posix())
        zf.write(manifest_path, "wizard_manifest.json")


def assemble(dest: Path, shell: bytes, wizard_bytes: bytes,
             payload_bytes: bytes) -> dict[str, object]:
    """按「壳 + ZIP-W + ZIP-P + 尾块」写出 Setup，返回自检用元数据。"""
    payload_sha = sha256_bytes(payload_bytes)
    off_w = len(shell)
    off_p = off_w + len(wizard_bytes)
    footer = struct.pack(FOOTER_FMT, FOOTER_MAGIC, FOOTER_VERSION, 0,
                         off_w, len(wizard_bytes), off_p, len(payload_bytes),
                         bytes.fromhex(payload_sha))
    with dest.open("wb") as fh:
        fh.write(shell)
        fh.write(wizard_bytes)
        fh.write(payload_bytes)
        fh.write(footer)
    return {
        "payload_sha256": payload_sha,
        "shell_bytes": off_w,
        "wizard_bytes": len(wizard_bytes),
        "payload_bytes": len(payload_bytes),
    }


def verify(path: Path) -> bool:
    """独立自检：尾块结构、偏移闭合、载荷哈希、两个 zip 与清单一致性。"""
    data_len = path.stat().st_size
    with path.open("rb") as fh:
        fh.seek(max(0, data_len - FOOTER_SIZE))
        footer = fh.read(FOOTER_SIZE)
    if len(footer) != FOOTER_SIZE:
        log("verify: 文件小于尾块尺寸")
        return False

    magic, fmt, _flags, off_w, len_w, off_p, len_p, sha = struct.unpack(
        FOOTER_FMT, footer)
    ok = True

    def check(name: str, cond: bool, extra: str = "") -> None:
        nonlocal ok
        ok = ok and cond
        log(f"verify: {name} {'OK' if cond else 'FAIL'} {extra}")

    check("magic", magic == FOOTER_MAGIC)
    check("fmtVer", fmt == FOOTER_VERSION, f"(={fmt})")
    check("offsets", 0 < off_w < off_p and off_p + len_p + FOOTER_SIZE == data_len,
          f"(W@{off_w}+{len_w}, P@{off_p}+{len_p}, file={data_len})")

    with path.open("rb") as fh:
        fh.seek(off_p)
        payload = fh.read(len_p)
    digest = sha256_bytes(payload)
    check("payload sha256", digest.encode() == sha.hex().encode(), f"({digest[:12]}…)")
    try:
        payload_files = payload_file_manifest(payload)
    except Exception as exc:  # noqa: BLE001
        check("payload file manifest", False, f"({exc})")
        payload_files = None

    for label, off, ln in (("wizard", off_w, len_w), ("payload", off_p, len_p)):
        with path.open("rb") as fh:
            fh.seek(off)
            blob = fh.read(ln)
        try:
            zf = zipfile.ZipFile(io.BytesIO(blob))
            bad = zf.testzip()
            check(f"{label} zip", bad is None, f"({len(zf.namelist())} 条目)")
            if label == "wizard":
                man = json.loads(zf.read("wizard_manifest.json"))
                check("manifest payloadSha256", man.get("payloadSha256") == digest)
                expected_files = sorted(payload_files or [],
                                        key=lambda entry: str(entry["path"]).casefold())
                actual_files = sorted(man.get("payloadFiles", []),
                                      key=lambda entry: str(entry["path"]).casefold())
                check("manifest payloadFiles",
                      payload_files is not None and actual_files == expected_files,
                      f"({len(actual_files)} entries)")
        except Exception as exc:  # noqa: BLE001
            check(f"{label} zip", False, f"({exc})")
    return ok
