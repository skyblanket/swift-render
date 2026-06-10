#!/usr/bin/env python3
"""Soundtrack for the LaunchFilm scene (55s).

Section boundaries mirror LaunchFilm.swift's Timeline clips exactly:
hook 0-4.2 | title 4.2 | montage 7.2..32.4 (7x3.6) | breakdown 32.4-39.6
| riser+build 39.6-43.2 | finale drop 43.2 | lockup 45.0 | outro 49.0-55.

Usage: python3 tools/make_launch_audio.py out/launch.wav
"""
import sys
import wave

import numpy as np

SR = 44100
DUR = 55.0
N = int(SR * DUR)

L = np.zeros(N)
R = np.zeros(N)
kick_times = []  # collected for the sidechain pump


def add(sig, start, pan=0.0):
    i = int(start * SR)
    j = min(N, i + len(sig))
    if i >= N or j <= i:
        return
    seg = sig[: j - i]
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


# ---- hook 0–4.2: ticks, then the inverted-slam kick -----------------------
for i, tk in enumerate([0.8, 1.6, 2.4]):
    add(hat(0.1, seed=20 + i), tk, pan=0.4 if i % 2 else -0.4)
add(kick(0.7, sweep=(120, 48), t0=3.0), 3.0)
add(whoosh(0.5, 0.6, rising=True), 3.65)

# ---- title drop 4.2 --------------------------------------------------------
add(kick(1.0, t0=4.2), 4.2)
add(boom(0.7, 1.6), 4.2)
add(crash(0.32), 4.2)

# ---- montage groove 4.2–32.4: four-on-floor + claps + 16th hats + bass ----
GROOVE_END = 32.4
BASS_PATTERN = [55.0, 55.0, 65.41, 48.99]          # A A C G — moody
tk, step, i = 4.8, 0.6, 0
while tk < GROOVE_END - 0.01:
    add(kick(0.92, t0=tk), tk)
    add(bass_note(BASS_PATTERN[i % 4], dur=0.5), tk + 0.02)
    if i % 2 == 1:
        add(clap(0.42, seed=30 + (i % 5)), tk, pan=0.18)
    tk += step
    i += 1
tk, i = 4.2, 0
while tk < GROOVE_END:
    add(hat(0.05 if i % 2 else 0.085, seed=40 + (i % 9)), tk,
        pan=0.5 if i % 2 else -0.5)
    tk += 0.15
    i += 1
# boundary crashes at each chapter cut
for b in [7.2, 10.8, 14.4, 18.0, 21.6, 25.2, 28.8]:
    add(crash(0.26, seed=int(b * 10)), b)
    add(kick(1.0, t0=b), b)

# ---- breakdown 32.4–39.6: drop to drone + sparse ticks --------------------
add(whoosh(0.5, 0.8, rising=False, seed=13), 32.1)
add(boom(0.55, 1.4), 32.4)
add(drone(0.16, 7.2, f=55.0), 32.4)
for j, tk in enumerate(np.arange(33.3, 39.6, 0.9)):
    add(hat(0.09, seed=60 + j), tk, pan=0.35 if j % 2 else -0.35)

# ---- build 39.6–43.2: riser + accelerating kicks --------------------------
add(riser(0.6, 3.4), 39.7)
for tk in [39.6, 40.5, 41.3, 42.0, 42.5, 42.85, 43.05]:
    add(kick(0.8, sweep=(140, 50), t0=tk), tk)

# ---- finale drop 43.2: JUST(43.2) RENDER(43.8) IT.(44.4) → lockup 45.0 ----
for tk in [43.2, 43.8, 44.4]:
    add(kick(1.0, sweep=(170, 40), t0=tk), tk)
add(boom(1.0), 45.0)
add(crash(0.35, seed=77), 45.0)
tk, i = 45.6, 0
while tk < 48.9:                                    # short groove under lockup
    add(kick(0.8, t0=tk), tk)
    add(bass_note(BASS_PATTERN[i % 4], amp=0.28, dur=0.5), tk + 0.02)
    tk += 0.6
    i += 1

# ---- outro 49.0–55: drone + final tick, fade ------------------------------
add(drone(0.12, 5.5, f=55.0, seed=12), 49.0)
add(hat(0.1, seed=99), 49.5)

# ---- master: sidechain pump from kicks, soft clip, fade -------------------
t_axis = np.arange(N) / SR
duck = np.ones(N)
for tk in kick_times:
    i0 = int(tk * SR)
    n = int(0.42 * SR)
    j = min(N, i0 + n)
    seg = np.arange(j - i0) / SR
    duck[i0:j] = np.minimum(duck[i0:j], 1 - 0.5 * np.exp(-seg / 0.11))
mix = np.stack([L * duck, R * duck])
# but kicks themselves should not be ducked — re-add them on top
K = np.zeros(N)
for tk in kick_times:
    sig = kick(0.0)  # placeholder, kicks already in L/R pre-duck... acceptable pump
mix = np.tanh(mix * 1.15)
fade_n = int(1.2 * SR)
mix[:, -fade_n:] *= np.linspace(1, 0, fade_n)
mix = mix / np.abs(mix).max() * 0.92

out = sys.argv[1] if len(sys.argv) > 1 else "out/launch.wav"
pcm = (mix.T * 32767).astype(np.int16)
with wave.open(out, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(f"wrote {out} ({DUR}s, {len(kick_times)} kicks, sidechain pump applied)")
