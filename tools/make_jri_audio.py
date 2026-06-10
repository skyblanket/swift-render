#!/usr/bin/env python3
"""Synthesize the beat track for the JustRenderIt scene.

Every hit time below mirrors a timeline anchor in
Sources/SwiftRender/Scenes/JustRenderIt.swift — keep them in sync.

Usage: python3 tools/make_jri_audio.py out/jri.wav
"""
import sys
import wave

import numpy as np

SR = 44100
DUR = 15.0
N = int(SR * DUR)
t_axis = np.arange(N) / SR

L = np.zeros(N)
R = np.zeros(N)


def add(sig, start, pan=0.0):
    """Mix `sig` into the master at `start` seconds. pan in [-1, 1]."""
    i = int(start * SR)
    j = min(N, i + len(sig))
    if i >= N:
        return
    seg = sig[: j - i]
    L[i:j] += seg * (1 - max(0, pan))
    R[i:j] += seg * (1 + min(0, pan))


def env_exp(n, rate):
    return np.exp(-np.arange(n) / SR * rate)


def kick(amp=1.0, sweep=(150, 42), dur=0.45):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    freq = sweep[1] + (sweep[0] - sweep[1]) * np.exp(-tt * 28)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    body = np.sin(phase) * env_exp(n, 11)
    click = np.random.RandomState(7).randn(n) * env_exp(n, 220) * 0.4
    return np.tanh((body + click) * 2.2) * amp


def hat(amp=0.15, dur=0.06, seed=3):
    n = int(dur * SR)
    noise = np.random.RandomState(seed).randn(n)
    bright = np.diff(noise, prepend=0)  # crude highpass
    return bright * env_exp(n, 90) * amp


def whoosh(amp=0.5, dur=0.7, rising=True, seed=11):
    n = int(dur * SR)
    tt = np.arange(n) / n
    noise = np.random.RandomState(seed).randn(n)
    # moving-average lowpass whose window shrinks (rising) or grows (falling)
    out = np.zeros(n)
    win = (60 - 52 * tt) if rising else (8 + 52 * tt)
    csum = np.cumsum(np.concatenate(([0], noise)))
    for i in range(n):
        w = max(2, int(win[i]))
        a, b = max(0, i - w), i
        out[i] = (csum[b + 1] - csum[a]) / (b + 1 - a)
    shape = np.sin(np.pi * tt) ** 1.5
    return out * shape * amp * 6


def riser(amp=0.5, dur=1.1):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    freq = 180 + (1300 - 180) * (tt / dur) ** 2
    phase = 2 * np.pi * np.cumsum(freq) / SR
    tone = np.sin(phase) * 0.5
    noise = np.random.RandomState(5).randn(n) * 0.5
    grow = (tt / dur) ** 2.2
    return (tone + noise) * grow * amp


def boom(amp=1.0, dur=2.3):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    freq = 38 + 30 * np.exp(-tt * 14)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    sub = np.sin(phase) * env_exp(n, 2.6)
    harm = np.sin(phase * 2) * env_exp(n, 5) * 0.25
    return np.tanh((sub + harm) * 2.6) * amp


def drone(amp=0.16, dur=2.7, f=55.0):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    lfo = 0.7 + 0.3 * np.sin(2 * np.pi * 0.9 * tt)
    sig = (np.sin(2 * np.pi * f * tt) + 0.4 * np.sin(2 * np.pi * f * 1.5 * tt)) * lfo
    fade = np.minimum(1, tt / 0.4) * np.minimum(1, (dur - tt) / 0.6)
    return sig * fade * amp


# ---- cold open: ticks + heartbeat build (0.0–2.2) -------------------------
for i, tk in enumerate([0.55, 1.10, 1.65]):
    add(hat(0.12, seed=20 + i), tk, pan=0.4 if i % 2 else -0.4)
for tk, a in [(0.6, 0.35), (1.35, 0.5), (2.0, 0.65)]:
    add(kick(a, sweep=(110, 45)), tk)

# ---- slam quad: one hard kick per phrase (2.2–5.4) ------------------------
for tk in [2.2, 3.0, 3.8, 4.6]:
    add(kick(1.0), tk)
    add(hat(0.18, seed=int(tk * 10)), tk + 0.4, pan=0.3)

# ---- speed: whoosh in, driving 16th hats, kicks (5.4–8.2) -----------------
add(whoosh(0.55, 0.7, rising=True), 4.95)
tk = 5.4
i = 0
while tk < 8.2:
    add(hat(0.07 if i % 2 else 0.11, seed=40 + i), tk, pan=0.5 if i % 2 else -0.5)
    tk += 0.2
    i += 1
for tk in [5.4, 6.2, 7.0, 7.8]:
    add(kick(0.85), tk)

# ---- texture: whoosh down, low drone, riser into finale (8.2–10.8) --------
add(whoosh(0.5, 0.7, rising=False, seed=13), 7.95)
add(boom(0.5, 1.2), 8.2)
add(drone(0.16, 2.7), 8.2)
add(riser(0.55, 1.1), 9.7)

# ---- finale slams + 808 boom on lockup (10.8–13.4) ------------------------
for tk in [10.8, 11.35, 11.9]:
    add(kick(1.0, sweep=(170, 40)), tk)
add(boom(1.0), 12.45)
add(hat(0.10, seed=99), 13.4)

# ---- master: gentle soft-clip + fade tail ---------------------------------
mix = np.stack([L, R])
mix = np.tanh(mix * 1.1)
fade_n = int(0.8 * SR)
mix[:, -fade_n:] *= np.linspace(1, 0, fade_n)
peak = np.abs(mix).max()
mix = mix / peak * 0.92

out_path = sys.argv[1] if len(sys.argv) > 1 else "out/jri.wav"
pcm = (mix.T * 32767).astype(np.int16)
with wave.open(out_path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(f"wrote {out_path} ({DUR}s, peak {peak:.2f})")
