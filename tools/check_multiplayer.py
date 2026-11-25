#!/usr/bin/env python3
"""Exercise CogitoNet over loopback ENet in fresh Godot processes, after project import."""

import json
import math
import os
import queue
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = "res://tests/net/process_peer.tscn"
SCENARIO_SECONDS = 45


class CheckFailed(Exception):
    pass


class BindFailed(CheckFailed):
    pass


def available_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Role:
    def __init__(self, directory, args, events, expected_failure):
        self.directory = directory
        self.home = directory / "data"
        self.stop_file = directory / "stop"
        self.events = deque()
        self.samples = deque(maxlen=600)
        self.generation = 0
        self.order = 0
        self.tail = deque(maxlen=25)
        self.expected_failure = expected_failure
        self.stopping = False
        self.exited = False
        self.killed = False
        self.bind_failed = False
        self.home.mkdir(parents=True, exist_ok=True)
        cmd = [
            *shlex.split(os.getenv("NICE", "nice -n 19")),
            os.getenv("GODOT_BIN", "godot"), "--headless", "--path", str(ROOT),
            "--max-fps", "60", *args,
        ]
        self.process = subprocess.Popen(
            cmd, cwd=ROOT, env={**os.environ, "XDG_DATA_HOME": str(self.home),
                               "COGITO_TEST_CONTROL": str(directory)},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            errors="replace", start_new_session=True,
        )

        def read_output():
            with self.process.stdout as stream:
                for line in stream:
                    events.put((self, line.rstrip("\n")))
            events.put((self, None))

        self.reader = threading.Thread(target=read_output, daemon=True)
        self.reader.start()

    def kill(self):
        if self.killed:
            return
        self.killed = True
        self.stopping = True
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait()
        self.reader.join()


class Scenario:
    def __init__(self, directory):
        self.directory = directory
        self.roles = []
        self.output = queue.Queue()
        self.deadline = time.monotonic() + SCENARIO_SECONDS
        self.port = None
        self.server = None

    def launch(self, label, args, copy_from=None, expected_failure=None):
        directory = self.directory / f"{len(self.roles)}-{label}"
        if copy_from:
            identities = list(copy_from.home.rglob("net/identity.cfg"))
            if len(identities) != 1:
                raise CheckFailed(f"{copy_from.directory.name}: expected one client identity file")
            source = identities[0]
            target = directory / "data" / source.relative_to(copy_from.home)
            target.parent.mkdir(parents=True)
            shutil.copyfile(source, target)
        role = Role(directory, args, self.output, expected_failure)
        self.roles.append(role)
        return role

    def fixture(self, label, role, copy_from=None, expected_failure=None, extra=()):
        directory = self.directory / f"{len(self.roles)}-{label}"
        args = [
            FIXTURE, "--", "--role", role, "--port", str(self.port), "--name", label,
            "--stop", str(directory / "stop"), "--save-dir", str(self.directory / "world"),
            *extra,
        ]
        return self.launch(label, args, copy_from, expected_failure)

    def next_line(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise CheckFailed("45 s scenario deadline exceeded")
        try:
            role, line = self.output.get(timeout=remaining)
        except queue.Empty:
            raise CheckFailed("45 s scenario deadline exceeded") from None
        if line is None:
            role.exited = True
            try:
                rc = role.process.wait(timeout=max(0, self.deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise CheckFailed("45 s scenario deadline exceeded during exit") from None
            if role.bind_failed and role is self.server:
                raise BindFailed(f"could not bind UDP {self.port}")
            if not role.stopping or (rc != 0 and not role.killed):
                raise CheckFailed(f"{role.directory.name} exited ({rc})")
            return
        role.tail.append(line)
        if "SCRIPT ERROR" in line or "Parse Error" in line:
            raise CheckFailed(line)
        if "Cannot bind 127.0.0.1:" in line and role is self.server:
            role.bind_failed = True
        if line.startswith("NET FAILED "):
            reason = json.loads(line.removeprefix("NET FAILED "))
            if reason != role.expected_failure and not role.bind_failed:
                raise CheckFailed(f"{role.directory.name}: {reason}")
        if line.startswith("NET POS "):
            role.samples.append(json.loads(line.removeprefix("NET POS ")))
            return
        if line.startswith("NET ") or "CogitoNet rejected peer " in line:
            role.events.append(line)

    def wait_line(self, role, predicate):
        while True:
            for line in role.events:
                if predicate(line):
                    role.events.remove(line)
                    return line
            self.next_line()

    def start(self, dedicated, restart=False):
        for attempt in range(3):
            if not restart:
                self.port = available_port()
            if dedicated:
                self.server = self.launch("dedicated", [
                    "--", "--server", "--bind", "127.0.0.1", "--port", str(self.port),
                    "--level", "res://tests/net/process_arena.tscn",
                    "--max-players", "4", "--save-dir", str(self.directory / "world"),
                ])
            else:
                self.server = self.fixture("Host", "host")
            try:
                self.wait_line(self.server, lambda line: line == f"NET READY port={self.port}")
                return
            except BindFailed:
                self.server.kill()
                if attempt == 2:
                    raise

    def state(self, role, names):
        line = self.wait_line(role, lambda event: event.startswith("NET STATE "))
        data = json.loads(line.removeprefix("NET STATE "))
        roster = data["roster"]
        ids = {r["display_name"]: r["player_id"] for r in roster}
        if (set(ids) != set(names) or len(set(ids.values())) != len(roster)
                or len({r["peer_id"] for r in roster}) != len(roster)
                or data["local"] not in ids.values()):
            raise CheckFailed(f"{role.directory.name}: unexpected roster {data!r}")
        return data["local"], ids

    def expect_rejection(self, label, reason, copy_from=None, extra=()):
        role = self.fixture(label, "client", copy_from, reason, extra)
        self.wait_line(role, lambda line: line.startswith("NET FAILED "))
        self.wait_line(self.server, lambda line: "CogitoNet rejected peer " in line and reason in line)
        self.stop(role)

    def stop(self, role):
        role.stopping = True
        role.stop_file.touch()
        while not role.exited:
            self.next_line()

    def pose(self, role, names, after=-1):
        while True:
            if role.samples:
                sample = role.samples[-1]
                if (sample["tick"] > after and set(sample["actors"]) == set(names)
                        and sample["count"] == len(names)):
                    return sample
            self.next_line()

    def stationary(self, role, names):
        first = self.pose(role, names)
        last = self.pose(role, names, first["tick"] + 24)
        for name in names:
            a, b = (s["actors"][name] for s in (first, last))
            if math.hypot(a[0] - b[0], a[2] - b[2]) > 0.03:
                raise CheckFailed(f"{name} moved without commands: {a} -> {b}")
        return last

    def drive(self, driver, name, names, observers):
        starts = {role: self.pose(role, names) for role in observers}
        driver.generation += 1
        (driver.directory / f"drive-{driver.generation}").touch()
        while (not driver.samples or driver.samples[-1]["drive"] != driver.generation
               or driver.samples[-1]["progress"] < 140):
            self.next_line()
        if driver is not self.server:
            self.wait_line(driver, lambda line: line.startswith("NET DROPPED JUMP "))
        positions = []
        for role, start in starts.items():
            # Let final snapshots cross the interpolation delay on every observing process.
            last = self.pose(role, names, role.samples[-1]["tick"] + 16)
            a, b = (s["actors"][name] for s in (start, last))
            delta = (b[0] - a[0], b[2] - a[2])
            peak = max(s["actors"][name][1] for s in role.samples
                       if s["tick"] >= start["tick"] and name in s["actors"])
            if not (-3.9 < delta[0] < -2.0 and -4.9 < delta[1] < -3.1 and peak - a[1] > 0.28):
                raise CheckFailed(f"{role.directory.name}: {name} travel {delta}, jump {peak-a[1]}")
            positions.append(b)
        if any(math.dist(positions[0], pos) > 0.2 for pos in positions[1:]):
            raise CheckFailed(f"{name}: peers disagree on final position {positions}")
        return positions[0]

    def sample(self, role, predicate):
        while not role.samples or not predicate(role.samples[-1]):
            self.next_line()
        return role.samples[-1]

    def order(self, role, **command):
        role.order += 1
        path = role.directory / f"order-{role.order}"
        pending = path.with_suffix(".tmp")
        pending.write_text(json.dumps(command))
        pending.replace(path)
        return self.sample(role, lambda s: s["order"] == role.order)

    def use(self, role, component, reason=None, **fields):
        self.order(role, op="use", component=component, **fields)
        def result():
            line = self.wait_line(role, lambda event: event.startswith("NET RESULT "))
            return json.loads(line.removeprefix("NET RESULT "))
        reply = result()
        if reply["ok"] != (reason is None) or reply.get("reason") != reason:
            raise CheckFailed(f"{role.directory.name}: unexpected interaction result {reply}")
        if fields.get("retry") and result() != reply:
            raise CheckFailed("duplicate request got a different result")

    def panels(self, first, second, first_name, walker=None):
        for role in (first, second):
            self.sample(role, lambda s: s["epoch"] > 0)
        self.use(first, "Door/Use", reason="Out of reach")
        self.order(self.server, op="stage", first=first_name)
        if walker:
            self.order(second, op="walk")
            self.sample(second, lambda s: s["walk"] == 0)
            blocked = self.sample(self.server, lambda s: s["actors"][walker][2] < -13.0)
            if blocked["actors"][walker][2] < -13.95 or blocked["open"]:
                raise CheckFailed("walker crossed the closed door")
        self.use(first, "Door/Use", retry=True)
        for role in (self.server, second):
            self.sample(role, lambda s: s["open"] and s["door_revision"] == 1)
        if walker:
            self.order(second, op="walk")
            self.sample(self.server, lambda s: s["actors"][walker][2] < -14.8)
            self.sample(second, lambda s: s["walk"] == 0)
            self.order(self.server, op="stage", first=first_name)
        self.use(second, "Button/Use")
        for role in (self.server, first):
            self.sample(role, lambda s: s["linked"])
        self.use(first, "Keypad/BasicInteraction", reason="Wrong code", action="submit_code", code="0000")
        if not self.server.samples[-1]["locked"] or not self.server.samples[-1]["keydoor_locked"]:
            raise CheckFailed("wrong code changed the world")
        self.use(first, "Keypad/BasicInteraction", action="submit_code", code="0420")
        for role in (self.server, second):
            self.sample(role, lambda s: not s["locked"] and not s["keydoor_locked"] and s["keydoor_open"])

    def devices(self, first, second, first_name, walker):
        self.order(self.server, op="devices", first=first_name)
        self.order(first, op="wheel", phase="start")
        self.wait_line(first, lambda line: line.startswith("NET RESULT ") and json.loads(
            line.removeprefix("NET RESULT "))["ok"])
        start = self.server.samples[-1]["tick"]
        self.sample(self.server, lambda s: s["tick"] >= start + 24)
        self.order(first, op="wheel", phase="release")
        self.wait_line(first, lambda line: line.startswith("NET RESULT ") and json.loads(
            line.removeprefix("NET RESULT "))["ok"])
        for role in (first, second, self.server):
            self.sample(role, lambda s: s["wheel_open"] and s["turned"])

        self.use(first, "PickDoor/Pick")
        self.sample(first, lambda s: s["picking"])
        self.order(self.server, op="fix_lock")
        self.order(first, op="tension")
        for role in (first, second, self.server):
            self.sample(role, lambda s: s["picked"] and not s["picking"])

        self.order(self.server, op="enter_zone", first=first_name)
        self.sample(first, lambda s: s["cutscene"] and s["cutscene_starts"] == 1)
        before = self.sample(second, lambda s: s["cut_used"])
        self.order(second, op="walk")
        self.sample(self.server, lambda s: s["actors"][walker][2] < before["actors"][walker][2] - 0.6)
        if second.samples[-1]["cutscene_starts"] or not first.samples[-1]["cutscene"]:
            raise CheckFailed("cutscene was not private while the observer moved")

    def dedicated(self):
        self.start(dedicated=True)
        first = self.fixture("Ada", "client")
        ada, _ = self.state(first, ["Ada"])
        self.stationary(self.server, ["Ada"])
        settled = self.drive(first, "Ada", ["Ada"], [self.server, first])
        second = self.fixture("Ben", "client")
        ben, roster = self.state(second, ["Ada", "Ben"])
        if self.state(first, roster) != (ada, roster) or roster != {"Ada": ada, "Ben": ben}:
            raise CheckFailed("clients disagree on identities")
        arrival = self.pose(second, roster)
        if math.dist(arrival["actors"]["Ada"], settled) > 0.2:
            raise CheckFailed(f"late-join pose {arrival} vs {settled}")
        self.drive(first, "Ada", roster, [self.server, second])
        self.drive(second, "Ben", roster, [self.server, first])
        self.panels(first, second, "Ada", "Ben")
        self.devices(first, second, "Ada", "Ben")
        late = self.fixture("Cy", "client")
        self.state(late, ["Ada", "Ben", "Cy"])
        self.state(first, ["Ada", "Ben", "Cy"])
        self.state(second, ["Ada", "Ben", "Cy"])
        baseline = self.sample(late, lambda s: s["epoch"] > 0)
        if (not baseline["open"] or not baseline["keydoor_open"] or baseline["locked"]
                or baseline["keydoor_locked"] or baseline["events"] or not baseline["wheel_open"]
                or not baseline["picked"] or not baseline["cut_used"] or baseline["cutscene_starts"]):
            raise CheckFailed(f"incorrect late-join world baseline: {baseline}")
        self.stop(late)
        self.state(first, roster)
        self.state(second, roster)
        self.expect_rejection("old", "Content version mismatch", extra=("--content", "wrong"))
        self.expect_rejection("duplicate", "Identity already connected", copy_from=first)
        self.stop(first)
        self.state(second, ["Ben"])
        self.pose(self.server, ["Ben"])
        self.pose(second, ["Ben"])
        again = self.fixture("Ada", "client", copy_from=first)
        if self.state(again, roster) != (ada, roster) or self.state(second, roster) != (ben, roster):
            raise CheckFailed("client restart changed identities")
        self.stop(again)
        self.state(second, ["Ben"])
        self.stop(second)
        self.server.kill()
        while not self.server.exited:
            self.next_line()
        self.start(dedicated=True, restart=True)
        restored = self.fixture("Ada", "client", copy_from=again)
        if self.state(restored, ["Ada"]) != (ada, {"Ada": ada}):
            raise CheckFailed("server restart changed identity")
        self.stop(restored)
        print("PASS dedicated + 2 clients: movement, collision, interaction retry, keypad, turnwheel, lockpick, private cutscene, silent late join, identity, restart")

    def listen(self):
        self.start(dedicated=False)
        host, _ = self.state(self.server, ["Host"])
        client = self.fixture("Ada", "client")
        ada, roster = self.state(client, ["Host", "Ada"])
        if self.state(self.server, roster) != (host, roster) or roster != {"Host": host, "Ada": ada}:
            raise CheckFailed("listen roster differs")
        self.stationary(self.server, roster)
        self.drive(self.server, "Host", roster, [self.server, client])
        self.drive(client, "Ada", roster, [self.server, client])
        self.panels(self.server, client, "Host")
        self.devices(self.server, client, "Host", "Ada")
        self.stop(client)
        self.state(self.server, ["Host"])
        self.pose(self.server, ["Host"])
        self.stop(self.server)
        print("PASS listen host + 1 client: movement, interactions in both directions, turnwheel, lockpick, private cutscene, host identity, departure")


def main():
    for name in ("dedicated", "listen"):
        with tempfile.TemporaryDirectory(prefix=f"cogito-{name}-") as directory:
            scenario = Scenario(Path(directory))
            try:
                getattr(scenario, name)()
            except (OSError, ValueError, KeyError, CheckFailed) as exc:
                print(f"FAIL {name}: {exc}", file=sys.stderr)
                for role in scenario.roles:
                    print(f"[{role.directory.name}]", *role.tail, sep="\n", file=sys.stderr)
                return 1
            finally:
                for role in reversed(scenario.roles):
                    role.kill()
    return 0


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
