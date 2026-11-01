# -*- coding: utf-8 -*-
"""engine_artifact — 引擎构建产物的单一路径解析器（S1，2026-11-01）。

背景：《Linux适配方案》T2/D-4 —— 此前 100+ 个 smoke 各自拼
`core/desktop/windows/out/Release/auradsp_engine.dll`，另有十余处硬编码
作者机绝对路径 `D:\\temp_desktop\\Proj\\JamesDSP`。产物位置一旦变化
（新平台、新构建目录）就要全仓改。产物路径只许在这里定义一次：

  Windows: core/desktop/windows/out/<Config>/auradsp_engine.dll
  Linux:   core/desktop/linux/out/<Config>/libauradsp_engine.so

smoke / 工具需要引擎产物时用 find_engine_lib() 或 engine_lib_path()，
不要再拼字面路径。新 smoke 请 `sys.path` 加入 test/ 后 import 本模块
（与 smoke_platform_isolation.py 定位 runner.py 的手法一致）。
"""
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def current_platform():
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macos"
    return "other"


def engine_lib_name(platform=None):
    platform = platform or current_platform()
    if platform == "windows":
        return "auradsp_engine.dll"
    if platform == "linux":
        return "libauradsp_engine.so"
    raise ValueError(f"平台 {platform} 暂无引擎产物定义")


def engine_lib_path(root=None, platform=None, config="Release"):
    """构建真相源路径（core/desktop/<platform>/out/<Config>/<lib>）。"""
    platform = platform or current_platform()
    root = root or REPO_ROOT
    return os.path.join(root, "core", "desktop", platform, "out", config,
                        engine_lib_name(platform))


def engine_lib_candidates(root=None, platform=None, config="Release"):
    """候选位置，顺序即优先级：构建真相源 → test/ 运行副本。

    test/<lib> 是 verify_dll_copies 的分发副本位置（Windows 既有政策）；
    Linux 暂无分发政策，候选保留同构位置，缺失自动跳过。
    """
    root = root or REPO_ROOT
    return [
        engine_lib_path(root, platform, config),
        os.path.join(root, "test", engine_lib_name(platform)),
    ]


def find_engine_lib(root=None, platform=None, config="Release"):
    """返回第一个存在的候选；都不存在时返回真相源路径（供报错展示）。"""
    candidates = engine_lib_candidates(root, platform, config)
    for path in candidates:
        if os.path.isfile(path):
            return path
    return candidates[0]


def repo_root_from(file_path, levels=2):
    """由 __file__ 推导仓库根：test/smoke/x.py 与 tools/bin/x.py 均为 2 层。

    替代 `ROOT = r"D:\\temp_desktop\\Proj\\JamesDSP"` 硬编码（S1-②）。
    """
    path = os.path.dirname(os.path.abspath(file_path))
    for _ in range(levels):
        path = os.path.dirname(path)
    return path
