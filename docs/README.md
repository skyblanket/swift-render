# Documentation

Start with the [project README](../README.md) for what swift-render is, setup and a first render.
Coding agents start with [AGENTS.md](../AGENTS.md).

## Use it

| Guide | Use it for |
| --- | --- |
| [Getting started](../README.md#quick-start) | Install, first render, a scene as a function of time |
| [Scenes API](ai-quickstart.md) | The whole scene API on one page: Timeline, easing, springs, Score, knobs, props, media, captions, shaders, 3D, gotchas. The MCP `docs` tool serves the same text. |
| [Features](features.md) | Worked examples: timelines, springs, native scoring, shaders, looks, media, Vision, demo scenes |
| [3D](3d.md) | `Scene3D`: SceneKit models, PBR materials, SwiftUI textures, lights, cameras, determinism, performance |
| [CLI reference](cli.md) | Every `swift-render` subcommand and option |
| [Launch films](launch.md) | `launch`, `init`, what the scanner reads, props, LaunchKit components |

## Studio and agents

| Guide | Use it for |
| --- | --- |
| [Studio](studio.md) | The native editor: window, keyboard shortcuts, menus, right-click menus, exports, snapshots for CI, packaging the `.app` |
| [Review loop](review-loop.md) | Timecoded comments on disk, `swift-render review`, the director agent, the Claude Code plugin, the headless run Studio executes |
| [Agents and MCP](agents.md) | `swift-render-mcp` modes, every tool and its arguments, jobs for long renders, setup for Claude Code, Claude Desktop, Codex and Cursor |

## Work on it

| Guide | Use it for |
| --- | --- |
| [Architecture](architecture.md) | Targets, processes (CLI, `serve`, Studio, MCP), data in `.swift-render/`, hot reload and the review loop |
| [Contributing](../CONTRIBUTING.md) | Development loop, adding scenes, components and shaders, contracts to keep in sync, tests |
| [Roadmap](../ROADMAP.md) | What has shipped and what is next |
| [Changelog](../CHANGELOG.md) | Release history |

## Demo notes

| Note | About |
| --- | --- |
| [Future of the Firm](future-of-the-firm.md) | How the narrated essay demo is built and voiced |
| [Autonomous war sources](autonomous-war-sources.md) | Research notes and sources for the `AutonomousWar` demo |

`assets/` holds the checked-in example videos and the Studio screenshot. Generated output belongs
in the Git-ignored `out/` directory. Demo content is not a promise that external product facts
stay current.
