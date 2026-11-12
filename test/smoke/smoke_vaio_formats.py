# smoke_vaio_formats.py — VAIO 格式升级一期门（24 位/容器格式/环扩容）。
#
# 背景（docs/10-架构/VAIO驱动格式升级一期计划书-2026-11-12.md）：
# 一期之前桥靠引脚表「32 位恒 float、16 位恒 PCM」的隐含契约按位深
# 分发转换；24 位（紧密 3 字节与 24-in-32 容器）要求格式类别与有效
# 位深显式化：驱动引脚表加 PCM 24/32-container 范围、交集 resultant
# 回写客户端有效位深、共享头发布 FormatKind/ValidBitsPerSample、桥
# 按 (kind, 容器位深, 有效位深) 转换（实现抽 VaioSampleConvert.h）。
#
# 本门：① 把真实 VaioSampleConvert.h 宿主编译实跑数值断言（四种格
# 式的满幅/半幅/符号扩展/有效位深截断 + 支持矩阵 + 旧驱动推断）；
# ② 源码断言钉住驱动/桥的关键接线（范围计数、validBits 回写、环
# 288 贴格、泵按格式模型设门）。无宿主编译器时数值部分 SKIP
# （与 smoke_vaio_clock_grid 同口径），源码断言恒跑。
import os
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DRV = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers',
                   '01_vaio_driver', 'src')
BRG = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers',
                   'bridge', 'vaio_bridge')
IPC = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers',
                   'common', 'AuraVaioIpc.h')
BUILD = os.path.join(ROOT, 'test', 'build', 'vaio-formats')

MAIN = r'''
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "VaioSampleConvert.h"

static int failures = 0;
static void chkFloat(float got, float want, const char* msg) {
    if (std::fabs((double)got - (double)want) > 1e-6) {
        std::printf("FAIL: %s (got %.9g want %.9g)\n", msg,
                    (double)got, (double)want);
        ++failures;
    }
}
static void chkBool(bool got, bool want, const char* msg) {
    if (got != want) {
        std::printf("FAIL: %s (supported=%d want %d)\n", msg, (int)got, (int)want);
        ++failures;
    }
}

// kind: 0=unspec 1=PCM 2=float（与 AuraVaioIpc.h 的 AURA_VAIO_FMT_* 一致）
int main() {
    float out[8];

    // PCM16：历史口径 int16 * 1/32768
    {
        const int16_t s[4] = {16384, -16384, 32767, -32768};
        VaioConvertRingToFloat((const unsigned char*)s, out, 2, 2, 1, 16, 0);
        chkFloat(out[0], 0.5f, "pcm16 +0.5");
        chkFloat(out[1], -0.5f, "pcm16 -0.5");
        chkFloat(out[2], 32767.0f / 32768.0f, "pcm16 max");
        chkFloat(out[3], -1.0f, "pcm16 min");
    }
    // float32 直通
    {
        const float s[2] = {0.5f, -0.25f};
        VaioConvertRingToFloat((const unsigned char*)s, out, 1, 2, 2, 32, 0);
        chkFloat(out[0], 0.5f, "float +0.5");
        chkFloat(out[1], -0.25f, "float -0.25");
    }
    // PCM24 紧密：小端 3 字节、符号扩展、/2^23（双声道交织验步长）
    {
        const unsigned char s[6] = {0x00, 0x00, 0x40,   // ch0: 0x400000 -> +0.5
                                    0x00, 0x00, 0x80};  // ch1: 0x800000 -> -1.0
        VaioConvertRingToFloat(s, out, 1, 2, 1, 24, 24);
        chkFloat(out[0], 0.5f, "pcm24 packed +0.5");
        chkFloat(out[1], -1.0f, "pcm24 packed sign-extend min");
        const unsigned char m[3] = {0xFF, 0xFF, 0x7F};  // 0x7FFFFF
        VaioConvertRingToFloat(m, out, 1, 1, 1, 24, 0);
        chkFloat(out[0], 8388607.0f / 8388608.0f, "pcm24 packed max");
    }
    // PCM 32 容器、有效 24（24-in-32）：取高 24 位
    {
        const int32_t s[3] = {0x40000000, (int32_t)0x80000000, 0x7FFFFF00};
        VaioConvertRingToFloat((const unsigned char*)s, out, 3, 1, 1, 32, 24);
        chkFloat(out[0], 0.5f, "in32 valid24 +0.5");
        chkFloat(out[1], -1.0f, "in32 valid24 min");
        chkFloat(out[2], 8388607.0f / 8388608.0f, "in32 valid24 max");
    }
    // PCM 32 容器、有效 32（真 int32）与有效 20/16 的通式
    {
        const int32_t s[1] = {0x40000000};
        VaioConvertRingToFloat((const unsigned char*)s, out, 1, 1, 1, 32, 32);
        chkFloat(out[0], 0.5f, "in32 valid32 +0.5");
        VaioConvertRingToFloat((const unsigned char*)s, out, 1, 1, 1, 32, 20);
        chkFloat(out[0], 0.5f, "in32 valid20 +0.5");
        VaioConvertRingToFloat((const unsigned char*)s, out, 1, 1, 1, 32, 16);
        chkFloat(out[0], 0.5f, "in32 valid16 +0.5");
    }
    // 旧驱动推断（kind=0）：32 -> float、16 -> PCM16
    {
        const float f[1] = {0.5f};
        VaioConvertRingToFloat((const unsigned char*)f, out, 1, 1, 0, 32, 0);
        chkFloat(out[0], 0.5f, "legacy infer float");
        const int16_t s[1] = {16384};
        VaioConvertRingToFloat((const unsigned char*)s, out, 1, 1, 0, 16, 0);
        chkFloat(out[0], 0.5f, "legacy infer pcm16");
    }
    // 支持矩阵
    chkBool(VaioRingFormatSupported(0, 16, 0), true,  "sup legacy 16");
    chkBool(VaioRingFormatSupported(0, 32, 0), true,  "sup legacy 32");
    chkBool(VaioRingFormatSupported(0, 24, 0), false, "sup legacy 24 unknown");
    chkBool(VaioRingFormatSupported(1, 16, 16), true,  "sup pcm16");
    chkBool(VaioRingFormatSupported(1, 24, 24), true,  "sup pcm24 packed");
    chkBool(VaioRingFormatSupported(1, 32, 24), true,  "sup 24-in-32");
    chkBool(VaioRingFormatSupported(1, 32, 32), true,  "sup int32");
    chkBool(VaioRingFormatSupported(1, 32, 20), true,  "sup 20-in-32");
    chkBool(VaioRingFormatSupported(2, 32, 0),  true,  "sup float32");
    chkBool(VaioRingFormatSupported(2, 16, 0),  false, "sup float16 nonsense");
    chkBool(VaioRingFormatSupported(1, 16, 24), false, "sup valid>container");
    chkBool(VaioRingFormatSupported(1, 24, 16), false, "sup packed24 valid16");
    chkBool(VaioRingFormatSupported(9, 32, 32), false, "sup unknown kind");

    std::printf(failures ? "VAIO FORMATS: FAIL (%d)\n" : "VAIO FORMATS: ALL PASS\n",
                failures);
    return failures ? 1 : 0;
}
'''


def check(cond, detail):
    print(('PASS  ' if cond else 'FAIL  ') + detail)
    return cond


def read(path):
    return open(path, encoding='utf-8', errors='replace').read()


def main():
    ok = True

    tables = read(os.path.join(DRV, 'AuraVaoTables.h'))
    ok &= check(tables.count('sizeof(KSDATARANGE_AUDIO),') == 16,
                '引脚表：streaming 范围共 16 条（8 旧 + 8 新）')
    ok &= check(tables.count('24, 24,') == 4,
                '引脚表：PCM24 紧密范围 4 条（2/4/6/8 声道）')
    ok &= check(tables.count('32-bit PCM container') == 4,
                '引脚表：PCM 32 容器范围 4 条（2/4/6/8 声道）')

    inter = read(os.path.join(DRV, 'MiniportWaveRT.cpp'))
    ok &= check('Samples.wValidBitsPerSample' in inter and
                'reqValidBits = clientWfe' in inter,
                '交集：读取客户端 wValidBitsPerSample')
    ok &= check('wValidBitsPerSample = (WORD)reqValidBits' in inter,
                '交集：resultant 回写有效位深（非容器位深）')

    ctrl = read(os.path.join(DRV, 'ControlDevice.cpp'))
    ok &= check('g_ulRingDataSize' in ctrl and
                'AURA_VAIO_RING_DATA_ALIGNMENT' in ctrl,
                '环：dataSize 内核真值按 288 贴格')
    stream = read(os.path.join(DRV, 'MiniportWaveRTStream.cpp'))
    ok &= check(stream.count('AuraExtractFormatKind') >= 3,
                '流：格式类别/有效位深提取（定义 + Init/SetFormat 两调用）')

    ipc = read(IPC)
    ok &= check('(1024 * 1024)' in ipc and 'AURA_VAIO_FMT_PCM' in ipc and
                'AURA_VAIO_FMT_FLOAT' in ipc,
                'IPC：环 1MiB + FormatKind 常量在位')

    bridge = read(os.path.join(BRG, 'VaioBridge.cpp'))
    ok &= check('VaioRingFormatSupported(ringFmtKind, ringBits, ringValidBits)'
                in bridge,
                '桥：泵按格式模型设门（不支持的组合诚实失败）')
    ok &= check('snapKind == pHeader->FormatKind' in bridge,
                '桥：几何元组含 FormatKind（同形切换可察觉）')

    cxx = None
    for cand in ('g++', 'clang++', 'c++'):
        if shutil.which(cand):
            cxx = cand
            break
    if cxx is None:
        print('smoke_vaio_formats: SKIP numeric part (no host C++ compiler)')
    else:
        os.makedirs(BUILD, exist_ok=True)
        shutil.copy(os.path.join(BRG, 'VaioSampleConvert.h'),
                    os.path.join(BUILD, 'VaioSampleConvert.h'))
        with open(os.path.join(BUILD, 'main.cpp'), 'w', encoding='utf-8') as fh:
            fh.write(MAIN)
        exe = os.path.join(BUILD, 'vaio_formats_test')
        r = subprocess.run([cxx, '-std=c++17', '-O1', '-o', exe,
                            os.path.join(BUILD, 'main.cpp')],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            print(r.stdout)
            print(r.stderr)
            ok &= check(False, '宿主编译失败')
        else:
            r = subprocess.run([exe], capture_output=True, text=True,
                               timeout=120)
            sys.stdout.write(r.stdout)
            if r.stderr:
                sys.stderr.write(r.stderr)
            ok &= check(r.returncode == 0, '格式转换数值实跑')

    print('smoke_vaio_formats: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
