#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_tests.py — 便捷调用 test/runner.py"""
import os
import sys
import subprocess

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(ROOT_DIR, "test", "runner.py")

if __name__ == "__main__":
    sys.exit(subprocess.run([sys.executable, RUNNER] + sys.argv[1:], cwd=ROOT_DIR).returncode)
