# smoke_vaio_clock_grid.py — VAIO 虚拟时钟帧格不变量门（白噪声专项 S3）。
#
# 定罪背景（docs/30-审查/VAIO白噪声专项S1审计-2026-11-12.md）：
# 驱动虚拟时钟推进任意字节时，停滞钳制/溢出修剪丢弃非帧倍数字节
# 会把共享环字节流旋转出帧格，int16 采样被读成字节序错位
# （ac1 −0.528 指纹）。根治 = Advance() 按 BlockAlign 量化推进。
#
# 本门把真实 VirtualClock.{h,cpp} 拷入 test/build/vaio-clock-grid/
# 配最小类型桩宿主编译，断言：① 任意 QPC 抖动/停滞序列下每次推进
# 量与双偏移恒为帧倍数；② 一小时模拟的长期速率误差 < 1 帧（量化
# 不丢速率）；③ 亚帧小步进累积仍单调且在格上；④ align 0/1 退化
# 不崩。另含两条源码断言钉住调用点传 align 与钳制贴帧。
# 无宿主编译器时 SKIP（与 smoke_apo_plan 同口径）。
import os
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers',
                   '01_vaio_driver', 'src')
BUILD = os.path.join(ROOT, 'test', 'build', 'vaio-clock-grid')

STUB = r'''
#ifndef _AURA_VAIO_H_
#define _AURA_VAIO_H_
// 宿主测试桩：仅提供 VirtualClock 需要的 Windows 基本类型。
#include <cstdint>
typedef uint64_t ULONGLONG;
typedef uint32_t ULONG;
typedef void VOID;
typedef uint8_t BOOLEAN;
#ifndef FALSE
#define FALSE 0
#define TRUE 1
#endif
#ifndef _In_
#define _In_
#endif
#endif
'''

MAIN = r'''
#include <cstdio>
#include <cstdlib>
#include "VirtualClock.h"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { \
    std::printf("FAIL: %s\n", msg); ++failures; } } while (0)

// 确定性伪随机（LCG），保证两平台同序列。
static uint64_t lcg = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(uint32_t n) {
    lcg = lcg * 6364136223846793005ull + 1442695040888963407ull;
    return (uint32_t)((lcg >> 33) % n);
}

static void runGridCase(ULONG rate, ULONG align, const char* name) {
    CAuraVirtualClock clk;
    clk.SetQpcFrequency(10000000ull); // 10 MHz QPC
    clk.Reset();
    ULONGLONG qpc = 1000000ull;
    clk.Start(qpc);
    for (int i = 0; i < 200000; ++i) {
        qpc += 1 + rnd(3000);                    // 0.1us..0.3ms 抖动
        if (i % 50000 == 49999) qpc += 50000000ull; // 5 s 停滞
        ULONG adv = clk.Advance(qpc, rate, align);
        CHECK(adv % align == 0, name);
        CHECK(clk.PlayOffset() % align == 0, name);
        CHECK(clk.WriteOffset() == clk.PlayOffset(), name);
    }
    std::printf("grid case %s done, offset=%llu\n", name,
                (unsigned long long)clk.PlayOffset());
}

int main() {
    runGridCase(192000, 4, "int16 stereo 48k");
    runGridCase(384000, 8, "float stereo 48k");
    runGridCase(96000, 2, "int16 mono 48k");
    runGridCase(576000, 12, "int16 6ch 48k");

    // 长期速率：3600 s 精确 QPC，不规则步进，总量误差 < 1 帧且不超前。
    {
        CAuraVirtualClock clk;
        clk.SetQpcFrequency(10000000ull);
        clk.Reset();
        ULONGLONG qpc = 0;
        clk.Start(qpc);
        const ULONGLONG target = 3600ull * 10000000ull;
        while (qpc < target) {
            ULONGLONG step = 1 + rnd(100000);
            if (qpc + step > target) step = target - qpc;
            qpc += step;
            clk.Advance(qpc, 192000, 4);
        }
        ULONGLONG exact = 3600ull * 192000ull;
        CHECK(clk.PlayOffset() <= exact, "rate: ahead of exact");
        CHECK(exact - clk.PlayOffset() < 4, "rate: lost more than a frame");
        std::printf("rate case offset=%llu exact=%llu\n",
                    (unsigned long long)clk.PlayOffset(),
                    (unsigned long long)exact);
    }

    // 亚帧小步进：1 tick/次 × 100k 次（每次不足 1 字节），累积须
    // 单调、在格上、总量逼近期望（192000*100000/1e7 = 1920 B）。
    {
        CAuraVirtualClock clk;
        clk.SetQpcFrequency(10000000ull);
        clk.Reset();
        ULONGLONG qpc = 0;
        clk.Start(qpc);
        ULONGLONG prev = 0;
        for (int i = 0; i < 100000; ++i) {
            qpc += 1;
            clk.Advance(qpc, 192000, 4);
            CHECK(clk.PlayOffset() >= prev, "tiny steps: not monotone");
            CHECK(clk.PlayOffset() % 4 == 0, "tiny steps: off grid");
            prev = clk.PlayOffset();
        }
        CHECK(prev <= 1920 && 1920 - prev < 4, "tiny steps: total drift");
    }

    // 退化：align 0/1 不量化、不崩，推进非零。
    {
        CAuraVirtualClock clk;
        clk.SetQpcFrequency(10000000ull);
        clk.Reset();
        clk.Start(0);
        ULONG a0 = clk.Advance(100000, 192000, 0);
        ULONG a1 = clk.Advance(200000, 192000, 1);
        CHECK(a0 > 0 && a1 > 0, "degenerate align: no advance");
    }

    std::printf(failures ? "CLOCK GRID: FAIL (%d)\n" : "CLOCK GRID: ALL PASS\n",
                failures);
    return failures ? 1 : 0;
}
'''


def check(cond, detail):
    print(('PASS  ' if cond else 'FAIL  ') + detail)
    return cond


def main():
    ok = True

    stream = open(os.path.join(SRC, 'MiniportWaveRTStream.cpp'),
                  encoding='utf-8', errors='replace').read()
    clock = open(os.path.join(SRC, 'VirtualClock.cpp'),
                 encoding='utf-8', errors='replace').read()
    ok &= check('Advance(QpcNow, m_ulBytesPerSecond, m_ulBlockAlign)' in stream,
                '调用点：AdvanceAndCopyLocked 传现行 BlockAlign')
    ok &= check('bytesToProcess -= bytesToProcess % m_ulBlockAlign' in stream,
                '钳制：bytesToProcess 向下贴帧（丢弃量恒帧倍数）')
    ok &= check('BytesAdvanced -= BytesAdvanced % BlockAlign' in clock,
                '时钟：Advance 按 BlockAlign 量化推进量')

    cxx = None
    for cand in ('g++', 'clang++', 'c++'):
        if shutil.which(cand):
            cxx = cand
            break
    if cxx is None:
        print('smoke_vaio_clock_grid: SKIP (no host C++ compiler)')
        return 0 if ok else 1

    os.makedirs(BUILD, exist_ok=True)
    for f in ('VirtualClock.h', 'VirtualClock.cpp'):
        shutil.copy(os.path.join(SRC, f), os.path.join(BUILD, f))
    with open(os.path.join(BUILD, 'AuraVaio.h'), 'w', encoding='utf-8') as fh:
        fh.write(STUB)
    with open(os.path.join(BUILD, 'main.cpp'), 'w', encoding='utf-8') as fh:
        fh.write(MAIN)
    exe = os.path.join(BUILD, 'vaio_clock_grid_test')
    r = subprocess.run([cxx, '-std=c++17', '-O1', '-o', exe,
                        os.path.join(BUILD, 'main.cpp'),
                        os.path.join(BUILD, 'VirtualClock.cpp')],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        ok &= check(False, '宿主编译失败')
    else:
        r = subprocess.run([exe], capture_output=True, text=True, timeout=120)
        sys.stdout.write(r.stdout)
        if r.stderr:
            sys.stderr.write(r.stderr)
        ok &= check(r.returncode == 0, '时钟帧格不变量实跑')

    print('smoke_vaio_clock_grid: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
