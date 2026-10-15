#!/usr/bin/env bash
#
# make_firm_audio.sh — build the full narrated soundtrack for the
# "FutureOfTheFirm" explainer and render the finished video.
#
# Pipeline (all on macOS — needs swift, `say`, afconvert, python3+numpy):
#   1. export the scene's synthesized ambient score  → out/firm-music.wav
#   2. generate one TTS clip per chapter with `say`   → out/vo/NN.wav (44.1k mono)
#   3. duck the music under each line and mix          → out/firm-mix.wav  (tools/mix_vo.py)
#   4. render the scene with the mixed track as --audio → out/future-of-the-firm.mp4
#
# The VO START times below mirror FutureOfTheFirm.anchors (+ a small per-chapter
# lead-in) so narration lands with each chapter. KEEP IN SYNC with the `durs`
# array in Sources/SwiftRenderScenes/FutureOfTheFirm.swift.
#
# Usage:
#   bash tools/make_firm_audio.sh                 # defaults (`say`, Samantha)
#   VOICE="Ava (Premium)" bash tools/make_firm_audio.sh
#   VOICE=Daniel RATE=170 bash tools/make_firm_audio.sh
#   TTS=kokoro bash tools/make_firm_audio.sh                       # Kokoro, af_heart
#   TTS=kokoro KOKORO_VOICE=af_bella bash tools/make_firm_audio.sh # Kokoro, other voice
#
set -euo pipefail
cd "$(dirname "$0")/.."

TTS="${TTS:-say}"                     # tts engine: say | kokoro
KOKORO_VOICE="${KOKORO_VOICE:-af_heart}"
VOICE="${VOICE:-Samantha}"
RATE="${RATE:-}"                      # words-per-minute; empty = voice default
OUT="${OUT:-out/future-of-the-firm.mp4}"
MUSIC="out/firm-music.wav"
MIX="out/firm-mix.wav"
TSV="out/firm-vo.tsv"
VODIR="out/vo"

mkdir -p out "$VODIR"

# id | absolute start (s) | narration text
LINES=(
"01|1.0|Here's how I think about the future of the firm in an AI-driven economy — a shift unlike any before it."
"02|9.3|In the past, digital systems enhanced human capital. Now, for the first time, we can build a real cognitive loop between people and machines — changing how we conceptualize work."
"03|20.8|What's at stake isn't a tool or a system. It's how organizations keep learning, building I P, and differentiating — while A I absorbs that expertise and commoditizes it."
"04|31.3|Every company will build two kinds of capital. Human capital — the knowledge, judgment, relationships, and pattern recognition of its people. And token capital — the A I capability the firm builds and owns."
"05|44.8|And human capital doesn't shrink as token capital grows — it becomes more valuable. Human agency is the driver. Without direction, compute just runs in circles."
"06|55.3|So the real opportunity isn't picking the best model. It's building a learning loop where human and token capital compound. You can offload a task — but never your learning."
"07|67.8|This needs a new architecture: agentic systems that improve over time, while you keep your I P. Swap out a generalist model — and keep the company-veteran expertise. That's the test of sovereignty."
"08|80.3|Companies turn workflows and judgment into systems that improve with use. Private evals measure what truly matters, not outside benchmarks. Private reinforcement learning grows models on real internal traces. A knowledge base makes institutional memory queryable."
"09|93.8|This loop becomes the firm's new I P — a hill-climbing machine. And unlike most assets, it compounds. Every improved workflow makes a better training signal. Build it early, and the advantage is hard to replicate."
"10|107.3|We don't want a world where a few models eat everything they see, capturing all the value. The political economy won't tolerate it — there's no societal permission to hollow out entire industries."
"11|120.8|We've seen this before. Globalization hollowed out entire economies through outsourcing. The G D P looked fine — but the displacement was real. Let's not bring that into the A I era."
"12|132.3|The priority must be a frontier ecosystem — not just a frontier model. Value flowing broadly across every company, industry, and country, where every organization owns the loop that encodes its knowledge."
"13|144.8|Then companies create value for themselves and the economy around them. Employees see their expertise amplified — their judgment made replicable and scalable. That's the stable equilibrium we should build together."
)

echo "[firm] 1/4  exporting ambient score → $MUSIC"
swift run swift-render audio FutureOfTheFirm --out "$MUSIC"

if [[ "$TTS" == "kokoro" ]]; then
  echo "[firm] 2/4  generating TTS with engine 'kokoro' (voice '$KOKORO_VOICE')"
  # Build the TSV mix_vo.py consumes, then synthesize the whole batch in ONE
  # python process so the Kokoro model loads only once.
  : > "$TSV"
  for entry in "${LINES[@]}"; do
    id="${entry%%|*}"; rest="${entry#*|}"
    start="${rest%%|*}"; text="${rest#*|}"
    printf '%s\t%s\t%s\n' "$id" "$start" "$text" >> "$TSV"
  done
  /Users/sky/swift-render/.venv-kokoro/bin/python \
    tools/kokoro_tts.py "$TSV" "$VODIR" "$KOKORO_VOICE"
else
  echo "[firm] 2/4  generating TTS with engine 'say' (voice '$VOICE')"
  : > "$TSV"
  for entry in "${LINES[@]}"; do
    id="${entry%%|*}"; rest="${entry#*|}"
    start="${rest%%|*}"; text="${rest#*|}"
    aiff="$(mktemp -t firm_vo).aiff"
    if [[ -n "$RATE" ]]; then
      say -v "$VOICE" -r "$RATE" -o "$aiff" "$text"
    else
      say -v "$VOICE" -o "$aiff" "$text"
    fi
    afconvert -f WAVE -d LEI16@44100 -c 1 "$aiff" "$VODIR/$id.wav"
    rm -f "$aiff"
    printf '%s\t%s\t%s\n' "$id" "$start" "$text" >> "$TSV"
    echo "       line $id @ ${start}s"
  done
fi

echo "[firm] 3/4  ducking music under VO → $MIX"
python3 tools/mix_vo.py "$MUSIC" "$TSV" "$VODIR" "$MIX"

echo "[firm] 4/4  rendering video → $OUT"
swift run swift-render render FutureOfTheFirm --audio "$MIX" --out "$OUT"

echo "[firm] done → $OUT"
