# Launch kit — swift-render v0.5

The film: `swift run swift-render render LaunchFilm --audio out/launch.wav --out out/launch-film.mp4`
(regenerate the soundtrack first if needed: `python3 tools/make_launch_audio.py out/launch.wav`)

## Voiceover (generated — out/launch-film-vo.mp4)

VO is synthesized on sushi via fish-speech s2-pro and mixed by `tools/mix_vo.py`
(places each line at its timecode, ducks music to 40% under voice).

Voice: zero-shot cloned from a single pinned reference
(`~/fish-speech/references/narrator/` on sushi) — an 18s public-domain LibriVox
narration segment chosen by measuring median f0 across candidates (picked the
deepest at ~92 Hz). Always pass `reference_id` — promptless fish rolls a random
speaker per request. Cloning from real human speech, never from TTS output
(cloning a clone sounds robotic).

Pipeline:
```bash
# on sushi: start the API, generate lines from a TSV (id <TAB> start <TAB> text)
ssh sky@sushi 'cd ~/fish-speech && nohup .venv/bin/python tools/api_server.py \
  --listen 0.0.0.0:8080 --llama-checkpoint-path checkpoints/s2-pro \
  --decoder-checkpoint-path checkpoints/s2-pro/codec.pth \
  --decoder-config-name modded_dac_vq &'
ssh sky@sushi 'bash /tmp/vo_gen.sh'            # curls /v1/tts per line
scp 'sky@sushi:/tmp/vo/*.wav' out/vo_raw/      # fetch
# trim silence, 44.1k mono, then mix + mux:
python3 tools/mix_vo.py out/launch.wav lines.tsv out/vo out/launch-vo-mix.wav
ffmpeg -i out/launch-film.mp4 -i out/launch-vo-mix.wav -map 0:v -map 1:a \
  -c:v copy -c:a aac -b:a 192k out/launch-film-vo.mp4
```

Final lines (fish pace ≈ 2.9 words/sec — keep lines ≤ slot × 2.8 words):

| start | line |
|---|---|
| 0.5 | "Your video framework runs a browser." |
| 3.05 | "Ours doesn't." |
| 7.6 | "Real Metal shaders… raymarched live, on the GPU. Ink. Interference. Voronoi. Every pixel computed fresh, every frame." |
| 17.2 | "One pure function of time. The whole API." |
| 20.8 | "Springs, solved in closed form." |
| 23.6 | "Timeline clips. Zero math." |
| 26.8 | "Real 3D. No game engine." |
| 30.0 | "It hears its own soundtrack." |
| 33.2 | "Nine hundred frames, in six seconds." |
| 36.5 | "Byte identical. Asserted in CI." |
| 39.6 | "One Swift file. Written by an AI." |
| 42.8 | "No browser. No keyframes. Just Swift." |
| 48.3 | "Just render it." |
| 51.9 | "Swift render. MIT licensed. On GitHub, today." |

## Post copy — the "Fable 5 took it to prod" angle

**X/Twitter — tweet 1 (attach out/launch-film-vo.mp4 natively, never a link):**

> I had a half-finished SwiftUI→MP4 rendering framework sitting in a repo.
>
> Today, Fable 5 took it to full production. v0.5.0, tagged, CI green. Largely by itself.
>
> This launch film? ONE Swift file. Fable wrote the film, synthesized the
> soundtrack from pure math, and cloned the voiceover on my own GPU box.
>
> Just render it. 🧵

**Tweet 2 (reply, attach a screenshot of LaunchFilm.swift):**

> Receipts — one day, 12 commits, +4,000 lines:
>
> · Timeline/sequencing API (Remotion's <Sequence>, but pure functions of t)
> · analytic springs · FFT audio-reactive scenes · JSON props
> · found a flickering edge glitch by *inspecting rendered frames*, traced it
>   to the grain shader, fixed it
> · 24 tests incl. byte-identical determinism — asserted in CI

**Tweet 3 (reply):**

> SwiftUI + real Metal shaders, rendered natively at ~130fps.
> No headless Chromium. No node_modules. No keyframes.
>
> MIT. Open source. https://github.com/skyblanket/swift-render

**HN (Show HN) — keep tool-first, AI as the concrete supporting fact:**

> Title: Show HN: Swift-render — motion graphics in Swift; an AI took it from prototype to v0.5
>
> Body: Every scene is a pure function of `t: Double` — no hooks, no state, no
> browser. SwiftUI + real Metal shaders render at ~100–140fps at 1080p on Apple
> silicon, and determinism is enforced by a byte-identical re-render test in CI.
>
> The interesting part: the API shape was designed to be LLM-writable, and that
> got tested for real — most of v0.5.0 (the Timeline API, springs, the
> audio-reactive FFT pipeline, the test suite, and the launch film in the README
> — including its synthesized soundtrack and TTS voiceover) was built by an AI
> agent (Claude, Fable 5) working against that API in a day. `t: Double` in,
> pixels out turns out to be something a model almost never gets wrong.
>
> Honest caveats: macOS-only by design, no web player, no render farm — if you
> need those, Remotion is the right tool. Feedback wanted on the Timeline and
> spring APIs.

**LinkedIn:**

> We open-sourced swift-render — the motion-graphics engine behind our product
> videos. SwiftUI scenes + real Metal shaders → MP4, ~130fps, fully deterministic.
>
> The launch film attached was made by an AI agent in one Swift file: the cuts,
> the 3D, the soundtrack (synthesized from math), the voiceover (cloned on our
> own GPUs). One day from prototype to a tagged, CI-green release.
>
> MIT licensed. github.com/skyblanket/swift-render

**Reddit r/swift / r/SwiftUI (less salesy, community-toned):**

> Title: I open-sourced swift-render: SwiftUI scenes + Metal shaders → MP4
> (scenes are pure functions of t — and an AI agent built most of v0.5)
>
> Body: been building this as the native answer to Remotion. Every scene is
> `body(at t: Double)` — no @State, no timers, so renders are deterministic
> (there's a byte-identical test in CI). Renders ~130fps at 1080p on M-series.
> The launch video in the README is one Swift file in the repo, soundtrack and
> all. Would love feedback on the Timeline/spring APIs from people who do
> motion design in SwiftUI.

## Asset checklist

- [ ] `out/launch-film.mp4` — master, 1080p60 + audio (attach to X full-res)
- [ ] optional VO mux (above)
- [ ] `docs/assets/launch-film.mp4` — 720p embed for the README hero
- [ ] GitHub Release v0.5.0 with CHANGELOG notes
