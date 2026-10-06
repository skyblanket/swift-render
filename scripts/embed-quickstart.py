#!/usr/bin/env python3
"""Embed docs/ai-quickstart.md in swift-render-mcp, so its `docs` tool and resources work anywhere.

    python3 scripts/embed-quickstart.py           # rewrite Sources/SwiftRenderMCP/QuickstartText.swift
    python3 scripts/embed-quickstart.py --check   # exit 1 when that file is stale

Run it after editing docs/ai-quickstart.md (MCPCreateTests fails until you do).
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "docs", "ai-quickstart.md")
TARGET = os.path.join(ROOT, "Sources", "SwiftRenderMCP", "QuickstartText.swift")


def render(markdown):
    body = markdown.rstrip("\n")
    delimiter = "#"
    while ('"""' + delimiter) in body or ("\\" + delimiter) in body:
        delimiter += "#"
    return (
        "// Generated from docs/ai-quickstart.md by scripts/embed-quickstart.py — do not edit.\n"
        "// swiftlint:disable all\n\n"
        "enum QuickstartText {\n"
        f"    static let markdown = {delimiter}\"\"\"\n"
        f"{body}\n"
        f"\"\"\"{delimiter}\n"
        "}\n"
    )


def main():
    with open(SOURCE, encoding="utf-8") as f:
        wanted = render(f.read())
    current = open(TARGET, encoding="utf-8").read() if os.path.exists(TARGET) else ""
    if "--check" in sys.argv:
        if current != wanted:
            print(f"{os.path.relpath(TARGET, ROOT)} is stale: run python3 scripts/embed-quickstart.py", file=sys.stderr)
            sys.exit(1)
        return
    if current != wanted:
        with open(TARGET, "w", encoding="utf-8") as f:
            f.write(wanted)
        print(f"wrote {os.path.relpath(TARGET, ROOT)}")


if __name__ == "__main__":
    main()
