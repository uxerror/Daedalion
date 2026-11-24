#!/usr/bin/env python3
"""Exercise CogitoNet over loopback ENet in fresh Godot processes, after project import."""

import json
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
            cmd, cwd=ROOT, env={**os.environ, "XDG_DATA_HOME": str(self.home)},
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

    def dedicated(self):
        self.start(dedicated=True)
        first = self.fixture("Ada", "client")
        ada, _ = self.state(first, ["Ada"])
        second = self.fixture("Ben", "client")
        ben, roster = self.state(second, ["Ada", "Ben"])
        if self.state(first, roster) != (ada, roster) or roster != {"Ada": ada, "Ben": ben}:
            raise CheckFailed("clients disagree on identities")
        self.expect_rejection("old", "Content version mismatch", extra=("--content", "wrong"))
        self.expect_rejection("duplicate", "Identity already connected", copy_from=first)
        self.stop(first)
        self.state(second, ["Ben"])
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
        print("PASS dedicated + 2 clients: roster, version, duplicate, reconnect, server restart")

    def listen(self):
        self.start(dedicated=False)
        host, _ = self.state(self.server, ["Host"])
        client = self.fixture("Ada", "client")
        ada, roster = self.state(client, ["Host", "Ada"])
        if self.state(self.server, roster) != (host, roster) or roster != {"Host": host, "Ada": ada}:
            raise CheckFailed("listen roster differs")
        self.stop(client)
        self.state(self.server, ["Host"])
        self.stop(self.server)
        print("PASS listen host + 1 client: host identity, shared roster, departure")


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
