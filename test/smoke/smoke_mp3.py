"""smoke_mp3.py — MP3 解码链路验收（engine_audiofile.cpp + FFI + isolate 路由）。

验收标准：
  1. 不存在的文件 → null（不崩）。
  2. 手造静音 MP3（MPEG1-L3 128kbps/44.1kHz，全零主数据帧）→ rate=44100、
     frames>0、样点全有限、近静音。
  3. WAV 回归：decodeWav 路径不受影响（见 smoke_* 相关用例）。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


dll = ctypes.CDLL(DLL)
dll.auradsp_decode_audio_file.restype = ctypes.c_void_p
dll.auradsp_decode_audio_file.argtypes = [ctypes.c_char_p,
                                          ctypes.POINTER(ctypes.c_int32),
                                          ctypes.POINTER(ctypes.c_uint64)]
dll.auradsp_free_audio_buffer.argtypes = [ctypes.c_void_p]


def decode(path):
    rate = ctypes.c_int32(0)
    frames = ctypes.c_uint64(0)
    ptr = dll.auradsp_decode_audio_file(path.encode('utf-8'), ctypes.byref(rate),
                                        ctypes.byref(frames))
    return ptr, rate.value, frames.value


def make_silence_mp3(nframes=4):
    # MPEG1 Layer III，128kbps @44.1kHz，padding=1 → 418 字节/帧；
    # 边信息 + 主数据全零 → 解出静音（1152 样点/帧）。
    hdr = bytes([0xFF, 0xFB, 0x92, 0x00])
    return hdr + bytes(418 - 4) + (hdr + bytes(418 - 4)) * (nframes - 1) \
        if nframes > 1 else hdr + bytes(418 - 4)


# 1. 不存在的文件
p0, r0, f0 = decode('Z:\\no\\such\\file.mp3')
check('missing file -> null', p0 is None and r0 == 0 and f0 == 0,
      'ptr=%s rate=%d frames=%d' % (p0, r0, f0))

# 2. 手造静音 MP3
mp3_path = os.path.join(ROOT, 'test', 'smoke', '_tmp_silence.mp3')
with open(mp3_path, 'wb') as f:
    f.write(make_silence_mp3())
try:
    ptr, rate, frames = decode(mp3_path)
    check('silence decodes', ptr is not None and rate == 44100 and frames > 0,
          'rate=%d frames=%d' % (rate, frames))
    if ptr is not None:
        n = frames * 2
        buf = (ctypes.c_float * n).from_address(ptr)
        peak = 0.0
        ok = True
        for i in range(0, n, 997):
            v = buf[i]
            if not math.isfinite(v):
                ok = False
                break
            peak = max(peak, abs(v))
        check('samples finite', ok)
        check('near silence', peak < 0.05, 'peak=%.5f' % peak)
        dll.auradsp_free_audio_buffer(ptr)
finally:
    if os.path.exists(mp3_path):
        os.remove(mp3_path)

print()
if FAIL:
    print('MP3 FAILURES:', FAIL)
    sys.exit(1)
print('mp3: all checks passed')
