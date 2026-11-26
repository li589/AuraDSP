"""资源档位与合并语义（`--resources` 的落点）。

档位（owner Q2 裁定 + 资源计划 P1）：

  core    staging 自带资源原样
  full    合并 auradsp-resource-full.zip 覆盖 resources/
  light   合并 resource-core + addon-headphone-ddc（全类别齐全、卷积走轻档）
  addons  依次 core → full → 全部 addon 包（增量叠加，不清底料）
  none    剔除 resources（保留 manifest.json 与占位说明）

两条被事故教育过的规则：

- **full/light 必须先清 staging 自带内容目录**：构建机工作树若躺着未入库
  的全量 IR 库，light 会被底料撑成 full 大小，档位失去意义（2026-11-12
  开发机实证 light≈full≈175MB）。
- **资源包哈希必须对账**：`SHA256SUMS.txt` 存在时逐包比对，未登记或
  不符一律拒绝合并（发行规范 §4「验哈希再导入」的唯一代码执行点）。
"""

from __future__ import annotations

import json
import shutil
import zipfile
from pathlib import Path

from .common import die, log
from .hashing import read_sha256sums, sha256_file

BUILTIN_DIRS_JSON = {
    "version": 1,
    "dirs": [
        {"kind": "convolver", "rel": "resources/convolver"},
        {"kind": "ddc", "rel": "resources/ddc"},
        {"kind": "liveprog", "rel": "resources/liveprog"},
        {"kind": "plugins", "rel": "resources/plugins"},
    ],
}

PLUGIN_PLACEHOLDER_KEEP = (
    "AuraDSP bundled plugin placeholder (resource plan P1, 2026-11-12).\n"
    "This directory intentionally ships empty for now; future open-source\n"
    "free plugins may be bundled here.\n")

# 单条目解压上限：防一方异常包把构建机内存吃爆（审计 F5）。
# 资源条目量级在 MB 级，512MiB 留足余量。
MAX_ENTRY_BYTES = 512 * 1024 * 1024


def validate_resource_tier(kind: str, packs_dir: Path) -> None:
    """校验档位必需包完整；light 缺 core 或 headphone-ddc 均失败。"""
    if kind != "light":
        return
    required = ("auradsp-resource-core.zip",
                "auradsp-addon-headphone-ddc.zip")
    missing = [name for name in required if not (packs_dir / name).is_file()]
    if missing:
        raise die("--resources light 缺少必需资源包: " + ", ".join(missing)
                  + f"（目录: {packs_dir}；先跑 build_packages.py 或加 "
                    "--rebuild-resource-packs）")


def resource_pack_paths(kind: str, packs_dir: Path) -> list[Path]:
    """按档位给出有序的资源包列表（顺序即覆盖顺序）。"""
    if kind in ("core", "none"):
        return []
    if kind == "full":
        full = packs_dir / "auradsp-resource-full.zip"
        return [full] if full.is_file() else []
    if kind == "light":
        ordered = []
        for name in ("auradsp-resource-core.zip",
                     "auradsp-addon-headphone-ddc.zip"):
            p = packs_dir / name
            if p.is_file():
                ordered.append(p)
        return ordered
    # addons：core → full → addons（文件名序）
    ordered = []
    for name in ("auradsp-resource-core.zip", "auradsp-resource-full.zip"):
        p = packs_dir / name
        if p.is_file():
            ordered.append(p)
    ordered += sorted(packs_dir.glob("auradsp-addon-*.zip"))
    return ordered


def finalize_resources(res_dir: Path, what_if: bool) -> None:
    """合并后的统一收尾：插件空占位目录 + builtin_dirs.json。

    staging 来自旧构建（无 plugins/）或资源 zip 覆盖后占位丢失时在此兜底，
    保证任何档位的 resources/ 结构恒完整。
    """
    if what_if:
        log("resources: what-if 跳过 finalize（占位 + builtin_dirs.json）")
        return
    for sub in ("clap", "vst2", "vst3"):
        keep = res_dir / "plugins" / sub / ".keep"
        if not keep.is_file():
            keep.parent.mkdir(parents=True, exist_ok=True)
            keep.write_text(PLUGIN_PLACEHOLDER_KEEP, encoding="utf-8")
    (res_dir / "builtin_dirs.json").write_text(
        json.dumps(BUILTIN_DIRS_JSON, indent=1) + "\n", encoding="utf-8")
    log("resources: builtin_dirs.json 已生成 + plugins 占位已补齐")


def _clear_tier_content(res_dir: Path) -> None:
    for sub in ("convolver", "ddc", "liveprog"):
        d = res_dir / sub
        if d.exists():
            shutil.rmtree(d)
    log("resources: 已清 staging 自带内容目录（档位以 zip 为准）")


def _extract_pack(pack: Path, res_dir: Path) -> int:
    """解一个资源包进 res_dir，返回落盘条目数。"""
    count = 0
    with zipfile.ZipFile(pack) as zf:
        for info in zf.infolist():
            name = info.filename
            # user_data 隔离按大小写不敏感判定（2026-11-08 审计 F5）：
            # Windows 文件系统大小写不敏感，USER_DATA/ 变体会落进同一
            # 目录，敏感前缀检查不得被大小写绕开。
            if name.endswith("/") or name.lower().startswith("user_data/"):
                continue
            if info.file_size > MAX_ENTRY_BYTES:
                raise die(f"资源包 {pack.name} 条目超上限: {name}"
                          f"（{info.file_size} 字节）")
            target = res_dir / name
            if not target.resolve().is_relative_to(res_dir.resolve()):
                raise die(f"资源包 {pack.name} 含越界路径: {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(zf.read(info))
            count += 1
    return count


def apply_resources(
    work_staging: Path, kind: str, packs_dir: Path, what_if: bool,
) -> list[dict[str, str]]:
    """在 staging 副本上应用资源策略，返回合并记录（写入 build-info）。"""
    validate_resource_tier(kind, packs_dir)
    records: list[dict[str, str]] = []
    res_dir = work_staging / "resources"

    if kind == "none":
        if res_dir.exists():
            manifest = res_dir / "manifest.json"
            keep = manifest.read_bytes() if manifest.is_file() else None
            shutil.rmtree(res_dir)
            res_dir.mkdir(parents=True)
            if keep is not None:
                (res_dir / "manifest.json").write_bytes(keep)
            (res_dir / "README.txt").write_text(
                "Resources were excluded from this package (--resources none).\n"
                "Download the resource packs from the GitHub Release and\n"
                "extract them into this directory.\n", encoding="utf-8")
        log("resources: none（已剔除，保留 manifest.json）")
        return records

    packs = resource_pack_paths(kind, packs_dir)
    if kind in ("full", "addons", "light") and not packs:
        raise die(f"--resources {kind} 需要资源包，但 {packs_dir} 下没有找到"
                  "（先跑 build_packages.py 或加 --rebuild-resource-packs）")

    if packs and kind in ("full", "light") and not what_if:
        _clear_tier_content(res_dir)

    expected_sums = read_sha256sums(packs_dir / "SHA256SUMS.txt")
    for pack in packs:
        sha = sha256_file(pack)
        if expected_sums:
            want = expected_sums.get(pack.name)
            if want is None:
                raise die(f"SHA256SUMS.txt 未登记资源包 {pack.name}，"
                          "拒绝合并（发行完整性对账）")
            if want != sha:
                raise die(f"资源包 {pack.name} 的 SHA-256 与 "
                          "SHA256SUMS.txt 不符，拒绝合并")
        count = 0 if what_if else _extract_pack(pack, res_dir)
        records.append({"pack": pack.name, "sha256": sha, "files": str(count)})
        log(f"resources: 合并 {pack.name}（{count} 文件，sha256 {sha[:12]}…）")

    if kind == "core":
        log("resources: core（staging 自带）")
    finalize_resources(res_dir, what_if)
    return records
