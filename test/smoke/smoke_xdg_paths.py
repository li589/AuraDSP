# -*- coding: utf-8 -*-
"""smoke_xdg_paths — XDG 目录规范门禁（S5b，2026-11-02）。

方案 §7 验收表登记的门禁：Linux 配置/数据目录必须读 XDG 环境变量，
且 $HOME 缺失时不得回退 '.'（旧实现把配置散落到进程工作目录）。
Dart 侧 getter 读进程环境，无法在 Python 里直接执行，故按本仓
源码守护型门禁的惯例做结构断言：
  - platform_profile.dart 的 configDir 读 XDG_CONFIG_HOME、
    dataDir 读 XDG_DATA_HOME，且两者都带 HOME 缺失的临时目录回退
  - 全文件不得再出现 `?? '.'` 形式的 HOME 回退
  - core/config.dart 提供 ConfigManager.dataDir 且迁移清单覆盖
    已切换到数据根的六个条目（presets / session_state.json /
    plugin_data / plugin_presets / plugins / liveprog）
"""
import os
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
APP = os.path.join(ROOT, "app", "auradsp_app", "lib")
PROFILE = os.path.join(APP, "platform", "platform_profile.dart")
CONFIG = os.path.join(APP, "core", "config.dart")

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    if not os.path.isfile(PROFILE) or not os.path.isfile(CONFIG):
        print("SKIP xdg_paths: app sources missing")
        return 0
    profile = open(PROFILE, encoding="utf-8").read()
    config = open(CONFIG, encoding="utf-8").read()

    check("XDG_CONFIG_HOME" in profile,
          "configDir reads XDG_CONFIG_HOME")
    check("XDG_DATA_HOME" in profile,
          "dataDir reads XDG_DATA_HOME")
    check("static String get dataDir" in profile,
          "PlatformProfile.dataDir exists")
    check("?? '.'" not in profile and '?? "."' not in profile,
          "no HOME fallback to '.' remains")
    check(profile.count("Directory.systemTemp") >= 2,
          "configDir/dataDir fall back to systemTemp when HOME missing")

    check("static String get dataDir" in config,
          "ConfigManager.dataDir exists")
    check("dataPath" in config and "dataSubDir" in config,
          "ConfigManager data path helpers exist")
    for entry in ("presets", "session_state.json", "plugin_data",
                  "plugin_presets", "plugins", "liveprog"):
        check(f"'{entry}'" in config,
              f"legacy migration covers {entry}")

    print(f"xdg_paths: {'FAIL ' + str(len(FAILS)) if FAILS else 'PASS'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
