#!/usr/bin/env python3
"""Drive swift-render-mcp over stdio the way Claude Code does, and check the answers.

    python3 scripts/mcp-smoke.py                    # launch via .mcp.json, quick checks
    python3 scripts/mcp-smoke.py --full             # + a review round trip, check_scene, build, knobs
    python3 scripts/mcp-smoke.py --bin .build/debug/swift-render-mcp --save /tmp/frames

--full adds a throwaway comment with `swift-render review add`, walks it through
get/claim/reply/resolve over MCP, then deletes it (and its attachments) again.
Exit status 0 = every check passed. Server stderr goes to ours.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = {"list_scenes", "scene_info", "render_frames", "contact_sheet", "check_scene", "build",
         "list_comments", "get_comment", "claim_comment", "reply_comment", "resolve_comment",
         "set_knobs", "render_video"}
failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what, flush=True)
    if not cond:
        failures.append(what)
    return cond


class Client:
    def __init__(self, argv):
        self.proc = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=sys.stderr, bufsize=0)
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


def cli(*argv):
    """The project's own CLI (built by the server's first render if needed)."""
    bin_path = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True,
                              text=True, check=True).stdout.strip()
    return subprocess.run([os.path.join(bin_path, "swift-render"), *argv], cwd=ROOT, capture_output=True, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", help="server binary (default: the command in .mcp.json)")
    ap.add_argument("--scene", default="TimelineDemo")
    ap.add_argument("--full", action="store_true", help="also run the review round trip, check, build, knobs")
    ap.add_argument("--save", help="write every returned image here")
    args = ap.parse_args()
    scene = args.scene

    print("protocol")
    c = Client(server_argv(args))
    r = c.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "mcp-smoke", "version": "1"}, "futureField": True})
    res = r.get("result", {})
    check(res.get("protocolVersion") == "2025-06-18", "initialize echoes a supported protocolVersion")
    check(res.get("capabilities", {}).get("tools") == {}, "capabilities.tools = {}")
    check(res.get("serverInfo", {}).get("name") == "swift-render", "serverInfo.name = swift-render")
    c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})     # must not be answered
    r = c.request("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}})
    check(r["result"]["protocolVersion"] == "2025-11-25", "unknown protocolVersion → newest supported")
    check(c.request("ping").get("result") == {}, "ping → {}")
    r = c.request("tools/list")
    names = {t["name"] for t in r["result"]["tools"]}
    check(names == TOOLS, f"tools/list has the 13 contract tools ({len(names)})")
    check(all(t["inputSchema"].get("type") == "object" for t in r["result"]["tools"]), "every inputSchema is an object")
    r = c.request("resources/list")
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

    if args.full:
        print("review round trip")
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
                stored = json.load(open(os.path.join(ROOT, ".swift-render/reviews", f"{scene}.json")))
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
    print("\n" + ("PASS" if not failures else f"FAIL ({len(failures)}): " + "; ".join(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
