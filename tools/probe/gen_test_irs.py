# -*- coding: utf-8 -*-
import math, struct, os, random

DIR = r"D:\temp_desktop\Proj\JamesDSP\.tmp\irtest"
os.makedirs(DIR, exist_ok=True)

def write_wavf32(path, ch_data, rate):
    nch = len(ch_data)
    n = len(ch_data[0])
    bps = 4
    data = b"".join(struct.pack("<" + "f" * nch, *[ch_data[c][i] for c in range(nch)])
                    for i in range(n))
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 3, nch, rate, rate * nch * bps, nch * bps, bps * 8)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr + data)

def make_realistic_ir(n_frames, decay_factor, hf_damp, random_seed=42):
    random.seed(random_seed)
    samples = [0.0] * n_frames
    # Direct sound
    samples[0] = 0.95
    # Early reflections and late diffuse tail
    prev = 0.0
    for i in range(1, n_frames):
        t = i / 48000.0
        env = math.exp(-decay_factor * t)
        noise = (random.random() * 2.0 - 1.0) * env
        # One-pole lowpass
        filtered = prev * hf_damp + noise * (1.0 - hf_damp)
        prev = filtered
        samples[i] = filtered
    return samples

# 1. 2 声道真实混响 IR (48kHz, 0.5s = 24000 帧)
N = 24000
ir_l = make_realistic_ir(N, 14.0, 0.65, 101)
ir_r = make_realistic_ir(N, 13.5, 0.70, 202)
write_wavf32(os.path.join(DIR, "room_stereo.wav"), [ir_l, ir_r], 48000)

# 2. 4 声道环绕混响 IR (48kHz, 0.6s)
N4 = 28800
ir_4ch_l  = make_realistic_ir(N4, 12.0, 0.60, 301)
ir_4ch_r  = make_realistic_ir(N4, 11.8, 0.62, 302)
ir_4ch_sl = make_realistic_ir(N4, 10.5, 0.75, 303)
ir_4ch_sr = make_realistic_ir(N4, 10.2, 0.78, 304)
write_wavf32(os.path.join(DIR, "hall_4ch.wav"), [ir_4ch_l, ir_4ch_r, ir_4ch_sl, ir_4ch_sr], 48000)

print("Generated room_stereo.wav and hall_4ch.wav successfully!")
