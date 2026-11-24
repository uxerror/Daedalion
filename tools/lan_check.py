#!/usr/bin/env python3
"""LAN check: two headless clients join a remote dedicated server; Ada drives, Bob observes."""
import json, os, subprocess, sys, tempfile, time, pathlib, threading, queue

ADDR, PORT = sys.argv[1], sys.argv[2]
root = pathlib.Path(tempfile.mkdtemp(prefix="lan-"))
out = queue.Queue()
procs = {}


def launch(name):
    d = root / name
    d.mkdir()
    env = dict(os.environ, XDG_DATA_HOME=str(d / "data"), COGITO_TEST_CONTROL=str(d))
    args = ["nice", "-n", "19", "godot", "--headless", "--path", ".", "res://tests/net/process_peer.tscn",
            "--", "--role", "client", "--port", PORT, "--name", name, "--address", ADDR,
            "--stop", str(d / "stop"), "--save-dir", str(d / "world")]
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                         cwd=str(pathlib.Path(__file__).resolve().parent.parent))
    procs[name] = (p, d)
    threading.Thread(target=lambda: [out.put((name, l.rstrip())) for l in p.stdout], daemon=True).start()


def until(pred, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        try:
            name, line = out.get(timeout=end - time.time())
        except queue.Empty:
            break
        if "SCRIPT ERROR" in line or line.startswith("NET FAILED"):
            print(name, line)
        r = pred(name, line)
        if r:
            return r
    raise SystemExit("timeout")


last = {}
def pos(name, line):
    if line.startswith("NET POS "):
        last[name] = json.loads(line[8:])
    return None

launch("Ada")
until(lambda n, l: l.startswith("NET STATE") and n == "Ada")
launch("Bob")
until(lambda n, l: n == "Bob" and l.startswith("NET STATE") and "Ada" in l and "Bob" in l)
t0 = time.time()
until(lambda n, l: (pos(n, l), "Ada" in last.get("Bob", {}).get("actors", {}))[1], 20)
start_bob = last["Bob"]["actors"]["Ada"]
start_ada = last["Ada"]["actors"]["Ada"]
(procs["Ada"][1] / "drive-1").touch()
until(lambda n, l: (pos(n, l), last.get("Ada", {}).get("drive") == 1 and last["Ada"]["progress"] >= 140)[1], 30)
time.sleep(1.0)
until(lambda n, l: (pos(n, l), n == "Bob")[1], 5)
end_bob = last["Bob"]["actors"]["Ada"]
end_ada = last["Ada"]["actors"]["Ada"]
peak = None
print("Ada on Ada:", [round(a - b, 2) for a, b in zip(end_ada, start_ada)])
print("Ada on Bob:", [round(a - b, 2) for a, b in zip(end_bob, start_bob)])
print("disagreement m:", round(sum((a - b) ** 2 for a, b in zip(end_ada, end_bob)) ** 0.5, 3))
for p, d in procs.values():
    (d / "stop").touch()
for p, _ in procs.values():
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()
