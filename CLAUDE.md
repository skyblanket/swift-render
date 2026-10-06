# CLAUDE.md

Read [AGENTS.md](AGENTS.md) first — it covers building, testing, the house rules and where everything lives.

Claude Code specifics:

- **MCP:** this repo's `.mcp.json` registers the `swift-render` server (it builds `swift-render-mcp` quietly, then
  runs it). Tools are named `mcp__swift-render__<tool>`; see [docs/agents.md](docs/agents.md) for the list.
- **Director agent:** `.claude/agents/swift-render-director.md` resolves review comments end to end
  (claim → look at the frame → edit → build → re-render → resolve). Studio's **Ask Claude** runs it headless:
  `claude -p "…" --agent swift-render-director --output-format stream-json --verbose --permission-mode acceptEdits`
  (exact flags in [docs/review-loop.md](docs/review-loop.md)).
- **Skill:** `.claude/skills/swift-render-review/` explains the review loop.
- **Plugin for other repos:** `/plugin marketplace add skyblanket/swift-render`, then `/plugin install swift-render@swift-render`.
- Look at what you render: `swift run swift-render check <Scene>` writes `out/check-<Scene>.png` — Read it.
  Say plainly that you reviewed frames and levels but could not listen.
