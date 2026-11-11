#!/usr/bin/env python3
"""第六轮项 1 定罪契约：VAIO 环映射不得被同进程其他句柄的关闭拆掉。

证据链（2026-11-11，WinDbg dump 实证 + 代码复核）：
- 崩溃 = auravaio_bridge.dll+0x6d51 读违例，指令
  `cmp dword ptr [rax+1Ch], r15d`（r15=2）即泵线程每轮读
  AURA_VAIO_SHARED_HEADER.Channels（偏移 0x1C）时映射已不存在；
- 旧版驱动 IRP_MJ_CLEANUP 只按进程判定便 MmUnmapLockedPages，
  而 vaio_detect 每次都开/关一次控制设备——桥运行期的一次
  detect（开机 vaiomode 起桥后紧跟的自动 detect、设置页刷新
  设备）即拆掉泵的映射，泵苏醒读头即死，整进程崩溃。历轮
  「刷新闪退 / 开机闪退」同源。

本门钉三处修复（任一回退即红）：
1. 驱动 CLEANUP 按 FILE_OBJECT 归属（映射由哪个文件对象建，
   只有它的 cleanup 能拆），MAP 时记录归属；
2. 桥 vaio_detect 运行期免开控制设备（版本/状态走缓存合成）；
3. vaio_stop 的 join 超时中止拆解（不在活泵脚下解映射）。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
DRV = (ROOT / "core/desktop/windows-drivers/01_vaio_driver/src/ControlDevice.cpp").read_text(encoding="utf-8", errors="replace")
BRG = (ROOT / "core/desktop/windows-drivers/bridge/vaio_bridge/VaioBridge.cpp").read_text(encoding="utf-8", errors="replace")

fails = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


# 1. 驱动：归属记录 + cleanup 按归属判定
check("驱动记录映射归属 FILE_OBJECT",
      "g_pMappedFileObject  = stack->FileObject" in DRV
      or "g_pMappedFileObject = stack->FileObject" in DRV)
cleanup_at = DRV.find("AuraControlDevice_DispatchCleanup")
cleanup_seg = DRV[cleanup_at:cleanup_at + 2600]
check("CLEANUP 以 FileObject 归属为解映射条件",
      "stack->FileObject == g_pMappedFileObject" in cleanup_seg)
check("CLEANUP 解映射后清归属", "g_pMappedFileObject = NULL" in cleanup_seg)

# 2. 桥：detect 运行期分支先于 CreateFileW 且合成在场
det_at = BRG.find("int vaio_detect(")
det_seg = BRG[det_at:det_at + 3400]
run_at = det_seg.find("InterlockedCompareExchange(&g_vaio.running")
open_at = det_seg.find("CreateFileW")
check("vaio_detect 先判运行态再决定开控制设备",
      0 <= run_at < open_at)
check("vaio_detect 运行期版本走 start 缓存",
      "ver.DriverVersionMajor = g_vaio.drvVerMajor" in det_seg)
start_at = BRG.find("int vaio_start(")
start_seg = BRG[start_at:start_at + 5200]
check("vaio_start 在同一句柄上缓存驱动版本",
      "IOCTL_AURAVAIO_GET_VERSION" in start_seg
      and "g_vaio.drvVerMajor" in start_seg)

# 3. 桥：stop join 超时在解映射之前中止
stop_at = BRG.find("int vaio_stop()")
stop_seg = BRG[stop_at:stop_at + 2600]
tmo_at = stop_seg.find("WAIT_TIMEOUT")
unmap_at = stop_seg.find("UnmapAndCloseRing()")
check("vaio_stop 检 join 超时且在解映射前返回",
      0 <= tmo_at < unmap_at and "return -6" in stop_seg)

print("smoke_round6_vaio_unmap: " + ("FAIL" if fails else "PASS"))
sys.exit(1 if fails else 0)
