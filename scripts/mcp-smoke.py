#!/usr/bin/env python3
"""Drive swift-render-mcp over stdio the way Claude Code does, and check the answers.

    python3 scripts/mcp-smoke.py                    # launch via .mcp.json, quick checks
    python3 scripts/mcp-smoke.py --full             # + a review round trip, check_scene, build, knobs
    python3 scripts/mcp-smoke.py --full --init      # + init_project, write_scene and a real Launch/ build
    python3 scripts/mcp-smoke.py --bin .build/debug/swift-render-mcp --save /tmp/frames

    python3 scripts/mcp-smoke.py --claude           # one real headless Claude Code run (needs `claude` logged in)

--full adds a throwaway comment with `swift-render review add`, walks it through
get/claim/reply/resolve over MCP, then deletes it (and its attachments) again; and starts a
second server in a throwaway Swift package outside the repo (standalone mode) to make a launch
film there, edit its props, follow a render job with render_status and check the creation tools'
refusals. --init also gives that package a Launch/ (init_project), writes a scene with write_scene
and builds it for real (minutes: it compiles swift-render).
--claude adds a throwaway comment, runs the exact `claude -p … --agent swift-render-director`
command Studio uses, asks it to reply "ack", checks the reply landed in the review file,
prints the stream-json events it saw, and deletes the comment again.
Exit status 0 = every check passed. Server stderr goes to ours.
"""
import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REVIEW_TOOLS = {"list_scenes", "scene_info", "render_frames", "contact_sheet", "check_scene", "build",
                "list_comments", "get_comment", "claim_comment", "reply_comment", "resolve_comment",
                "set_knobs", "render_video"}
CREATE_TOOLS = {"docs", "launch_film", "new_scene", "write_scene", "init_project", "get_props", "set_props",
                "render_status"}
TOOLS = REVIEW_TOOLS | CREATE_TOOLS
failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what, flush=True)
    if not cond:
        failures.append(what)
    return cond


class Client:
    def __init__(self, argv, cwd=ROOT, env=None):
        self.proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=sys.stderr, bufsize=0, env=env)
        self.next_id = 0

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def read(self):
        line = self.proc.stdout.readline()
        if not line:
            raise SystemExit("server closed stdout")
        msg = json.loads(line)           # any non-JSON byte on stdout is a protocol bug
        assert msg.get("jsonrpc") == "2.0", f"not JSON-RPC: {line[:200]!r}"
        return msg

    def request(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        reply = self.read()
        assert reply.get("id") == self.next_id, f"id mismatch: sent {self.next_id}, got {reply.get('id')}"
        return reply

    def call(self, name, args=None, save=None):
        t0 = time.time()
        reply = self.request("tools/call", {"name": name, "arguments": args or {}})
        result = reply.get("result") or {}
        texts = [c["text"] for c in result.get("content", []) if c.get("type") == "text"]
        images = [c for c in result.get("content", []) if c.get("type") == "image"]
        if save:
            os.makedirs(save, exist_ok=True)
            for i, img in enumerate(images):
                path = os.path.join(save, f"{name}-{self.next_id}-{i}.png")
                with open(path, "wb") as f:
                    f.write(base64.b64decode(img["data"]))
        print(f"  ·    {name} {json.dumps(args or {})} → {len(texts)} text, {len(images)} image(s), "
              f"isError={result.get('isError')} ({time.time() - t0:.1f}s)", flush=True)
        return reply, result, "\n".join(texts), images

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def png_size(img):
    data = base64.b64decode(img["data"])
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def server_argv(args):
    if args.bin:
        return [args.bin]
    cfg = json.load(open(os.path.join(ROOT, ".mcp.json")))["mcpServers"]["swift-render"]
    return [cfg["command"]] + cfg.get("args", [])


def review_file(scene):
    return os.path.join(ROOT, ".swift-render/reviews", f"{scene}.json")


def drop_if_empty(scene, existed):
    """Don't leave an empty review file behind that wasn't there before the run."""
    path = review_file(scene)
    if not existed and os.path.exists(path) and not json.load(open(path))["comments"]:
        os.remove(path)


def cli(*argv):
    """The project's own CLI (built by the server's first render if needed)."""
    bin_path = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True,
                              text=True, check=True).stdout.strip()
    return subprocess.run([os.path.join(bin_path, "swift-render"), *argv], cwd=ROOT, capture_output=True, text=True)


READ_ONLY_TOOLS = ["list_scenes", "scene_info", "render_frames", "contact_sheet", "check_scene",
                   "list_comments", "get_comment", "reply_comment", "render_status"]
WRITING_TOOLS = ["claim_comment", "resolve_comment", "set_knobs", "render_video"]


def claude_command(prompt, budget):
    """Exactly what Studio runs for a reply run (cwd = project root); see docs/review-loop.md
    and ClaudeCodeBackend.arguments. The prompt only asks for a reply, so edits and Bash are denied."""
    return ["claude", "-p", prompt, "--agent", "swift-render-director", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "default",
            "--allowedTools", *["mcp__swift-render__" + t for t in READ_ONLY_TOOLS],
            "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit", "Bash",
            *["mcp__swift-render__" + t for t in WRITING_TOOLS],
            "--mcp-config", ".mcp.json", "--max-budget-usd", str(budget)]


def claude_e2e(scene, budget):
    print("headless Claude Code")
    existed = os.path.exists(review_file(scene))
    add = cli("review", "add", scene, "--at", "2.6", "--region", "0.3,0.12,0.4,0.15", "--author", "e2e", "--json",
              "e2e test: is the ANALYTIC SPRINGS heading too small?")
    if not check(add.returncode == 0, "review add (CLI) creates the test comment"):
        print(add.stderr)
        return
    cid = json.loads(add.stdout)["comment"]["id"]
    prompt = f"List the open swift-render review comments and reply to {cid} with the word ack. Do not edit any files."
    try:
        t0 = time.time()
        proc = subprocess.run(claude_command(prompt, budget), cwd=ROOT, capture_output=True, text=True, timeout=900)
        events = []
        for line in proc.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                print("  !    non-JSON stdout line:", line[:160])
        print(f"  ·    claude exited {proc.returncode} after {time.time() - t0:.0f}s with {len(events)} events")
        for e in events:
            kind = e.get("type"), e.get("subtype")
            content = (e.get("message") or {}).get("content") or []
            parts = [c.get("type") + (":" + c["name"] if c.get("name") else "") for c in content if isinstance(c, dict)]
            print(f"  ·      {kind[0]}{'/' + kind[1] if kind[1] else ''} {' '.join(parts)}"
                  + (f" → {str(e.get('result'))[:120]!r} cost=${e.get('total_cost_usd')}" if kind[0] == "result" else ""))
        init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), {})
        servers = {s["name"]: s["status"] for s in init.get("mcp_servers", [])}
        check(servers.get("swift-render") == "connected", f"system/init: swift-render MCP connected ({servers.get('swift-render')})")
        check("mcp__swift-render__reply_comment" in init.get("tools", []), "system/init: director has the MCP tools")
        result = next((e for e in events if e.get("type") == "result"), {})
        if not check(result and not result.get("is_error"), "result event without is_error"):
            print("       result:", result.get("result"), "| stderr:", proc.stderr.strip()[-400:])
        stored = json.load(open(review_file(scene)))
        cm = next((x for x in stored["comments"] if x["id"] == cid), {})
        replies = [r for r in cm.get("replies", []) if r["author"]["kind"] == "agent"]
        check(any("ack" in r["body"].lower() for r in replies),
              f"agent reply 'ack' landed in .swift-render/reviews/{scene}.json")
        check(cm.get("status") == "open", "comment left open (reply only)")
    finally:
        rm = cli("review", "delete", cid)
        check(rm.returncode == 0, "cleanup: review delete")
        drop_if_empty(scene, existed)


TINY_PACKAGE = {
    "Package.swift": """// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Tally", targets: ["Tally"])],
    targets: [.target(name: "Tally")]
)
""",
    "README.md": """# Tally

Count anything, beautifully. Live counters with springy SwiftUI digits.

## Features

- **Live counters** — bind any number and watch it roll.
- **Springy digits** — analytic springs, no timers.
- **Haptics built in** — feel every increment on iPhone.
""",
    "Sources/Tally/Tally.swift": "public struct Tally { public var value = 0; public init() {} }\n",
}


def follow(c, job, limit=900):
    """render_status until the job is no longer queued or running."""
    deadline = time.time() + limit
    while True:
        _, res, text, imgs = c.call("render_status", {"job": job, "wait": 30})
        first = text.splitlines()[0] if text else ""
        if (" · running" not in first and " · queued" not in first) or time.time() > deadline:
            return res, text, imgs


def job_id(text):
    for word in text.replace('"', " ").split():
        if word.startswith("j") and word[1:].isdigit():
            return word
    return None


SCENE_SOURCE = """import SwiftUI
import SwiftRender

/// Written over MCP by scripts/mcp-smoke.py --init.
public struct TallyTeaser: RenderScene {
    public static let defaultDuration: Double = 4

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            chordPad(.major7(.c3), at: 0, duration: duration)
            thump(at: 2)
        }
    }

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let p = Ease.easeOut(Ease.clip(t, 0.2, 1.2))
        return ZStack {
            Color.black
            Text("Tally").font(.system(size: 160, weight: .bold)).foregroundStyle(.white)
                .opacity(p).scaleEffect(Ease.spring(t, from: 1.2, to: 1, response: 0.5, dampingFraction: 0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
"""


def standalone_e2e(args):
    """A second server in a Swift package that has never seen swift-render (outside the repo):
    standalone mode, with the swift-render CLI next to the server binary."""
    print("standalone (any Swift repo)")
    if args.bin:
        server = os.path.abspath(args.bin)
    else:
        bin_dir = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True,
                                 check=True).stdout.strip()
        server = os.path.join(bin_dir, "swift-render-mcp")
    if not os.path.exists(os.path.join(os.path.dirname(server), "swift-render")):
        subprocess.run(["swift", "build", "--product", "swift-render"], cwd=ROOT, check=True,
                       stdout=sys.stderr, stderr=sys.stderr)
    tmp = tempfile.mkdtemp(prefix="sr-mcp-smoke-")
    pkg = os.path.join(tmp, "Tally")
    for rel, body in TINY_PACKAGE.items():
        os.makedirs(os.path.dirname(os.path.join(pkg, rel)), exist_ok=True)
        with open(os.path.join(pkg, rel), "w") as f:
            f.write(body)
    env = {k: v for k, v in os.environ.items() if k not in ("SWIFT_RENDER_ROOT", "SWIFT_RENDER_CLI")}
    c = Client([server], cwd=pkg, env=env)
    try:
        r = c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "mcp-smoke", "version": "1"}})
        res = r.get("result", {})
        check("mode: standalone" in res.get("instructions", ""), "initialize in a plain package → mode: standalone")
        _, res, text, _ = c.call("list_scenes")
        check(not res.get("isError") and text.startswith("mode: standalone") and "AppleLaunch" in text
              and "built-in demo films (list_scenes {all:true}" in text and "TimelineDemo" not in text,
              "list_scenes → the templates, demos summarized, mode line first")
        _, res, text, _ = c.call("list_scenes", {"all": True})
        check("TimelineDemo" in text and "· demo" in text, "list_scenes {all} → the demo films too, tagged")
        _, res, text, _ = c.call("docs", {"topic": "scenes"})
        check("typecheck-budget" not in text, "docs scenes leaves out this repo's CI rules")
        _, res, text, imgs = c.call("launch_film", {"preview": True}, args.save)
        film = next((line.split("film: ", 1)[1].split("  (")[0] for line in text.splitlines()
                     if line.startswith("film: ")), "")
        check(not res.get("isError") and film and os.path.getsize(film) > 10_000 and len(imgs) == 1,
              f"launch_film preview → {os.path.basename(film)} + contact sheet")
        check("tagline     Count anything, beautifully." in text and "README.md" in text,
              "launch_film reports what it detected, with sources")
        props = os.path.join(pkg, ".swift-render/launch/Tally.json")
        _, res, text, _ = c.call("set_props", {"scene": "AppleLaunch", "props": {"tagline": "Count on it."}})
        check(not res.get("isError") and json.load(open(props))["tagline"] == "Count on it.",
              "set_props AppleLaunch edits the film's props file")
        _, res, text, _ = c.call("get_props", {"scene": "AppleLaunch"})
        check("Count on it." in text, "get_props shows the edit")
        _, res, text, imgs = c.call("render_frames", {"scene": "AppleLaunch", "times": [9], "width": 480}, args.save)
        check(not res.get("isError") and len(imgs) == 1 and "Tally.json" in text, "render_frames uses the film's props")
        _, res, text, _ = c.call("new_scene", {"name": "TallyTeaser"})
        check(res.get("isError") is True and "init_project" in text, "new_scene outside a project → points to init_project")
        _, res, text, _ = c.call("launch_film", {"path": "/etc"})
        check(res.get("isError") is True, "launch_film refuses a system folder")
        bare = os.path.join(tmp, "NotACodebase")
        os.makedirs(bare)
        _, res, text, _ = c.call("launch_film", {"path": bare})
        check(res.get("isError") is True and "doesn't look like a codebase" in text,
              "launch_film refuses a folder that isn't a codebase")
        _, res, text, _ = c.call("new_scene", {"name": "Score"})
        check(res.get("isError") is True and "already a type" in text, "new_scene refuses a name that shadows a type")
        outside = os.path.join(tmp, "outside")
        os.makedirs(outside)
        os.makedirs(os.path.join(pkg, ".swift-render"), exist_ok=True)
        link = os.path.join(pkg, ".swift-render/props")
        os.symlink(outside, link)
        _, res, text, _ = c.call("set_props", {"scene": "KnobLab", "props": {"title": "x"}})
        check(res.get("isError") is True and not os.listdir(outside), "set_props refuses a symlinked props folder")
        os.remove(link)

        print("jobs")
        _, res, text, _ = c.call("render_video", {"scene": "AppleLaunch", "preview": True, "wait": False})
        job = job_id(text)
        check(not res.get("isError") and "started as job" in text and job, f"render_video wait:false → job {job}")
        _, res, text, _ = c.call("render_status", {"job": job, "wait": 0})
        check(not res.get("isError") and job in text, "render_status reports the running job")
        res, text, _ = follow(c, job)
        mp4 = os.path.join(pkg, "out/AppleLaunch-preview.mp4")
        check(not res.get("isError") and " · done" in text and "rendered AppleLaunch" in text
              and os.path.exists(mp4) and os.path.getsize(mp4) > 10_000, "render_status → done, the MP4 exists")
        _, res, text, _ = c.call("render_status")
        check(job in text, "render_status {} lists the jobs")

        if args.init:
            print("init_project + write_scene (real build)")
            _, res, text, _ = c.call("init_project")
            build = job_id(text.split("as job", 1)[1]) if "as job" in text else None
            check(not res.get("isError") and build, f"init_project → Launch/ + first build as job {build}")
            res, text, _ = follow(c, build, limit=1800)
            check(not res.get("isError") and "BUILD OK" in text, "the first Launch/ build finishes OK")
            _, res, text, _ = c.call("new_scene", {"name": "TallyTeaser"})
            check(not res.get("isError") and "public struct TallyTeaser" in text, "new_scene returns the scaffold's source")
            _, res, text, _ = c.call("write_scene", {"name": "TallyTeaser", "source": SCENE_SOURCE, "wait": True})
            check(not res.get("isError") and "replaced" in text and "BUILD OK" in text, "write_scene → builds OK")
            _, res, text, imgs = c.call("contact_sheet", {"scene": "TallyTeaser"}, args.save)
            check(not res.get("isError") and len(imgs) == 1, "contact_sheet of the written scene")
            broken = SCENE_SOURCE.replace("Ease.clip(t, 0.2, 1.2)", "Ease.clip(t, 0.2)")
            _, res, text, _ = c.call("write_scene", {"name": "TallyTeaser", "source": broken, "wait": True})
            check(res.get("isError") is True and "BUILD FAILED" in text and "TallyTeaser.swift:" in text,
                  "write_scene with an error → compiler diagnostics")
            c.call("write_scene", {"name": "TallyTeaser", "source": SCENE_SOURCE, "wait": True})
        wrote = sorted(os.path.relpath(os.path.join(d, f), pkg) for d, _, fs in os.walk(pkg) for f in fs
                       if not os.path.relpath(os.path.join(d, f), pkg).startswith(("Sources", "Package", "README")))
        check(all(w.startswith((".swift-render/", "out/", "Launch/", ".mcp.json")) for w in wrote),
              f"writes stay in .swift-render/, out/ (and Launch/ with --init) ({len(wrote)})")
    finally:
        c.close()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", help="server binary (default: the command in .mcp.json)")
    ap.add_argument("--scene", default="TimelineDemo")
    ap.add_argument("--full", action="store_true", help="also run the review round trip, check, build, knobs")
    ap.add_argument("--init", action="store_true", help="with --full: init_project + write_scene + a real Launch/ build")
    ap.add_argument("--claude", action="store_true", help="only the headless Claude Code end-to-end run")
    ap.add_argument("--budget", default="1", help="--max-budget-usd for --claude (default 1)")
    ap.add_argument("--save", help="write every returned image here")
    args = ap.parse_args()
    scene = args.scene

    if args.claude:
        claude_e2e(scene, args.budget)
        print("\n" + ("PASS" if not failures else f"FAIL ({len(failures)}): " + "; ".join(failures)))
        sys.exit(1 if failures else 0)

    print("protocol")
    c = Client(server_argv(args))
    r = c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "mcp-smoke", "version": "1"}, "futureField": True})
    res = r.get("result", {})
    check(res.get("protocolVersion") == "2025-06-18", "initialize echoes a supported protocolVersion")
    check(res.get("capabilities", {}).get("tools") == {}, "capabilities.tools = {}")
    check(res.get("capabilities", {}).get("resources") == {}, "capabilities.resources = {}")
    check(res.get("serverInfo", {}).get("name") == "swift-render", "serverInfo.name = swift-render")
    check("mode: project" in res.get("instructions", "") and "launch_film" in res.get("instructions", ""),
          "instructions: the make-a-video recipe + mode: project")
    c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})     # must not be answered
    r = c.request("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}})
    check(r["result"]["protocolVersion"] == "2025-11-25", "unknown protocolVersion → newest supported")
    check(c.request("ping").get("result") == {}, "ping → {}")
    r = c.request("tools/list")
    names = {t["name"] for t in r["result"]["tools"]}
    check(names == TOOLS, f"tools/list has the {len(TOOLS)} contract tools ({len(names)})")
    check(all(t["inputSchema"].get("type") == "object" for t in r["result"]["tools"]), "every inputSchema is an object")
    check(all(isinstance(p.get("type"), str) for t in r["result"]["tools"]
              for p in t["inputSchema"].get("properties", {}).values()), "every argument has a single JSON type")
    r = c.request("resources/list")
    uris = [x["uri"] for x in r.get("result", {}).get("resources", [])]
    check("swift-render://docs/scenes" in uris and "swift-render://docs/more" not in uris,
          f"resources/list: {len(uris)} docs topics, every quickstart section filed")
    r = c.request("resources/read", {"uri": "swift-render://docs/all"})
    text = (r.get("result", {}).get("contents") or [{}])[0].get("text", "")
    with open(os.path.join(ROOT, "docs/ai-quickstart.md"), encoding="utf-8") as f:
        check(text == f.read().strip("\n"), "resources/read docs/all = docs/ai-quickstart.md (embedded copy fresh)")
    r = c.request("resources/read", {"uri": "swift-render://docs/nope"})
    check(r.get("error", {}).get("code") == -32002, "unknown resource → -32002")
    r = c.request("prompts/list")
    check(r.get("error", {}).get("code") == -32601, "unknown method → -32601")
    r = c.request("tools/call", {"name": "no_such_tool", "arguments": {}})
    check(r.get("error", {}).get("code") == -32602, "unknown tool → -32602")
    _, res, text, _ = c.call("scene_info", {})
    check(res.get("isError") is True and "scene" in text, "missing argument → isError result")

    print("scenes & frames")
    _, res, text, _ = c.call("list_scenes")
    check(not res.get("isError") and scene in text, f"list_scenes includes {scene}")
    _, res, text, _ = c.call("scene_info", {"scene": scene})
    check(not res.get("isError") and text.startswith(scene), "scene_info summary")
    _, res, text, imgs = c.call("render_frames", {"scene": scene, "times": [0.6, 5], "width": 640}, args.save)
    sizes = [png_size(i) for i in imgs]
    check(not res.get("isError") and len(imgs) == 2 and all(s and s[0] <= 640 for s in sizes),
          f"render_frames → 2 PNGs ≤ 640 wide {sizes}")
    _, res, _, imgs = c.call("contact_sheet", {"scene": scene}, args.save)
    check(not res.get("isError") and len(imgs) == 1 and png_size(imgs[0])[0] <= 1280, "contact_sheet → 1 PNG ≤ 1280")
    _, res, text, _ = c.call("list_comments", {"status": "all"})
    check(not res.get("isError"), "list_comments (all)")
    _, res, text, imgs = c.call("render_frames", {"scene": scene, "times": [1.0], "width": 480, "aspect": "9:16"}, args.save)
    sizes = [png_size(i) for i in imgs]
    check(not res.get("isError") and sizes and sizes[0][1] > sizes[0][0], f"render_frames aspect 9:16 → portrait {sizes}")

    print("creation tools (project mode)")
    _, res, text, _ = c.call("docs")
    check(not res.get("isError") and "How to make a video" in text and "`timeline`" in text, "docs → recipe + topic index")
    _, res, text, _ = c.call("docs", {"topic": "scenes"})
    check(not res.get("isError") and "Ease.clip" in text, "docs scenes → the scene API")
    _, res, text, _ = c.call("get_props", {"scene": "AppleLaunch"})
    check(not res.get("isError") and '"tagline"' in text, "get_props AppleLaunch → props JSON")
    _, res, text, _ = c.call("get_props", {"scene": scene})
    check(res.get("isError") is True and "takes no props" in text, f"get_props {scene} → takes no props")
    _, res, text, _ = c.call("render_video", {"scene": scene, "aspect": "4:3"})
    check(res.get("isError") is True and "aspect must be" in text, "render_video refuses a bad aspect")

    print("hardening")
    _, res, text, _ = c.call("new_scene", {"name": "../../Evil"})
    check(res.get("isError") is True and "UpperCamelCase" in text, "new_scene refuses a path as name")
    _, res, text, _ = c.call("set_props", {"scene": "AppleLaunch", "props": {"x": 1}, "file": "../../evil.json"})
    check(res.get("isError") is True and not os.path.exists(os.path.join(os.path.dirname(ROOT), "evil.json")),
          "set_props refuses a file outside .swift-render/props")
    _, res, text, _ = c.call("launch_film", {"path": "/"})
    check(res.get("isError") is True and "refusing" in text, "launch_film refuses /")
    for times in (["nan"], "inf", [1e19]):
        _, res, text, _ = c.call("render_frames", {"scene": scene, "times": times})
        check(res.get("isError") is True and "finite" in text, f"render_frames times={times!r} refused")
    _, res, text, _ = c.call("set_knobs", {"scene": "../../.mcp", "values": {"x": "pwned"}})
    check(res.get("isError") is True and "not a scene name" in text, "set_knobs refuses a path as scene")
    _, res, text, _ = c.call("set_knobs", {"scene": scene + "Typo", "values": {"x": 1}})
    check(res.get("isError") is True and "unknown scene" in text, "set_knobs refuses an unknown scene")
    check(c.request("ping").get("result") == {}, "server still answers after bad arguments")

    if args.full:
        print("review round trip")
        existed = os.path.exists(review_file(scene))
        add = cli("review", "add", scene, "--at", "1.2", "--region", "0.08,0.3,0.5,0.4",
                  "--author", "mcp-smoke", "--json", "smoke test: title block feels heavy")
        if not check(add.returncode == 0, "review add (CLI) creates a comment"):
            print(add.stderr)
        else:
            cid = json.loads(add.stdout)["comment"]["id"]
            try:
                _, res, text, _ = c.call("list_comments", {"scene": scene})
                check(cid in text, "list_comments shows the new comment")
                _, res, text, imgs = c.call("get_comment", {"id": cid[:6]}, args.save)
                check(not res.get("isError") and f'"id" : "{cid}"' in text and len(imgs) == 1,
                      "get_comment (by prefix) → JSON + boxed frame")
                _, res, text, _ = c.call("claim_comment", {"id": cid})
                check(not res.get("isError") and "inProgress" in text, "claim_comment → inProgress")
                _, res, text, imgs = c.call("reply_comment", {"id": cid, "body": "smoke reply", "attach_frame": True},
                                            args.save)
                check(not res.get("isError") and len(imgs) == 1, "reply_comment with attach_frame")
                _, res, text, imgs = c.call("resolve_comment", {"id": cid, "summary": "smoke: nothing changed"},
                                            args.save)
                check(not res.get("isError") and "resolved" in text and len(imgs) == 1, "resolve_comment")
                stored = json.load(open(review_file(scene)))
                cm = next(x for x in stored["comments"] if x["id"] == cid)
                check(cm["status"] == "resolved" and cm["resolution"] == "smoke: nothing changed",
                      "review file: status resolved + resolution")
                check(len(cm["replies"]) == 2 and cm["replies"][-1]["author"]["kind"] == "agent"
                      and cm["replies"][-1]["attachments"][0]["kind"] == "after", "review file: agent replies + after frame")
                paths = [a["path"] for a in cm.get("attachments", [])] + \
                        [a["path"] for rp in cm["replies"] for a in rp["attachments"]]
                check(all(os.path.exists(os.path.join(ROOT, p)) for p in paths), f"{len(paths)} attachment files exist")
                _, res, _, _ = c.call("claim_comment", {"id": cid})
                check(res.get("isError") is True, "claiming a resolved comment is refused")
            finally:
                rm = cli("review", "delete", cid)
                check(rm.returncode == 0, "cleanup: review delete")
                drop_if_empty(scene, existed)

        print("check, build, knobs")
        _, res, text, imgs = c.call("check_scene", {"scene": scene}, args.save)
        check(not res.get("isError") and "scene " + scene in text and len(imgs) == 1, "check_scene → report + sheet")
        _, res, text, _ = c.call("build")
        check(not res.get("isError") and text.startswith("BUILD OK"), "build → BUILD OK")
        knobs = os.path.join(ROOT, ".swift-render/knobs", f"{scene}.json")
        had_knobs = os.path.exists(knobs)
        _, res, text, _ = c.call("set_knobs", {"scene": scene, "values": {"smoke.size": 1.5, "smoke.on": True}})
        check(not res.get("isError") and "smoke.size = 1.5" in text and "smoke.on = true" in text, "set_knobs writes")
        check("not declared" in text, "set_knobs warns about undeclared keys")
        _, res, text, _ = c.call("set_knobs", {"scene": scene, "values": {"smoke.size": None, "smoke.on": None}})
        check(not res.get("isError") and (had_knobs or not os.path.exists(knobs)), "set_knobs null removes keys")

    c.close()
    if args.full:
        standalone_e2e(args)
    print("\n" + ("PASS" if not failures else f"FAIL ({len(failures)}): " + "; ".join(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
