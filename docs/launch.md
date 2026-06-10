# Launch kit — swift-render v0.5

The film: `swift run swift-render render LaunchFilm --audio out/launch.wav --out out/launch-film.mp4`
(regenerate the soundtrack first if needed: `python3 tools/make_launch_audio.py out/launch.wav`)

## Voiceover script (optional TTS pass)

Timed to the chapters. Keep delivery dry and confident; let the drops at 4.2s
and 43.2s breathe — no VO over them. Target ≈140 wpm.

| start | end | line |
|---|---|---|
| 0.5 | 2.8 | "Every video framework you know… renders a web browser." |
| 3.1 | 4.0 | "Ours doesn't." |
| 4.6 | 6.8 | *(beat — title drop, no VO)* |
| 7.5 | 10.4 | "swift-render. A scene is one pure function of time. That's the entire API." |
| 11.2 | 14.0 | "Springs solved in closed form — scrub any frame, same pixels, every run." |
| 14.8 | 17.6 | "Sequence clips on a timeline. Local time, automatic transitions, zero math." |
| 18.4 | 21.2 | "Real Metal shaders on the GPU. Thirteen ship in the box." |
| 22.0 | 24.8 | "3D perspective, starfields, raymarched tunnels — no game engine required." |
| 25.8 | 28.4 | "And it hears its own soundtrack. FFT-analyzed once. Still deterministic." |
| 29.4 | 32.0 | "Nine hundred frames. Native render: six seconds. Chromium is still warming up." |
| 33.0 | 35.6 | "Byte-identical re-renders — asserted in CI, not promised in a README." |
| 36.6 | 39.2 | "This film is one Swift file. An AI wrote it — frames and soundtrack." |
| 39.8 | 42.8 | "No Chromium. No node modules. No keyframes. Just Swift." |
| 43.2 | 45.0 | *(drop — no VO)* |
| 45.6 | 48.4 | "Just render it." |
| 49.6 | 53.5 | "swift-render. MIT licensed. On GitHub today." |

### Muxing your VO over the music

```bash
# duck music ~6dB under the voice, keep the drops loud
ffmpeg -i out/launch-film.mp4 -i vo.wav -filter_complex \
  "[0:a]volume=0.75[m];[m][1:a]amix=inputs=2:duration=first:dropout_transition=2[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k out/launch-film-vo.mp4
```

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
