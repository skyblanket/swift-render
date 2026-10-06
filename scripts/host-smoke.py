#!/usr/bin/env python3
"""Smoke test + timings for `swift-render serve` (the Studio render host).

Spawns the built CLI in serve mode against a throwaway project root
(SWIFT_RENDER_ROOT, so the repo stays clean), drives the wire protocol from
Sources/SwiftRenderKit/HostProtocol.swift over real pipes, asserts the answers,
and prints latency/throughput numbers.

    swift build && python3 scripts/host-smoke.py
    python3 scripts/host-smoke.py --bin .build/release/swift-render --scenes TimelineDemo,NeverHeard

Exit status 0 = every check passed.
"""
import argparse
import base64
import json
import os
import queue
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILURES = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        FAILURES.append(what)
    return cond


def png_size(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    return struct.unpack(">II", data[16:24])


def jpeg_size(data):
    assert data[:2] == b"\xff\xd8", "not a JPEG"
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    raise AssertionError("no SOF marker")


class Host:
    """One `serve` child: a reader thread decodes JSON lines (+ raw payloads)."""

    def __init__(self, binary, root, env_extra=None):
        env = dict(os.environ, SWIFT_RENDER_ROOT=root)
        env.update(env_extra or {})
        self.t0 = time.perf_counter()
        self.proc = subprocess.Popen([binary, "serve"], cwd=REPO, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.inbox = queue.Queue()
        self.stderr_lines = []
        self.bad_lines = []
        self.next_id = 1
        self.events = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read(self):
        buf = b""
        out = self.proc.stdout
        while True:
            nl = buf.find(b"\n")
            while nl < 0:
                chunk = out.read(1 << 16)
                if not chunk:
                    self.inbox.put(None)
                    return
                buf += chunk
                nl = buf.find(b"\n")
            line, buf = buf[:nl], buf[nl + 1:]
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                self.bad_lines.append(line[:200])
                continue
            frame = (msg.get("result") or {}).get("frame") or msg.get("frame")
            payload = None
            if frame and frame.get("bytes"):
                n = frame["bytes"]
                while len(buf) < n:
                    chunk = out.read(max(1 << 16, n - len(buf)))
                    if not chunk:
                        self.inbox.put(None)
                        return
                    buf += chunk
                payload, buf = buf[:n], buf[n:]
            self.inbox.put((time.perf_counter(), msg, payload))

    def _read_err(self):
        for raw in self.proc.stderr:
            self.stderr_lines.append(raw.decode("utf-8", "replace").rstrip())

    def send(self, method, **params):
        rid = self.next_id
        self.next_id += 1
        req = {"id": rid, "method": method}
        if params:
            req["params"] = params
        self.proc.stdin.write((json.dumps(req) + "\n").encode())
        self.proc.stdin.flush()
        return rid

    def next(self, timeout=120):
        item = self.inbox.get(timeout=timeout)
        if item is None:
            raise EOFError("host closed stdout")
        return item

    def wait_for(self, pred, timeout=120):
        """Next message matching pred; everything else lands in self.events."""
        deadline = time.perf_counter() + timeout
        while True:
            ts, msg, payload = self.next(timeout=max(0.01, deadline - time.perf_counter()))
            if pred(msg):
                return ts, msg, payload
            self.events.append((ts, msg, payload))

    def call(self, method, timeout=300, **params):
        start = time.perf_counter()
        rid = self.send(method, **params)
        ts, msg, payload = self.wait_for(lambda m: m.get("id") == rid, timeout)
        return msg, payload, (ts - start) * 1000

    def take_event(self, name, timeout=120, pred=lambda m: True):
        for i, (ts, msg, payload) in enumerate(self.events):
            if msg.get("event") == name and pred(msg):
                del self.events[i]
                return ts, msg, payload
        return self.wait_for(lambda m: m.get("event") == name and pred(m), timeout)

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        return self.proc.wait(timeout=30)


def ms_stats(xs):
    xs = sorted(xs)
    return f"median {statistics.median(xs):6.1f} ms  p90 {xs[int(0.9 * (len(xs) - 1))]:6.1f}  (n={len(xs)})"


def stream_throughput(h, fmt, count, max_width, window=4):
    """Studio-style credit window: grant `window`, return one credit per frame received."""
    start = time.perf_counter()
    msg, _, _ = h.call("stream", **{"from": 0.0, "to": 1e9, "maxWidth": max_width, "format": fmt, "credits": window})
    sid = msg["id"]
    got, payload_bytes, host_ms = 0, 0, []
    first_t = None
    while got < count:
        ts, ev, payload = h.wait_for(lambda m: m.get("streamID") == sid, timeout=60)
        if ev.get("event") == "streamEnd":
            break
        f = ev["frame"]
        if got == 0:
            first_t = ts
        got += 1
        host_ms.append(f["ms"])
        payload_bytes += len(payload) if payload is not None else len(f["data"])
        if got + window - 1 < count:
            h.send("credit", streamID=sid, credits=1)
    h.call("cancel", streamID=sid)
    wall = time.perf_counter() - start
    steady = (time.perf_counter() - first_t) if first_t else wall
    return got, wall, steady, payload_bytes, host_ms


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=os.path.join(REPO, ".build/debug/swift-render"))
    ap.add_argument("--scenes", default="TimelineDemo,LaunchFilm,NeverHeard",
                    help="scenes to time frames for (maxWidth 960)")
    ap.add_argument("--frames", type=int, default=12, help="frames per timing sample")
    ap.add_argument("--keep", action="store_true", help="keep the temp project root")
    args = ap.parse_args()
    if not os.access(args.bin, os.X_OK):
        sys.exit(f"no binary at {args.bin} — run `swift build` first")

    root = tempfile.mkdtemp(prefix="sr-host-smoke-")
    open(os.path.join(root, "Package.swift"), "w").write("// swift-tools-version: 5.10\n")
    numbers = []
    h = Host(args.bin, root)
    h2 = None
    try:
        print("ready")
        ts, ready, _ = h.next(timeout=60)
        start_ms = (ts - h.t0) * 1000
        check(ready.get("event") == "ready", "first line is the ready event")
        check(ready.get("protocolVersion") == 1 and ready.get("version"), "ready carries version + protocolVersion")
        names = [s["name"] for s in ready.get("scenes", [])]
        check({"TimelineDemo", "AudioBars"} <= set(names), f"ready lists scenes ({len(names)})")
        numbers.append(("process start → ready", f"{start_ms:.0f} ms"))

        print("errors")
        msg, _, _ = h.call("frame", t=1.0)
        check(msg.get("error", {}).get("code") == "noScene", "frame before open → noScene")
        msg, _, _ = h.call("open", scene="NoSuchScene")
        check(msg.get("error", {}).get("code") == "unknownScene", "unknown scene → unknownScene")
        rid = h.next_id
        h.proc.stdin.write(b'{"id":%d,"method":"explode"}\n' % rid)
        h.next_id += 1
        _, msg, _ = h.wait_for(lambda m: m.get("id") == rid)
        check(msg.get("error", {}).get("code") == "badParams", "unknown method → badParams with its id")
        msg, _, _ = h.call("list")
        check(len(msg["result"]["scenes"]) == len(names), "list matches ready")

        print("open + frames (TimelineDemo)")
        msg, _, open_ms = h.call("open", scene="TimelineDemo", fps=30)
        info = msg["result"]["info"]
        check(abs(info["duration"] - 9.9) < 1e-9 and info["fps"] == 30, "open → SceneInfo")
        numbers.append(("open TimelineDemo", f"{open_ms:.0f} ms"))
        msg, _, _ = h.call("frame", t=1.0, maxWidth=960)
        f = msg["result"]["frame"]
        jpg = base64.b64decode(f["data"])
        check(f["format"] == "jpeg" and jpeg_size(jpg) == (960, 540) and (f["width"], f["height"]) == (960, 540),
              f"jpeg frame 960×540 ({len(jpg) // 1024} KB, {f['ms']} ms)")
        check(f.get("index") == 30, "frame index at the opened fps")
        msg, _, _ = h.call("frame", t=1.0, maxWidth=480, format="png")
        png = base64.b64decode(msg["result"]["frame"]["data"])
        check(png_size(png) == (480, 270), "png frame 480×270")
        msg, _, _ = h.call("frame", t=1.0, format="bgra8")
        check(msg.get("error", {}).get("code") == "badParams", "bgra8 without binaryFrames → badParams")

        print("coalescing")
        ids = [h.send("frame", t=0.1 * i, maxWidth=320) for i in range(1, 9)]
        answers = {}
        while len(answers) < len(ids):
            _, m, _ = h.wait_for(lambda m: m.get("id") in ids)
            answers[m["id"]] = m
        superseded = [i for i in ids if answers[i].get("error", {}).get("code") == "superseded"]
        check("result" in answers[ids[-1]], "newest frame always renders")
        check(all("result" in answers[i] or i in superseded for i in ids), "older frames render or are superseded")
        print(f"        {len(superseded)}/{len(ids) - 1} older frames superseded")

        print("binary frames + streams")
        msg, _, _ = h.call("open", scene="TimelineDemo", fps=30, binaryFrames=True)
        msg, payload, _ = h.call("frame", t=2.0, maxWidth=960, format="bgra8")
        f = msg["result"]["frame"]
        check(f["data"] == "" and f["bytes"] == 960 * 540 * 4 and payload is not None and len(payload) == f["bytes"],
              "bgra8 frame: header + 2 MB raw payload")
        msg, _, _ = h.call("stream", **{"from": 0.0, "to": 0.5, "fps": 10, "maxWidth": 320, "credits": 3})
        sid = msg["id"]
        got = [h.wait_for(lambda m: m.get("streamID") == sid)[1] for _ in range(3)]
        check([g["frame"]["index"] for g in got] == [0, 3, 6], "stream: 3 credits → 3 frames (indices at 30 fps)")
        h.call("credit", streamID=sid, credits=10)
        rest = []
        while True:
            _, m, _ = h.wait_for(lambda m: m.get("streamID") == sid)
            rest.append(m)
            if m.get("event") == "streamEnd":
                break
        check([m["frame"]["t"] for m in rest[:-1]] == [0.3, 0.4], "credit resumes the stream until `to`")
        check(rest[-1].get("event") == "streamEnd" and "message" not in rest[-1], "streamEnd after the last frame")

        tl_stream = {}
        for fmt in ("jpeg", "bgra8"):
            n, wall, steady, nbytes, host_ms = stream_throughput(h, fmt, 60, 960)
            fps = (n - 1) / steady if n > 1 else 0
            tl_stream[fmt] = fps
            check(n == 60, f"stream {fmt}: 60 frames")
            numbers.append((f"stream TimelineDemo @960 {fmt}",
                            f"{fps:5.1f} fps  ({nbytes / n / 1024:.0f} KB/frame, host {statistics.median(host_ms):.1f} ms/frame)"))

        print("still + check")
        still = os.path.join(root, "shots", "a.png")
        msg, _, still_ms = h.call("still", t=3.0, path=still)
        check(msg["result"]["path"] == still and png_size(open(still, "rb").read()) == (1920, 1080),
              f"still: lossless 1920×1080 PNG written ({still_ms:.0f} ms)")
        msg, _, check_ms = h.call("check", path="out/check.png")
        rep = msg["result"]["report"]
        check(os.path.exists(msg["result"]["path"]) and rep[0].startswith("scene TimelineDemo"),
              f"check: contact sheet + {len(rep)} report lines ({check_ms:.0f} ms)")

        print("props (AudioBars)")
        props = {"title": "SMOKE", "subtitle": "HOST", "barCount": 12, "accentHex": "#33CCFF", "bassPunch": 0.3}
        msg, _, _ = h.call("open", scene="AudioBars", width=960, height=540, fps=30, propsJSON=json.dumps(props))
        check(json.loads(msg["result"]["info"]["propsJSON"]) == props, "open with propsJSON")
        check(os.path.exists(os.path.join(root, ".swift-render/cache/props-AudioBars.json")), "props written to cache")
        msg, _, _ = h.call("setProps", propsJSON='{"title": 3}')
        check(msg.get("error", {}).get("code") == "badParams", "undecodable props → badParams")
        props["title"] = "AGAIN"
        msg, _, _ = h.call("setProps", propsJSON=json.dumps(props))
        check(json.loads(msg["result"]["info"]["propsJSON"])["title"] == "AGAIN", "setProps")
        msg, _, _ = h.call("frame", t=2.0, maxWidth=480)
        check("result" in msg, "frame after setProps")

        print("knobs")
        msg, _, _ = h.call("open", scene="TimelineDemo", fps=30)
        msg, _, _ = h.call("setKnobs", knobs={"smoke.knob": 0.5}, persist=True, reprobe=False)
        knob_file = os.path.join(root, ".swift-render/knobs/TimelineDemo.json")
        check("result" in msg and json.load(open(knob_file)) == {"smoke.knob": 0.5}, "setKnobs persist → knob file")
        msg, _, _ = h.call("setKnobs", knobs={}, persist=True)
        check(not os.path.exists(knob_file), "empty knob set removes the file")

        print("frame timings (maxWidth 960)")
        for scene in [s for s in args.scenes.split(",") if s]:
            if scene not in names:
                print(f"  skip  {scene} (not in this binary)")
                continue
            msg, _, open_ms = h.call("open", scene=scene, fps=30)
            if not check("result" in msg, f"open {scene}"):
                continue
            info = msg["result"]["info"]
            dur = info["duration"]
            # first frame after open (cold caches), then a spread of times
            msg, _, first_rt = h.call("frame", t=min(1.0, dur / 2), maxWidth=960)
            host_ms, rt_ms = [], []
            for i in range(args.frames):
                t = dur * (i + 0.5) / args.frames
                msg, _, rt = h.call("frame", t=t, maxWidth=960)
                if "result" in msg:
                    host_ms.append(msg["result"]["frame"]["ms"])
                    rt_ms.append(rt)
            check(len(host_ms) == args.frames, f"{scene}: {args.frames} frames")
            numbers.append((f"open {scene}", f"{open_ms:.0f} ms ({info['kind']}, {dur:.1f}s, audio cached: {bool(info.get('audioPath'))})"))
            numbers.append((f"frame {scene} @960 jpeg", f"host {ms_stats(host_ms)} · round trip {statistics.median(rt_ms):.1f} ms · first {first_rt:.0f} ms"))
            if ready_scene := next((s for s in ready["scenes"] if s["name"] == scene), None):
                if ready_scene["hasSoundtrack"]:
                    t_open = time.perf_counter()
                    ts, ev, _ = h.take_event("audio", timeout=300)
                    check(ev.get("audioPath") and os.path.exists(ev["audioPath"]) and len(ev.get("loudness", [])) > 0,
                          f"{scene}: audio event with cached WAV + loudness")
                    numbers.append((f"audio {scene}", f"ready {(ts - t_open) * 1000 + open_ms:.0f} ms after open (background)"))

        print("shutdown")
        msg, _, _ = h.call("shutdown")
        check(msg.get("result") == {}, "shutdown → {}")
        code = h.proc.wait(timeout=30)
        check(code == 0, f"exit 0 after shutdown (got {code})")
        check(not h.bad_lines, f"every stdout line decoded ({len(h.bad_lines)} stray)")

        print("warm restart + stdin EOF")
        h2 = Host(args.bin, root)
        ts, ready2, _ = h2.next(timeout=60)
        numbers.append(("process start → ready (2nd run)", f"{(ts - h2.t0) * 1000:.0f} ms"))
        for scene in [s for s in args.scenes.split(",") if s and s in names]:
            if next(s for s in ready2["scenes"] if s["name"] == scene)["hasSoundtrack"]:
                msg, _, open_ms = h2.call("open", scene=scene, fps=30)
                check(bool(msg["result"]["info"].get("audioPath")), f"{scene}: cached audio path on reopen ({open_ms:.0f} ms)")
                ts0 = time.perf_counter()
                ts, ev, _ = h2.take_event("audio", timeout=300)
                numbers.append((f"audio {scene} (cache hit)", f"{(ts - ts0) * 1000 + open_ms:.0f} ms after open"))
        code = h2.close()
        check(code == 0, f"exit 0 on stdin EOF (got {code})")
    except Exception as e:  # report, then fail
        import traceback
        traceback.print_exc()
        FAILURES.append(f"exception: {e}")
    finally:
        if h.proc.poll() is None:
            h.proc.kill()
        print("\nhost stderr (tail):")
        for line in h.stderr_lines[-12:]:
            print("   ", line)
        if h2 is not None:
            print("restarted host stderr:")
            for line in h2.stderr_lines[-6:]:
                print("   ", line)
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print(f"kept {root}")

    print("\nnumbers (binary: %s)" % os.path.relpath(args.bin, REPO))
    for k, v in numbers:
        print(f"  {k:<36} {v}")
    print("\n%s" % ("PASS" if not FAILURES else "FAIL: " + "; ".join(FAILURES)))
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
