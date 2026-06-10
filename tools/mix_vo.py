#!/usr/bin/env python3
"""Mix the TTS voiceover over the LaunchFilm music bed.

Reads out/vo/NN.wav (44.1k mono, pre-converted), places each at the start
time in the TSV, ducks the music under every line, masters, writes a single
stereo wav ready to mux over the film.

Usage: python3 tools/mix_vo.py out/launch.wav /tmp/vo_lines.tsv out/vo out/launch-vo-mix.wav
"""
import sys
import wave

import numpy as np

music_path, tsv_path, vo_dir, out_path = sys.argv[1:5]


def read_wav(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    data = raw.astype(np.float64) / 32767.0
    if ch == 2:
        data = data.reshape(-1, 2)
    else:
        data = np.stack([data, data], axis=1)
    return sr, data


sr, music = read_wav(music_path)
N = len(music)
vo_bus = np.zeros((N, 2))
duck = np.ones(N)

lines = [l.split("\t") for l in open(tsv_path) if l.strip()]
for lid, start, text in lines:
    vsr, v = read_wav(f"{vo_dir}/{lid}.wav")
    assert vsr == sr, f"line {lid}: sample rate {vsr} != {sr} (convert first)"
    v = v.mean(axis=1)
    peak = np.abs(v).max()
    if peak > 1e-6:
        v = v / peak * 0.85
    i = int(float(start) * sr)
    j = min(N, i + len(v))
    vo_bus[i:j, 0] += v[: j - i]
    vo_bus[i:j, 1] += v[: j - i]

    # duck music 0.40 under the line, 120 ms ramps
    ramp = int(0.12 * sr)
    lo, hi = max(0, i - ramp), min(N, j + ramp)
    env = np.ones(hi - lo)
    env[: min(ramp, len(env))] = np.linspace(1, 0, min(ramp, len(env)))
    body_end = max(0, (j - lo) - 0)
    env[min(ramp, len(env)): body_end] = 0
    tail = hi - j
    if tail > 0:
        env[-tail:] = np.linspace(0, 1, tail)
    duck[lo:hi] = np.minimum(duck[lo:hi], 0.40 + 0.60 * env)

mix = music * duck[:, None] * 0.95 + vo_bus
mix = np.tanh(mix * 1.05)
mix = mix / np.abs(mix).max() * 0.94

pcm = (mix * 32767).astype(np.int16)
with wave.open(out_path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(pcm.tobytes())
print(f"wrote {out_path}: {len(lines)} VO lines mixed, music ducked to 40% under voice")
