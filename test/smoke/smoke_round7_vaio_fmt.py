#!/usr/bin/env python3
"""第七轮项 6 定罪契约：切歌换格式时 VAIO 泵不得按旧帧长永久错位。

证据链（2026-11-11 代码取证）：
- 共享环字节没有格式边界/代次；新流 Init 先覆盖共享头几何，环里
  未消费的旧格式字节仍在原处；
- 旧泵实现逐轮跟随几何变量（声道/位深/采样率都读），但消费游标
  userBytesRead 从不重对齐：帧长（声道×位深）一变，游标相对新
  帧长的模偏移永久存在（消费增量恒为新帧长整数倍、永不自愈），
  呈持续白噪声、只能重启桥恢复；
- 几何字段分三次直读、无一致性快照，恰在内核更新瞬间可读到
  混合元组；
- 驱动 MiniportWaveRTStream::SetFormat 是空实现：流原地换格式
  时共享头永远停在旧格式。

本门钉四处修复（任一回退即红）：
1. 泵几何读取走一致性快照（连读两遍比对元组）；
2. 帧长相关变化（声道/位深）→ 游标重对齐到最新写入位置
   （弃旧格式尾巴）且计数 fmtResyncs；
3. fmtResyncs 在 status 中恒输出、start 时清零；
4. 驱动 SetFormat 镜像 Init 发布新几何（OnFormatChange 至少两处）。
"""
import pathlib
import sys

try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = pathlib.Path(__file__).resolve().parents[2]
BRG = (ROOT / "core/desktop/windows-drivers/bridge/vaio_bridge/VaioBridge.cpp").read_text(encoding="utf-8", errors="replace")
DRV = (ROOT / "core/desktop/windows-drivers/01_vaio_driver/src/MiniportWaveRTStream.cpp").read_text(encoding="utf-8", errors="replace")

fails = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


# 1. 一致性快照
check("泵几何一致性快照（snapConsistent）", "snapConsistent" in BRG
      and "snapCh == pHeader->Channels" in BRG
      and "snapBits == pHeader->BitsPerSample" in BRG)

# 2. 帧长变化 → 游标重对齐 + 计数（取 frameShapeChanged 窗口核对）
at = BRG.find("frameShapeChanged")
seg = BRG[at:at + 3200] if at >= 0 else ""
check("帧长变化分支存在", at >= 0)
check("重对齐：游标对齐最新写入位置（弃旧尾巴）",
      "userBytesRead = pHeader->TotalBytesWritten" in seg)
check("重对齐计数 fmtResyncs++",
      "InterlockedIncrement(&g_vaio.fmtResyncs)" in seg)
check("重对齐清重采样相位", "fracPhase = 0.0" in seg)

# 3. status 恒输出 + start 清零
check("status 输出 fmtResyncs", '"fmtResyncs"' in BRG
      or '\\"fmtResyncs\\"' in BRG)
check("start 清零 fmtResyncs",
      "InterlockedExchange(&g_vaio.fmtResyncs, 0)" in BRG)

# 4. 驱动 SetFormat 发布新几何
check("SetFormat 镜像 Init 发布几何（OnFormatChange x2+）",
      DRV.count("AuraControlDevice_OnFormatChange") >= 2)
sf = DRV.find("CMiniportWaveRTStream::SetFormat")
sf_seg = DRV[sf:sf + 2400] if sf >= 0 else ""
check("SetFormat 段内含几何发布与成员更新",
      "AuraControlDevice_OnFormatChange" in sf_seg
      and "m_ulBlockAlign" in sf_seg)

print("smoke_round7_vaio_fmt: %s (%d fails)" % ("FAIL" if fails else "PASS", len(fails)))
sys.exit(1 if fails else 0)
