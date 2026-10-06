# FutureOfTheFirm — a narrated, animated essay explainer

`FutureOfTheFirm` turns the essay *"The future of the firm in an AI-driven
economy"* into a ~2:42 motion-graphics explainer: fourteen chapters that
**illustrate** each idea (a cognitive loop, two kinds of capital, a
hill-climbing machine, a frontier ecosystem) on a dark editorial canvas, with
an accent of `#C7FF1A`, a synthesized ambient score, and TTS narration mixed on
top.

It is one Swift file — [`Sources/SwiftRenderScenes/FutureOfTheFirm.swift`](../Sources/SwiftRenderScenes/FutureOfTheFirm.swift) —
a pure function of time like every other scene, plus a one-command pipeline for
the voiceover.

## Render it

**Picture only** (synthesized ambient score, no narration):

```bash
swift run swift-render render FutureOfTheFirm --out out/firm.mp4
```

**Full narrated film** (music → TTS → ducked mix → render, one command):

```bash
bash tools/make_firm_audio.sh
# → out/future-of-the-firm.mp4
```

Pick a voice (any installed macOS voice; premium Siri voices sound best):

```bash
VOICE="Ava (Premium)" bash tools/make_firm_audio.sh
VOICE=Daniel RATE=168 bash tools/make_firm_audio.sh   # RATE = words/min
```

Requirements: macOS 14+, the Swift toolchain, `say` + `afconvert` (built in),
and `python3` with `numpy` (`pip3 install numpy`) for the mix step.

### How the pipeline works

`tools/make_firm_audio.sh`:

1. `swift run swift-render audio FutureOfTheFirm` exports the scene's
   synthesized score to `out/firm-music.wav`.
2. For each chapter it runs `say` and converts to 44.1 kHz mono with
   `afconvert` → `out/vo/NN.wav`, and writes `out/firm-vo.tsv`.
3. [`tools/mix_vo.py`](../tools/mix_vo.py) places each line at its start time and
   **ducks the music to 40 %** under the voice → `out/firm-mix.wav`.
4. `swift run swift-render render FutureOfTheFirm --audio out/firm-mix.wav`
   muxes the mixed track over the picture (`--audio` always wins over a scene's
   own score).

## Sync model

Chapter start times live in one place — the `durs` array in the scene — and the
narration start times in `make_firm_audio.sh` mirror them. Adjacent chapters
overlap by `cross` (0.5 s) and each fades itself in/out, so they crossfade with
no black gap. The ambient score is declared from the **same** `anchors`, so the
whooshes/crashes land exactly on the cuts.

> Editing chapter lengths? Update `durs` in the scene **and** the start times in
> `tools/make_firm_audio.sh` together.

## Chapter map

| # | Chapter | Visual idea |
|---|---|---|
| 0 | Title | "The future of the firm" over a faint plasma shader |
| 1 | The cognitive loop | PEOPLE ⇄ MACHINES with a marker orbiting a loop |
| 2 | What's at stake | learn · build IP · differentiate, expertise blurring out |
| 3 | Two kinds of capital | HUMAN CAPITAL **+** TOKEN CAPITAL panels slide in |
| 4 | More valuable | two bar series rising together; "compute runs in circles" |
| 5 | The learning loop | a loop around MODELS; "offload the task, never the learning" |
| 6 | Control & sovereignty | swap a generalist model, keep company-veteran expertise |
| 7 | Three components | Private Evals · Private RL · Knowledge Base cards |
| 8 | A hill-climbing machine | a staircase the marker climbs — the climax (riser + boom) |
| 9 | The failure mode | a few models absorbing a field of dots |
| 10 | We've seen this before | GDP line steady while industries collapse beneath it |
| 11 | A frontier ecosystem | value radiating outward to many nodes |
| 12 | The payoff | company + economy rising together; the stable equilibrium |
| 13 | Lockup | "Own the learning loop." |

## Tuning

- **Length / pacing** — edit `durs` (and the matching VO starts).
- **Narration wording** — edit the `LINES` array in `make_firm_audio.sh`; keep
  each line shorter than its chapter (rule of thumb ≈ 2.7 words/sec).
- **Aspect** — add `--aspect 9:16` (or `--aspect 1:1`) for social cuts. The
  layout is authored for 16:9; verticals will need spacing tweaks.
- **Look** — the palette (`bg`, `ink`, `accent`, `warn`) sits at the top of the
  scene; change `accent` to rebrand the whole film.
