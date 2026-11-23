#!/usr/bin/env python3
"""Collect GDScript warnings/errors from Godot's language server (headless editor).

Godot only reports its static warnings (unused variables, shadowing, unsafe
calls...) inside the editor, so this starts `godot --headless --editor
--lsp-port`, opens every project script over LSP and collects the diagnostics.
Existing warnings are recorded in tools/gd_warnings_baseline.json; the check
fails on parse errors and on warnings a file did not have before.

    GODOT_BIN=godot python3 tools/gd_warnings.py            # check
    GODOT_BIN=godot python3 tools/gd_warnings.py --update   # rewrite the baseline
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tools" / "gd_warnings_baseline.json"
EXCLUDED = ("addons/gdUnit4/", "addons/godot_state_charts/", "addons/input_helper/")
PORT = int(os.environ.get("GD_LSP_PORT", "6105"))


class Lsp:
    def __init__(self, port: int, deadline: float):
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise RuntimeError("Godot LSP did not start")
                time.sleep(1)
        self.sock.settimeout(1)
        self.buf = b""
        self.next_id = 1

    def send(self, method: str, params: dict, request: bool = False) -> None:
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        if request:
            msg["id"] = self.next_id
            self.next_id += 1
        body = json.dumps(msg).encode()
        self.sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def messages(self, timeout: float):
        end = time.time() + timeout
        while time.time() < end:
            while b"\r\n\r\n" in self.buf:
                head, rest = self.buf.split(b"\r\n\r\n", 1)
                match = re.search(rb"Content-Length: (\d+)", head)
                if not match:
                    raise RuntimeError(f"bad LSP header: {head!r}")
                length = int(match.group(1))
                if len(rest) < length:
                    break
                self.buf = rest[length:]
                yield json.loads(rest[:length])
            try:
                self.sock.settimeout(max(0.01, min(0.5, end - time.time())))
                chunk = self.sock.recv(1 << 16)
                if not chunk:
                    return
                self.buf += chunk
            except socket.timeout:
                yield None  # lets callers check their own exit conditions


def project_scripts() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.gd"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.split()
    return sorted(p for p in out if not p.startswith(EXCLUDED) and (ROOT / p).exists())


def normalize(message: str) -> str:
    # Warning kind without names/numbers, so renames and line shifts don't matter.
    m = re.match(r"\s*\(([A-Z_]+)\)", message) or re.search(r"\(([A-Z_]+)\)\s*$", message)
    if m:
        return m.group(1)
    return re.sub(r'"[^"]*"|\d+', "_", message).strip()[:80]


def collect(godot: str, scripts: list[str]) -> dict[str, list[dict]]:
    proc = subprocess.Popen(
        [godot, "--headless", "--editor", "--path", str(ROOT), "--lsp-port", str(PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        t0 = time.time()
        lsp = Lsp(PORT, time.time() + 600)
        print(f"lsp up after {time.time() - t0:.0f}s", file=sys.stderr)
        root_uri = ROOT.as_uri()
        lsp.send("initialize", {"processId": os.getpid(), "rootUri": root_uri, "capabilities": {}}, True)
        for msg in lsp.messages(30):
            if msg and msg.get("id") == 1:
                break
        lsp.send("initialized", {})
        diags: dict[str, list[dict]] = {}
        uri_to_path = {(ROOT / p).as_uri(): p for p in scripts}
        for p in scripts:
            lsp.send("textDocument/didOpen", {"textDocument": {
                "uri": (ROOT / p).as_uri(), "languageId": "gdscript", "version": 1,
                "text": (ROOT / p).read_text(encoding="utf-8-sig")}})
            for msg in lsp.messages(0.02):
                if msg and msg.get("method") == "textDocument/publishDiagnostics":
                    path = uri_to_path.get(msg["params"]["uri"])
                    if path:
                        diags[path] = msg["params"]["diagnostics"]
        print(f"opened {len(scripts)} scripts after {time.time() - t0:.0f}s", file=sys.stderr)
        quiet_until = time.time() + 5
        for msg in lsp.messages(120):
            if msg and msg.get("method") == "textDocument/publishDiagnostics":
                path = uri_to_path.get(msg["params"]["uri"])
                if path:
                    diags[path] = msg["params"]["diagnostics"]
                quiet_until = time.time() + 5
            if len(diags) >= len(scripts) and time.time() > quiet_until:
                break
        print(f"diagnostics for {len(diags)} scripts after {time.time() - t0:.0f}s", file=sys.stderr)
        return diags
    finally:
        proc.kill()
        proc.wait()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    godot = os.environ.get("GODOT_BIN", "godot")
    scripts = project_scripts()
    diags = collect(godot, scripts)

    missing = [p for p in scripts if p not in diags]
    errors: list[str] = []
    counts: dict[str, Counter] = {}
    details: dict[str, list[str]] = {}
    for path, items in diags.items():
        c = Counter()
        for d in items:
            line = d["range"]["start"]["line"] + 1
            text = f"{path}:{line}: {d['message']}"
            if d.get("severity") == 1:
                errors.append(text)
                continue
            key = normalize(d["message"])
            c[key] += 1
            details.setdefault(path, []).append(f"{text} [{key}]")
        if c:
            counts[path] = c

    if args.update:
        BASELINE.write_text(json.dumps(
            {p: dict(sorted(c.items())) for p, c in sorted(counts.items())}, indent=1) + "\n")
        print(f"baseline updated: {sum(sum(c.values()) for c in counts.values())} warnings")
        for e in errors:
            print("ERROR", e)
        return 1 if errors else 0

    known = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    failures = [f"ERROR {e}" for e in errors]
    for path, c in counts.items():
        allowed = Counter(known.get(path, {}))
        for key, n in c.items():
            if n > allowed[key]:
                failures.append(f"{path}: {key} {allowed[key]} -> {n}")
                failures += [f"    {l}" for l in details[path] if l.endswith(f"[{key}]")]
    if args.verbose:
        for path in sorted(details):
            for l in details[path]:
                print(l)
    for f in failures:
        print(f)
    if missing:
        print(f"note: no diagnostics received for {len(missing)} script(s), e.g. {missing[:3]}")
    total = sum(sum(c.values()) for c in counts.values())
    print(f"gd_warnings: {len(scripts)} files, {total} warnings, {len(errors)} errors, "
          f"{len(failures) - len(errors)} new")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
