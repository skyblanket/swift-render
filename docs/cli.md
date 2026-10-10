# CLI reference

Run commands from the repository root with `swift run swift-render`.

```text
swift-render new    <Scene> [--kind audio]               scaffold an auto-registered scene
swift-render check  <Scene>                              contact sheet + frame scan + audio/sample/voiceover report
swift-render preview <Scene>                             live window: scrub, play/pause, frame-step, synced audio
swift-render render <Scene> [--duration s] [--fps n] [--aspect 16:9|9:16|1:1]
                            [--audio file] [--props file.json] [--range a:b]
                            [--jobs n|auto] [--preview] [--open] [--no-postfx] [--out path]
swift-render frame  <Scene> --at <t>[,t2,…] [--out path.png]   one or several frames
swift-render contact <Scene> [--cols n] [--rows n]       grid contact sheet
swift-render audio  <Scene> --out score.wav              export the scene's Score
swift-render captions <Scene> --out film.srt|.vtt        export voiceover captions
swift-render props  <Scene>                              print default props JSON
swift-render smoke                                       one frame of every scene + no-swish check (CI)
swift-render list                                        all registered scenes
```

**`--jobs n|auto`** renders in parallel processes and stitches the chunks without re-encoding
(frame-exact against a single-process render). Render speed depends on scene complexity, hardware, and job count.

**`check`** also measures the mix you can't hear: *voice vs music* reports how many dB the
voiceover sits above the ducked music while someone is speaking, and the exact time spans where
it's buried.


`--range a:b` is picture-only. Render the full scene to include its soundtrack. `--audio` overrides the scene-declared score. `--jobs auto` uses half the available cores; choose an explicit count for your machine.
