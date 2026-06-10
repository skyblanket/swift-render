# Launch kit — swift-render v0.5

The film: `swift run swift-render render LaunchFilm --audio out/launch.wav --out out/launch-film.mp4`
(regenerate the soundtrack first if needed: `python3 tools/make_launch_audio.py out/launch.wav`)

## Voiceover (generated — out/launch-film-vo.mp4)

VO is synthesized on sushi via fish-speech s2-pro and mixed by `tools/mix_vo.py`
(places each line at its timecode, ducks music to 40% under voice).

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
| 23.6 | "Timeline clips. Local time. Zero math." |
| 26.8 | "Real 3D. No game engine." |
| 30.0 | "It hears its own soundtrack." |
| 33.2 | "Nine hundred frames, in six seconds." |
| 36.5 | "Byte identical. Asserted in CI." |
| 39.6 | "One Swift file. Written by an AI." |
| 42.8 | "No browser. No keyframes. Just Swift." |
| 48.3 | "Just render it." |
| 51.9 | "Swift render. MIT licensed. On GitHub, today." |

## Post copy

**X/Twitter (attach out/launch-film.mp4):**

> Remotion renders React in a headless browser at ~20fps.
> I render SwiftUI + real Metal shaders natively at ~130fps.
>
> This launch film is ONE Swift file — cuts, 3D, soundtrack, all of it.
> Written by an AI. Rendered in 26 seconds on a laptop.
>
> swift-render. MIT. Out today.
> github.com/skyblanket/swift-render

**HN (Show HN):**

> Title: Show HN: Swift-render – programmatic motion graphics in Swift (a native Remotion alternative)
>
> Body: Every frame is a pure function of `t: Double` — no hooks, no state, no
> browser. SwiftUI + real Metal shaders render at ~100–140fps at 1080p on Apple
> silicon, and determinism is enforced with a byte-identical re-render test in CI.
> The launch video in the README is a single Swift file in the repo (LaunchFilm.swift),
> soundtrack synthesized by a 200-line Python script, written end-to-end by an AI
> agent against the API. Honest caveats: macOS-only by design, no web player, no
> render farm — if you need those, Remotion is still the right tool. Feedback wanted
> on the Timeline/spring APIs.

## Asset checklist

- [ ] `out/launch-film.mp4` — master, 1080p60 + audio (attach to X full-res)
- [ ] optional VO mux (above)
- [ ] `docs/assets/launch-film.mp4` — 720p embed for the README hero
- [ ] GitHub Release v0.5.0 with CHANGELOG notes
