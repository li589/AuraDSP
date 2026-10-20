import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "test_plugin_chain.exe")

if not os.path.isfile(EXE):
    print(f"FAIL  test_plugin_chain.exe exists  {EXE}")
    sys.exit(1)

result = subprocess.run([EXE], cwd=ROOT, capture_output=True, text=True, timeout=120)
print(result.stdout, end="")
if result.stderr:
    print(result.stderr, file=sys.stderr, end="")
if result.returncode != 0:
    print(f"FAIL  test_plugin_chain exited {result.returncode}")
    sys.exit(result.returncode)

print("PASS  plugin chain direct consistency")
