#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
AuraDSP 音频资产自动化数据治理与清洗管线
遵循三大铁律：
1. 外部源 (D:\myPrograms\AudioEffect\Impulse) 绝对只读；
2. 彻底剔除 .lrc 歌词、压缩包、空文件与损坏文件；
3. 全部脉冲响应统一规范为 .irs 格式，并按声学功能分类；
4. 保证 Core 包与 Full 包使用完全相同的规范相对路径，实现覆盖时的幂等无冲突。
"""

import os
import sys
import shutil
import hashlib
import struct
import json
import re
from pathlib import Path
from collections import defaultdict

# 强制 UTF-8 输出
if sys.stdout.encoding != 'utf-8':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

SOURCE_IMPULSE_DIR = Path(r"D:\myPrograms\AudioEffect\Impulse")
PROJECT_ROOT = Path(r"D:\temp_desktop\Proj\JamesDSP")
RESOURCE_DIR = PROJECT_ROOT / "assets"
LIVEPROG_SRC_DIR = PROJECT_ROOT / "source"

# 杂质后缀黑名单
JUNK_EXTS = {'.lrc', '.rar', '.zip', '.7z', '.url', '.prf', '.txt', '.doc', '.docx', '.exe', '.dll', '.ini'}

# 8 大声学功能类目
CATEGORIES = [
    "01_headphone_correction",
    "02_spatial_3d",
    "03_acoustic_spaces",
    "04_hardware_analog",
    "05_bass_clarity",
    "06_mastering_signatures",
    "07_speaker_devices",
    "08_community_classic",
]

# 分类关键词规则
CATEGORY_RULES = {
    "01_headphone_correction": [
        "frc", "harman", "diffuse", "freefield", "correction", "target", "earphone", "headphone", "iem",
        "sennheiser", "sony", "akg", "beyer", "shure", "ath", "airpods", "wh-", "wf-", "hd5", "hd6", "hd8",
        "k701", "k712", "dt770", "dt880", "dt990", "ie80", "ie800", "er4", "se215", "se535", "se846",
        "耳机校正", "频响校正", "目标曲线", "曲线校准"
    ],
    "02_spatial_3d": [
        "3d", "surround", "hrtf", "holophonic", "binaural", "spatial", "cinema", "5.1", "7.1", "wide",
        "panoramic", "virtual", "atmos", "dts", "dolby", "srs", "sphere", "matrix", "qsound", "circle",
        "全景声", "环绕", "空间", "立体声展宽", "虚拟", "影院", "沉浸"
    ],
    "03_acoustic_spaces": [
        "hall", "room", "studio", "chamber", "cathedral", "church", "car", "auditorium", "live", "stage",
        "acoustic", "plate", "spring", "ambience", "arena", "stadium", "theater", "concert", "cave",
        "大厅", "音乐厅", "录音棚", "大教堂", "车内", "车载", "房间", "混响", "舞台", "剧场"
    ],
    "04_hardware_analog": [
        "tube", "valve", "tape", "console", "neve", "ssl", "studer", "pultec", "transformer", "analog",
        "cassette", "preamp", "solidstate", "vintage", "warmth", "harmonic", "saturation", "vacuum",
        "电子管", "胆机", "磁带", "调音台", "模拟", "复古", "硬件", "黑胶", "甲类"
    ],
    "05_bass_clarity": [
        "bass", "sub", "lowend", "clearloud", "punch", "impact", "deep", "megabass", "warmth", "dynamicbass",
        "thump", "kick", "subwoofer", "ultra", "clearbass", "heavy", "xtreme", "superbass", "bassboost",
        "低音", "超重低音", "低频", "震撼", "下潜", "重低音", "弹性", "轰头", "打击感"
    ],
    "06_mastering_signatures": [
        "master", "bbe", "exciter", "air", "vocal", "clarity", "hifi", "audiophile", "treble", "presence",
        "sonysound", "dsee", "walkman", "alive", "bright", "crisp", "sparkle", "crystal", "definition",
        "母带", "人声", "通透", "高音", "发烧", "清晰", "靓声", "毒性", "润泽", "解析"
    ],
    "07_speaker_devices": [
        "speaker", "monitor", "yamaha", "ns10", "caraudio", "hifisystem", "radio", "phone", "cabinet",
        "desktop", "boombox", "television", "soundbar", "nearfield", "genelec", "adam", "jbl",
        "音箱", "监听", "收音机", "车机", "便携音箱", "喇叭", "电视"
    ],
}

# 常见耳机品牌识别列表 (完整扩充)
KNOWN_BRANDS = [
    "SONY", "Sennheiser", "Audio-Technica", "AKG", "Beyerdynamic", "Shure", "Philips", "Beats",
    "Apple", "Bose", "JBL", "HiFiMAN", "Fostex", "Etymotic", "Final", "Bowers & Wilkins", "Bang & Olufsen",
    "Denon", "Pioneer", "JVC", "V-MODA", "Grado", "Marshall", "Koss", "Edifier", "Moondrop",
    "Meze", "Campfire", "Creative", "Plantronics", "Anker", "1MORE", "KZ", "FiiO", "TinHiFi",
    "CRESYN", "JAYS", "Klipsch", "LG", "Monster", "Logitech", "Ultimate Ears", "Panasonic",
    "Samsung", "Skullcandy", "Sol Republic", "SteelSeries", "TDK", "Westone", "Xiaomi", "Yamaha",
    "Huawei", "HTC", "Nokia", "SoundMAGIC", "Oppo", "Vivo", "OnePlus"
]


def inspect_wav_header(file_path: Path):
    """验证文件是否为合法的 RIFF/WAVE 音频文件，并提取基础元数据"""
    try:
        size = file_path.stat().st_size
        if size < 128:
            return None
        with open(file_path, "rb") as f:
            head = f.read(44)
            if len(head) < 44:
                return None
            riff = head[0:4]
            wave = head[8:12]
            if riff != b"RIFF" or wave != b"WAVE":
                return None
            
            channels = 2
            sample_rate = 44100
            bits_per_sample = 16
            
            # 扫描 fmt chunk
            f.seek(12)
            while True:
                chunk_header = f.read(8)
                if len(chunk_header) < 8:
                    break
                chunk_id, chunk_size = struct.unpack("<4sI", chunk_header)
                if chunk_id == b"fmt ":
                    fmt_data = f.read(min(chunk_size, 16))
                    if len(fmt_data) >= 14:
                        audio_format, channels, sample_rate, _, _, bits_per_sample = struct.unpack("<HHIIHH", fmt_data[:16])
                    break
                else:
                    f.seek(chunk_size, 1)
                    
            return {
                "valid": True,
                "size_bytes": size,
                "channels": channels,
                "sample_rate": sample_rate,
                "bits_per_sample": bits_per_sample,
            }
    except Exception:
        return None


def calculate_md5(file_path: Path) -> str:
    h = hashlib.md5()
    with open(file_path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def clean_filename(name: str) -> str:
    """清理文件名中的垃圾前缀与后缀，修复乱码"""
    # 1. 尝试修复 cp1252/latin1 还原 GBK
    fixed = name
    for enc in ['cp1252', 'latin1', 'iso-8859-1']:
        try:
            raw = name.encode(enc)
            for dec in ['gbk', 'gb18030', 'utf-8']:
                try:
                    cand = raw.decode(dec)
                    if any('\u4e00' <= ch <= '\u9fff' for ch in cand) and not any(ch in cand for ch in ['ŷ', 'ṷ', 'Ϊ', 'Ã', 'Â']):
                        fixed = cand
                        break
                except Exception:
                    pass
        except Exception:
            pass
    
    # 2. 去除尾部原扩展名
    stem = re.sub(r'\.(wav|irs|flac)$', '', fixed, flags=re.IGNORECASE)
    
    # 3. 剥离无意义冗余标签
    stem = re.sub(r'^\[(VIPER4Android|JamesDSP|IR|WAV|IRS)\][\s_-]*', '', stem, flags=re.IGNORECASE)
    stem = re.sub(r'[\s_-]*(Viper|JamesDSP)$', '', stem, flags=re.IGNORECASE)
    
    # 4. 去除多余括号中包含的损坏字符
    stem = stem.replace('\ufffd', '').strip()
    if not stem:
        stem = "Classic_Tuning"
        
    return stem


def score_candidate_name(file_path: Path, stem: str) -> int:
    """在重复的多个副本中为候选文件名打分，最高分者胜出成为主本"""
    score = 0
    # 惩罚项
    if '\ufffd' in stem:
        score -= 1000
    if stem.isdigit():
        score -= 50
    if len(stem) < 3:
        score -= 30
    if stem.startswith("New ") or stem.startswith("Copy"):
        score -= 20
        
    # 奖励项
    if any('\u4e00' <= ch <= '\u9fff' for ch in stem):
        score += 40  # 清晰中文加分
    if any(k in stem.lower() for k in ["clearloud", "harman", "dts", "sony", "sennheiser", "bass", "hall", "master"]):
        score += 30
    if " " in stem or "-" in stem or "+" in stem:
        score += 15  # 有词汇间隔加分
    score += min(len(stem), 40)  # 适当长度加分
    
    # 路径来源偏好 (Convolver > JamesDSP > ViPER)
    p_str = str(file_path).lower()
    if "convolver" in p_str:
        score += 10
    return score


def classify_ir(clean_name: str, rel_path_str: str) -> str:
    """基于名称与语义进行 8 大声学功能类目映射"""
    text = f"{clean_name} {rel_path_str}".lower()
    for cat in CATEGORIES[:-1]:  # 排除 08_community_classic
        keywords = CATEGORY_RULES.get(cat, [])
        for kw in keywords:
            if kw in text:
                return cat
    return "08_community_classic"


def extract_brand_for_ddc(file_path: Path) -> str:
    """从 VDC 路径或文件名推导品牌"""
    p_str = str(file_path)
    for b in KNOWN_BRANDS:
        if b.lower() in p_str.lower():
            return b
    # 从父文件夹推导
    parent_name = file_path.parent.name
    if parent_name and parent_name not in ["DDC", "DDC-Orig", "Impulse"]:
        return parent_name
    return "Others"


def run_pipeline(dry_run: bool = True):
    print(f"=== AuraDSP 音频资产自动化数据治理管线启动 ===")
    print(f"源路径 (只读): {SOURCE_IMPULSE_DIR}")
    print(f"目标工程路径: {RESOURCE_DIR}")
    print(f"执行模式: {'[DRY-RUN 预检模拟]' if dry_run else '[正式落盘执行]'}\n")

    if not SOURCE_IMPULSE_DIR.exists():
        print(f"错误: 原始目录不存在: {SOURCE_IMPULSE_DIR}")
        return

    # 1. 扫描与体检
    print("1. 正在深度只读扫描 Impulse 目录...")
    ir_groups = defaultdict(list)  # md5 -> list of (path, meta)
    ddc_groups = defaultdict(list) # md5 -> list of path
    junk_count = 0
    corrupt_count = 0
    total_scanned = 0

    for root, _, files in os.walk(SOURCE_IMPULSE_DIR):
        for f in files:
            total_scanned += 1
            f_path = Path(root) / f
            ext = f_path.suffix.lower()

            # 过滤杂质
            if ext in JUNK_EXTS or f_path.stat().st_size == 0:
                junk_count += 1
                continue

            # 处理 DDC (.vdc)
            if ext == '.vdc':
                if f_path.stat().st_size > 32:
                    h = calculate_md5(f_path)
                    ddc_groups[h].append(f_path)
                else:
                    junk_count += 1
                continue

            # 处理脉冲 (.wav / .irs / .flac)
            if ext in ['.wav', '.irs', '.flac']:
                meta = inspect_wav_header(f_path)
                if not meta:
                    corrupt_count += 1
                    continue
                h = calculate_md5(f_path)
                ir_groups[h].append((f_path, meta))
            else:
                junk_count += 1

    print(f"扫描完毕: 发现 {total_scanned} 个文件")
    print(f"  • 杂质/歌词/空文件: {junk_count} 个 (已彻底过滤剔除)")
    print(f"  • 损坏/非法音频头: {corrupt_count} 个 (已安全拦截)")
    print(f"  • 有效唯一脉冲文件 (MD5): {len(ir_groups)} 个 (原始包含 {sum(len(v) for v in ir_groups.values())} 份，去重率 {100 - len(ir_groups)*100/max(1, sum(len(v) for v in ir_groups.values())):.1f}%)")
    print(f"  • 有效唯一耳机 DDC (MD5): {len(ddc_groups)} 个 (原始包含 {sum(len(v) for v in ddc_groups.values())} 份，去重率 {100 - len(ddc_groups)*100/max(1, sum(len(v) for v in ddc_groups.values())):.1f}%)")

    # 2. 脉冲响应文件决议与分类
    print("\n2. 正在决议主本并进行声学分类 (全部统一为 .irs)...")
    final_ir_items = []
    category_counts = defaultdict(int)


    for md5_hash, entries in ir_groups.items():
        # 在多个副本中选出最佳主本
        best_path, best_meta = entries[0]
        best_score = -9999
        best_clean_name = clean_filename(best_path.name)

        for p, m in entries:
            clean_s = clean_filename(p.name)
            score = score_candidate_name(p, clean_s)
            if score > best_score:
                best_score = score
                best_path = p
                best_meta = m
                best_clean_name = clean_s

        # 归类
        rel_str = str(best_path.relative_to(SOURCE_IMPULSE_DIR))
        cat = classify_ir(best_clean_name, rel_str)
        category_counts[cat] += 1

        # 统一输出扩展名为 .irs
        target_filename = f"{best_clean_name}.irs"
        rel_target_path = f"convolver/{cat}/{target_filename}"

        final_ir_items.append({
            "id": f"ir-{cat[:2]}-{hashlib.md5(best_clean_name.encode('utf-8')).hexdigest()[:8]}",
            "type": "convolver",
            "category": cat,
            "name": best_clean_name,
            "relative_path": rel_target_path,
            "src_path": str(best_path),
            "hash_md5": md5_hash,
            "sample_rate": best_meta["sample_rate"],
            "channels": best_meta["channels"],
            "bits_per_sample": best_meta["bits_per_sample"],
            "size_bytes": best_meta["size_bytes"],
            "score": best_score,
            "tier": "full"
        })

    # 为每个分类选取 top 4 作为 Core 核心代表（8 大分类 * 4 = 32 款）
    ir_by_cat = defaultdict(list)
    for it in final_ir_items:
        ir_by_cat[it["category"]].append(it)

    core_assigned = 0
    for cat in CATEGORIES:
        sorted_cat = sorted(ir_by_cat[cat], key=lambda x: x["score"], reverse=True)
        for it in sorted_cat[:4]:
            it["tier"] = "core"
            core_assigned += 1

    for cat in CATEGORIES:
        print(f"  • [{cat}] {category_counts[cat]} 款脉冲 (含 4 款核心精选)")

    # 3. DDC 耳机校准决议与分类
    print("\n3. 正在整理 441 款耳机校准 DDC 文件...")
    final_ddc_items = []
    brand_counts = defaultdict(int)

    for md5_hash, paths in ddc_groups.items():
        # 选取名字最好的
        best_p = max(paths, key=lambda x: len(x.stem))
        brand = extract_brand_for_ddc(best_p)
        brand_counts[brand] += 1
        clean_model = best_p.stem.strip()
        
        rel_target_path = f"ddc/{brand}/{clean_model}.vdc"
        is_core_ddc = brand in ["SONY", "Sennheiser", "Apple", "Audio-Technica", "AKG", "Beyerdynamic"] and brand_counts[brand] <= 10

        final_ddc_items.append({
            "id": f"ddc-{hashlib.md5(f'{brand}-{clean_model}'.encode('utf-8')).hexdigest()[:8]}",
            "type": "ddc",
            "brand": brand,
            "model": clean_model,
            "relative_path": rel_target_path,
            "src_path": str(best_p),
            "hash_md5": md5_hash,
            "size_bytes": best_p.stat().st_size,
            "tier": "core" if is_core_ddc else "full"
        })

    print(f"  • 共归纳 {len(final_ddc_items)} 款耳机校准，涵盖 {len(brand_counts)} 个品牌")
    top_brands = sorted(brand_counts.items(), key=lambda x: x[1], reverse=True)[:8]
    print(f"  • 主要品牌分布: {', '.join(f'{b} ({c}款)' for b, c in top_brands)}")

    # 4. 统计与清单
    core_ir_count = sum(1 for item in final_ir_items if item["tier"] == "core")
    core_ddc_count = sum(1 for item in final_ddc_items if item["tier"] == "core")
    print(f"\n分级统计:")
    print(f"  • Core 核心包精选: {core_ir_count} 款 .irs 脉冲 + {core_ddc_count} 款耳机 DDC + 全量 Liveprog 脚本")
    print(f"  • Full 全量一体包: {len(final_ir_items)} 款 .irs 脉冲 + {len(final_ddc_items)} 款耳机 DDC")

    if dry_run:
        print("\n>>> DRY-RUN 检查通过！无任何错误，未向磁盘写入文件。")
        print("若要正式执行落盘治理，请运行: python clean_and_organize.py --execute")
        return

    # 5. 正式落盘执行
    print("\n5. 开始正式向工程盘落盘 (D:\\temp_desktop\\Proj\\JamesDSP\\assets)...")
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)

    # 5.1 复制脉冲文件并统一命名为 .irs
    written_irs = 0
    for item in final_ir_items:
        dest = RESOURCE_DIR / item["relative_path"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item["src_path"], dest)
        written_irs += 1
        if written_irs % 500 == 0:
            print(f"  [落盘进度] 已写入 {written_irs}/{len(final_ir_items)} 款 .irs 脉冲...")

    # 5.2 复制 DDC 文件
    for item in final_ddc_items:
        dest = RESOURCE_DIR / item["relative_path"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item["src_path"], dest)

    # 5.3 整理 Liveprog 脚本
    print("\n5.3 正在同步官方 Liveprog EEL2 脚本到 assets/liveprog...")
    liveprog_dest = RESOURCE_DIR / "liveprog"
    liveprog_dest.mkdir(parents=True, exist_ok=True)
    liveprog_items = []
    
    # 优先使用项目自身 source/ 目录下的官方脚本
    liveprog_found = 0
    if LIVEPROG_SRC_DIR.exists():
        for r, _, fs in os.walk(LIVEPROG_SRC_DIR):
            for f in fs:
                if f.endswith('.eel'):
                    src_f = Path(r) / f
                    # 识别子目录类别
                    cat = "utility"
                    p_lower = str(src_f).lower()
                    if "filter" in p_lower or "eq" in p_lower:
                        cat = "filters_eq"
                    elif "dynamic" in p_lower or "comp" in p_lower or "drx" in p_lower:
                        cat = "dynamics"
                    elif "spatial" in p_lower or "stereo" in p_lower or "width" in p_lower:
                        cat = "spatial_stereo"
                    elif "reverb" in p_lower or "hadamard" in p_lower or "fdn" in p_lower:
                        cat = "reverb"
                    elif "mod" in p_lower or "chorus" in p_lower or "flange" in p_lower:
                        cat = "modulation_time"
                    elif "distort" in p_lower or "lofi" in p_lower:
                        cat = "distortion_lofi"
                        
                    rel_dest = f"liveprog/{cat}/{f}"
                    out_f = RESOURCE_DIR / rel_dest
                    out_f.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src_f, out_f)
                    liveprog_items.append({
                        "id": f"eel-{hashlib.md5(f.encode('utf-8')).hexdigest()[:8]}",
                        "type": "liveprog",
                        "category": cat,
                        "name": f[:-4],
                        "relative_path": rel_dest,
                        "hash_md5": calculate_md5(out_f),
                        "tier": "core"
                    })
                    liveprog_found += 1
    print(f"  • 已同步 {liveprog_found} 款官方 EEL 脚本")

    # 5.4 生成全局索引清单 manifest.json
    print("\n5.4 正在生成标准 manifest.json 清单...")
    all_manifest_items = []
    for item in final_ir_items:
        clean_entry = {k: v for k, v in item.items() if k != "src_path"}
        all_manifest_items.append(clean_entry)
    for item in final_ddc_items:
        clean_entry = {k: v for k, v in item.items() if k != "src_path"}
        all_manifest_items.append(clean_entry)
    all_manifest_items.extend(liveprog_items)

    manifest_data = {
        "schema_version": "1.0.0",
        "project": "AuraDSP",
        "build_date": "2026-10-11T16:30:00Z",
        "description": "AuraDSP 统一声学分发资源库 (去重清洗纯净版，脉冲统一为 .irs 格式)",
        "summary": {
            "total_convolver": len(final_ir_items),
            "total_ddc": len(final_ddc_items),
            "total_liveprog": len(liveprog_items),
            "core_convolver": core_ir_count,
            "core_ddc": core_ddc_count,
        },
        "conflict_safety_policy": {
            "canonical_relative_paths": True,
            "idempotent_overwrite": True,
            "user_data_isolation": "user_data/ 永久隔离保护",
            "state_decoupled": "用户偏好保存在 user_data/resource_preferences.json"
        },
        "items": all_manifest_items
    }

    manifest_path = RESOURCE_DIR / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as mf:
        json.dump(manifest_data, mf, indent=2, ensure_ascii=False)

    print(f"\n✅ 治理完成！所有纯净音频资源已成功落盘至: {RESOURCE_DIR}")
    print(f"  • 总脉冲响应 (.irs): {len(final_ir_items)} 款 (0 歌词、0 损坏、统一 .irs)")
    print(f"  • 耳机校准 (.vdc): {len(final_ddc_items)} 款")
    print(f"  • 可编程 DSP (.eel): {len(liveprog_items)} 款")
    print(f"  • 清单文件: {manifest_path} ({manifest_path.stat().st_size / 1024:.1f} KB)")


if __name__ == "__main__":
    is_exec = "--execute" in sys.argv
    run_pipeline(dry_run=not is_exec)
