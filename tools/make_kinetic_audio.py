#!/usr/bin/env python3
"""Soundtrack for the KineticType scene (42s).

Intro 0-2.4 | 13 chapters x 2.4s (2.4..33.6, crash per chapter) | recap build
33.6-36.0 | outro 36.0-42.0. Keep in sync with KineticType.swift.

Usage: python3 tools/make_kinetic_audio.py out/kinetic-type.wav
"""
import sys
import wave

import numpy as np

SR = 44100
DUR = 42.0
N = int(SR * DUR)

L = np.zeros(N)   # ducked bus (bass, hats, claps, drone, risers, crashes)
R = np.zeros(N)
KL = np.zeros(N)  # clean bus (kicks, booms) — never ducked, transients intact
KR = np.zeros(N)
kick_times = []  # collected for the sidechain pump


def add(sig, start, pan=0.0, clean=False):
    i = int(start * SR)
    j = min(N, i + len(sig))
    if i >= N or j <= i:
        return
    seg = sig[: j - i]
    if clean:
        KL[i:j] += seg * (1 - max(0, pan))
        KR[i:j] += seg * (1 + min(0, pan))
    else:
        L[i:j] += seg * (1 - max(0, pan))
        R[i:j] += seg * (1 + min(0, pan))


def env_exp(n, rate):
    return np.exp(-np.arange(n) / SR * rate)


def kick(amp=1.0, sweep=(150, 44), dur=0.4, sidechain=True, t0=None):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    freq = sweep[1] + (sweep[0] - sweep[1]) * np.exp(-tt * 26)
    body = np.sin(2 * np.pi * np.cumsum(freq) / SR) * env_exp(n, 12)
    click = np.random.RandomState(7).randn(n) * env_exp(n, 230) * 0.35
    if sidechain and t0 is not None:
        kick_times.append(t0)
    return np.tanh((body + click) * 2.3) * amp


def clap(amp=0.5, seed=21):
    n = int(0.28 * SR)
    rs = np.random.RandomState(seed)
    out = np.zeros(n)
    for k, off in enumerate([0.0, 0.011, 0.023]):     # classic 3-burst clap
        i = int(off * SR)
        burst = np.diff(rs.randn(n - i), prepend=0) * env_exp(n - i, 70 if k == 2 else 220)
        out[i:] += burst
    return out * amp


def hat(amp=0.1, dur=0.05, seed=3):
    n = int(dur * SR)
    return np.diff(np.random.RandomState(seed).randn(n), prepend=0) * env_exp(n, 95) * amp


def crash(amp=0.3, dur=0.9, seed=51):
    n = int(dur * SR)
    return np.diff(np.random.RandomState(seed).randn(n), prepend=0) * env_exp(n, 6) * amp


def bass_note(freq, amp=0.32, dur=0.5):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    sig = np.sin(2 * np.pi * freq * tt) + 0.35 * np.sin(2 * np.pi * freq * 2 * tt)
    a = np.minimum(1, tt / 0.006)
    rel = np.minimum(1, (dur - tt) / 0.08)
    return np.tanh(sig * 1.6) * a * rel * amp


def riser(amp=0.55, dur=3.4):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    freq = 160 + (1500 - 160) * (tt / dur) ** 2
    tone = np.sin(2 * np.pi * np.cumsum(freq) / SR) * 0.45
    noise = np.random.RandomState(5).randn(n) * 0.55
    return (tone + noise) * (tt / dur) ** 2.4 * amp


def boom(amp=1.0, dur=2.6):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    freq = 36 + 32 * np.exp(-tt * 13)
    sub = np.sin(2 * np.pi * np.cumsum(freq) / SR) * env_exp(n, 2.2)
    return np.tanh(sub * 2.8) * amp


def drone(amp=0.15, dur=7.0, f=55.0, seed=9):
    n = int(dur * SR)
    tt = np.arange(n) / SR
    lfo = 0.7 + 0.3 * np.sin(2 * np.pi * 0.55 * tt)
    sig = (np.sin(2 * np.pi * f * tt) + 0.5 * np.sin(2 * np.pi * f * 1.5 * tt + 0.7)) * lfo
    fade = np.minimum(1, tt / 0.8) * np.minimum(1, (dur - tt) / 1.2)
    return sig * fade * amp


def whoosh(amp=0.5, dur=0.7, rising=True, seed=11):
    n = int(dur * SR)
    tt = np.arange(n) / n
    noise = np.random.RandomState(seed).randn(n)
    csum = np.cumsum(np.concatenate(([0], noise)))
    win = (58 - 50 * tt) if rising else (8 + 50 * tt)
    out = np.zeros(n)
    for i in range(n):
        w = max(2, int(win[i]))
        out[i] = (csum[i + 1] - csum[max(0, i - w)]) / (i + 1 - max(0, i - w))
    return out * (np.sin(np.pi * tt) ** 1.5) * amp * 6




# ---- intro 0-2.4: ticks + short build --------------------------------------
for i, tk in enumerate([0.3, 0.9, 1.5]):
    add(hat(0.1, seed=20 + i), tk, pan=0.4 if i % 2 else -0.4)
add(kick(0.6, sweep=(120, 48), t0=1.8), 1.8, clean=True)
add(whoosh(0.5, 0.5, rising=True), 1.95)

# ---- drop 2.4, groove to 33.6 ----------------------------------------------
add(boom(0.8, 1.5), 2.4, clean=True)
add(crash(0.34), 2.4)
BASS = [55.0, 55.0, 65.41, 48.99]
tk, i = 2.4, 0
while tk < 33.59:
    add(kick(0.95, t0=tk), tk, clean=True)
    add(bass_note(BASS[i % 4], dur=0.5), tk + 0.02)
    if i % 2 == 1:
        add(clap(0.4, seed=30 + (i % 5)), tk, pan=0.18)
    tk += 0.6
    i += 1
tk, i = 2.4, 0
while tk < 33.6:
    add(hat(0.05 if i % 2 else 0.085, seed=40 + (i % 9)), tk, pan=0.5 if i % 2 else -0.5)
    tk += 0.15
    i += 1
for k in range(1, 14):
    add(crash(0.26, seed=100 + k), 2.4 + 2.4 * k)

# ---- recap build 33.6-36.0: accelerating kicks + riser ----------------------
add(riser(0.6, 2.4), 33.6)
for tk in [33.6, 33.9, 34.2, 34.5, 34.8, 35.1, 35.35, 35.6, 35.8]:
    add(kick(0.85, sweep=(150, 46), t0=tk), tk, clean=True)

# ---- finale 36.0 + outro ----------------------------------------------------
add(boom(1.0), 36.0, clean=True)
add(crash(0.36, seed=77), 36.0)
for tk in [36.6, 37.2]:
    add(kick(0.9, sweep=(170, 40), t0=tk), tk, clean=True)
add(drone(0.14, 5.4, f=55.0), 36.6)
add(hat(0.1, seed=99), 38.4)

# ---- master ------------------------------------------------------------------
t_axis = np.arange(N) / SR
duck = np.ones(N)
for tk in kick_times:
    i0 = int(tk * SR)
    n = int(0.42 * SR)
    j = min(N, i0 + n)
    seg = np.arange(j - i0) / SR
    duck[i0:j] = np.minimum(duck[i0:j], 1 - 0.5 * np.exp(-seg / 0.11))
mix = np.stack([L * duck + KL, R * duck + KR])
mix = np.tanh(mix * 1.15)
fade_n = int(1.2 * SR)
mix[:, -fade_n:] *= np.linspace(1, 0, fade_n)
mix = mix / np.abs(mix).max() * 0.92

out = sys.argv[1] if len(sys.argv) > 1 else "out/kinetic-type.wav"
pcm = (mix.T * 32767).astype(np.int16)
with wave.open(out, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(f"wrote {out} ({DUR}s, {len(kick_times)} kicks)")
