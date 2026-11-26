#!/usr/bin/env python3
"""Exercise CogitoNet over loopback ENet in fresh Godot processes, after project import."""

import argparse
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
SCENARIO_SECONDS = 103


class CheckFailed(Exception):
    pass


class BindFailed(CheckFailed):
    pass


def available_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Role:
    def __init__(self, directory, args, events, expected_failure, bus):
        self.directory = directory
        self.home = directory / "data"
        self.stop_file = directory / "stop"
        self.events = deque()
        self.samples = deque(maxlen=600)
        self.generation = 0
        self.order = 0
        self.tail = deque(maxlen=25)
        self.expected_failure = expected_failure
        self.expected_exit = 0
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
        extra_env = {}
        if bus:
            extra_env = {"COGITO_FILE_BUS": str(bus),
                         "COGITO_FILE_ID": str(2 + int(directory.name.split("-", 1)[0]))}
        self.process = subprocess.Popen(
            cmd, cwd=ROOT, env={**os.environ, **extra_env, "XDG_DATA_HOME": str(self.home),
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
    def __init__(self, directory, file_transport=False):
        self.file_transport = file_transport
        self.bus = None
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
        role = Role(directory, args, self.output, expected_failure, self.bus)
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
            raise CheckFailed(f"{SCENARIO_SECONDS} s scenario deadline exceeded")
        try:
            role, line = self.output.get(timeout=remaining)
        except queue.Empty:
            raise CheckFailed(f"{SCENARIO_SECONDS} s scenario deadline exceeded") from None
        if line is None:
            role.exited = True
            try:
                rc = role.process.wait(timeout=max(0, self.deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise CheckFailed(f"{SCENARIO_SECONDS} s scenario deadline exceeded during exit") from None
            if role.bind_failed and role is self.server:
                raise BindFailed(f"could not bind UDP {self.port}")
            if not role.stopping or (rc != role.expected_exit and not role.killed):
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

    def start(self, dedicated, restart=False, friendly_fire=True, world="default", host_identity=None, autosave=60):
        for attempt in range(3):
            if not restart:
                self.port = 17777 if self.file_transport else available_port()
            if self.file_transport:
                self.bus = self.directory / f"bus-{len(self.roles):04d}"
                self.bus.mkdir()
            if dedicated and self.file_transport:
                self.server = self.fixture("dedicated", "authority", extra=(
                    "--world", world, "--autosave-seconds", str(autosave),
                    "--friendly-fire", str(friendly_fire).lower()))
            elif dedicated:
                self.server = self.launch("dedicated", [
                    "--", "--server", "--bind", "127.0.0.1", "--port", str(self.port),
                    "--level", "res://tests/net/process_arena.tscn", "--world", world,
                    "--autosave-seconds", str(autosave),
                    "--respawn-delay", "1.5", "--friendly-fire", str(friendly_fire).lower(),
                    "--max-players", "4", "--save-dir", str(self.directory / "world"),
                ])
            else:
                self.server = self.fixture("Host", "host", host_identity, extra=(
                    "--world", world, "--autosave-seconds", str(autosave)))
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
        role.peer_ids = {r["display_name"]: r["peer_id"] for r in roster}
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

    def physics(self, a, b, first, second, roster):
        def stage(place):
            self.order(self.server, op="physics_stage", place=place, first=first)
            tick = self.server.samples[-1]["tick"]
            self.pose(self.server, roster, tick + 8)

        def throw_and_settle(carrier, name):
            self.sample(carrier, lambda s: s["carrying"])
            self.order(carrier, op="walk")
            self.sample(self.server, lambda s: s["actors"][name][2] < -14.2)
            self.sample(carrier, lambda s: s["walk"] == 0)
            held = self.sample(self.server, lambda s: s["crate"][2] < -15)
            for viewer in (a, b):
                self.sample(viewer, lambda s: math.dist(s["crate"], held["crate"]) < 0.65)
            self.order(carrier, op="throw")
            self.sample(carrier, lambda s: not s["carrying"])
            rest = self.sample(self.server, lambda s: s["rest"])
            if math.dist(held["crate"], rest["crate"]) < 1.0:
                raise CheckFailed("thrown crate did not travel")
            for viewer in (a, b):
                self.sample(viewer, lambda s: math.dist(s["crate"], rest["crate"]) < 0.035)

        stage("carry")
        starts = {r: r.samples[-1] for r in (a, b)}
        if a is self.server:
            for carrier, name in ((a, first), (b, second)):
                if carrier is b:
                    stage("carry")
                self.use(carrier, "CarryBox/CarryableComponent", action="interact2")
                throw_and_settle(carrier, name)
        else:
            for role in (a, b):
                self.order(role, op="prepare_grab")
            for role in (a, b):
                self.order(role, op="race")
            replies = [json.loads(self.wait_line(r, lambda x: x.startswith("NET RESULT "))
                                  .removeprefix("NET RESULT ")) for r in (a, b)]
            if sum(reply["ok"] for reply in replies) != 1:
                raise CheckFailed(f"carry race: {replies}")
            winner = 0 if replies[0]["ok"] else 1
            throw_and_settle((a, b)[winner], (first, second)[winner])

        stage("seat")
        self.use(a, "Seat/BasicInteraction")
        self.sample(b, lambda s: s["seat"] == roster[first])
        self.use(b, "Seat/BasicInteraction", reason="In use")
        self.use(a, "Seat/BasicInteraction")
        self.sample(b, lambda s: not s["seat"])
        self.use(b, "Seat/BasicInteraction")
        self.sample(a, lambda s: s["seat"] == roster[second])
        self.use(b, "Seat/BasicInteraction")

        stage("vehicle")
        self.use(a, "Vehicle/BasicInteraction")
        origin = self.sample(b, lambda s: s["driver"] == roster[first])["vehicle"]
        self.order(a, op="walk")
        self.sample(b, lambda s: math.dist(s["vehicle"], origin) > 0.2)
        self.sample(a, lambda s: s["walk"] == 0)
        self.use(a, "Vehicle/BasicInteraction")
        self.sample(b, lambda s: not s["driver"])

        stage("slot")
        self.use(a, "CarryBox/CarryableComponent", action="interact2")
        self.order(a, op="walk")
        for role in (a, b, self.server):
            self.sample(role, lambda s: s["slot_id"] == "physics:box")
        self.sample(a, lambda s: not s["carrying"] and s["walk"] == 0)
        for role, start in starts.items():
            end = role.samples[-1]
            if "rx" in end and role is not self.server:
                rate = (end["rx"] - start["rx"]) * 60 / (end["tick"] - start["tick"])
                print(f"MP4 {role.directory.name} received {rate:.0f} payload bytes/s", flush=True)

    def inventories(self, a, b, first, second):
        def items(role, name):
            return role.samples[-1]["inventories"][name]["items"]

        self.sample(a, lambda s: not s["cutscene"])
        self.order(self.server, op="inventory_stage", place="start", first=first)
        self.sample(a, lambda s: s["inventories"][first]["items"].get("Battery") == 1)
        for role in (a, b):
            self.order(role, op="prepare_pickup")
        for role in (a, b):
            self.order(role, op="race")
        replies = [json.loads(self.wait_line(role, lambda line: line.startswith("NET RESULT "))
                              .removeprefix("NET RESULT ")) for role in (a, b)]
        if sum(reply["ok"] for reply in replies) != 1:
            raise CheckFailed(f"pickup race did not have one winner: {replies}")
        for role in (a, b, self.server):
            self.sample(role, lambda s: not s["loose"])
        for role, name in [(a, first), (b, second)]:
            if items(role, name) != items(self.server, name):
                raise CheckFailed("pickup race owner disagrees with server")
        if sum(items(self.server, name).get("Lockpick", 0) for name in (first, second)) != 1:
            raise CheckFailed("pickup race did not conserve the stack")

        self.order(a, op="inventory", action="drop", item="Battery")
        for role in (b, self.server):
            self.sample(role, lambda s: s["drop"])
        self.sample(self.server, lambda s: s["settled"])
        self.order(self.server, op="inventory_stage", place="drop", first=first)
        self.order(b, op="collect_drop")
        result = self.wait_line(b, lambda line: line.startswith("NET RESULT "))
        if not json.loads(result.removeprefix("NET RESULT "))["ok"]:
            raise CheckFailed(f"runtime pickup failed: {result}")
        for role in (b, self.server):
            self.sample(role, lambda s: not s["drop"] and
                        s["inventories"][second]["items"].get("Battery") == 1)
        self.sample(a, lambda s: "Battery" not in s["inventories"][first]["items"])
        self.order(self.server, op="inventory_stage", place="box", first=first)
        for role in (a, b):
            self.use(role, "SharedBox/BasicInteraction")
        self.order(a, op="inventory", action="put", item="Key")
        for role in (b, self.server):
            self.sample(role, lambda s: s["box"] == {"Key": 1})
        self.order(b, op="inventory", action="take", item="Key")
        for role in (a, b, self.server):
            self.sample(role, lambda s: s["box"] == {})
        if items(b, second).get("Key") != 1 or "Key" in items(a, first):
            raise CheckFailed("shared container did not transfer the key")
        for role in (a, b):
            self.order(role, op="close_box")

        self.order(self.server, op="inventory_stage", place="vendor", first=first)
        self.use(a, "Vendor/GenericButton/BasicInteraction")
        for role in (a, self.server):
            self.sample(role, lambda s: s["stock"] == 2 and
                        s["inventories"][first]["wallet"] == 15 and
                        s["inventories"][first]["items"].get("Health Potion") == 1)
        return a.samples[-1]["inventories"][first]

    def combat(self, a, b, first, second):
        def equip(role, owner, name, asset):
            self.order(role, op="inventory", action="use", item=name)
            for viewer in (a, b, self.server):
                self.sample(viewer, lambda s: s["wield"][owner][0] == f"Cogito_{asset}.tres")

        self.order(self.server, op="combat_stage", first=first)
        for role, owner in ((a, first), (b, second)):
            self.sample(role, lambda s: s["ammo"].get(owner) == 2)
        equip(a, first, "Laser Rifle", "LaserRifle")
        self.order(a, op="fire", ticks=24)
        self.sample(self.server, lambda s: s["west"] == 98 and s["ammo"][first] == 0)
        self.sample(a, lambda s: s["ammo"][first] == 0)
        observed = self.sample(b, lambda s: s["shots"] == 2)
        if observed["ammo"] != {second: 2}:
            raise CheckFailed(f"observer received another inventory: {observed['ammo']}")
        if self.server is a:
            equip(b, second, "Laser Rifle", "LaserRifle")
            self.order(b, op="fire", ticks=1)
            self.sample(self.server, lambda s: s["east"] == 99 and s["ammo"][second] == 1)
            self.sample(b, lambda s: s["ammo"][second] == 1)
        equip(a, first, "Dart", "Dart")
        self.order(a, op="fire", ticks=1)
        self.sample(b, lambda s: s["flights"] == 1 and s["impacts"] == 1 and s["dart"])
        self.sample(self.server, lambda s: s["west"] == 97)
        self.order(self.server, op="near_dart", who=second)
        self.order(b, op="take_dart")
        self.sample(b, lambda s: not s["dart"] and s["inventories"][second]["items"].get("Dart") == 1)
        equip(a, first, "Flashlight", "Flashlight")
        self.order(a, op="fire", ticks=1)
        self.sample(b, lambda s: s["wield"][first][1])
        return self.sample(a, lambda s: s["wield"][first][1])["inventories"][first]

    def hazards(self, a, b, first, second):
        names = (first, second)
        initial = self.pose(self.server, names)["vitals"]
        self.order(self.server, op="survival", place="hazard", first=first)
        self.sample(self.server, lambda s: all(
            s["vitals"][n]["health"] < initial[n]["health"] - 1.5 for n in names))
        self.order(self.server, op="survival", place="clear", first=first)
        tick = self.server.samples[-1]["tick"]
        health = self.pose(self.server, names, tick + 12)["vitals"]
        for owner, name in ((a, first), (b, second)):
            self.sample(owner, lambda s: abs(s["vitals"][name]["health"] - health[name]["health"]) < 1e-6)

    def duel(self, a, b, first, second, friendly_fire=True):
        self.order(self.server, op="survival", place="duel", first=first)
        self.sample(b, lambda s: s["vitals"][second]["health"] == 2)
        self.sample(a, lambda s: s["ammo"].get(first) == 100)
        if a.samples[-1]["wield"][first][0] != "Cogito_LaserRifle.tres":
            for _ in range(3):
                a.events = deque(line for line in a.events if not line.startswith("NET INVENTORY "))
                self.order(a, op="inventory", action="use", item="Laser Rifle")
                line = self.wait_line(a, lambda event: event.startswith("NET INVENTORY "))
                reply = json.loads(line.removeprefix("NET INVENTORY "))
                if reply["ok"]:
                    break
                if reply["reason"] != "Stale revision":
                    raise CheckFailed(f"duel equip failed: {reply}")
            else:
                raise CheckFailed("duel equip did not obtain a current inventory revision")
        self.sample(a, lambda s: s["wield"][first][0] == "Cogito_LaserRifle.tres")
        holdings = b.samples[-1]["inventories"][second]
        self.order(a, op="fire", ticks=35)
        self.sample(self.server, lambda s: s["ammo"][first] <= 97)
        if not friendly_fire:
            if self.server.samples[-1]["vitals"][second]["health"] != 2:
                raise CheckFailed("friendly_fire=false allowed player damage")
            return
        dead = self.sample(b, lambda s: s["death_screen"] and s["vitals"][second]["dead"])
        if dead["paused"] or dead["can_respawn"]:
            raise CheckFailed("private death screen paused the world or unlocked early")
        self.order(b, op="respawn")
        self.sample(b, lambda s: s["respawn_error"] == "Respawn delay")
        self.order(b, op="escape")
        self.sample(b, lambda s: s["menu"] and not s["paused"])
        self.order(b, op="escape")
        self.sample(b, lambda s: not s["menu"] and s["death_screen"])
        observer = self.sample(a, lambda s: s["vitals"][second]["dead"])
        if observer["death_screen"]:
            raise CheckFailed("surviving player received the death screen")
        origin = observer["actors"][first]
        self.order(a, op="walk")
        self.sample(self.server, lambda s: math.dist(s["actors"][first], origin) > 0.5)
        self.sample(b, lambda s: s["can_respawn"])
        self.order(b, op="respawn_button")
        for role in (a, b, self.server):
            self.sample(role, lambda s: not s["vitals"][second]["dead"] and not s["death_screen"]
                        and s["vitals"][second]["fraction"] == 1
                        and math.dist(s["actors"][second], [12, 0.91, 6]) < 0.3)
        if b.samples[-1]["inventories"][second] != holdings:
            raise CheckFailed("respawn changed the victim's inventory or wallet")

    def survival(self, listen=False):
        self.start(dedicated=not listen)
        first = "Host" if listen else "Ada"
        a = self.server if listen else self.fixture(first, "client")
        self.state(a, [first])
        b = self.fixture("Ben", "client")
        self.state(b, [first, "Ben"])
        for role in (a, b, self.server):
            self.pose(role, [first, "Ben"])
        self.hazards(a, b, first, "Ben")
        self.duel(a, b, first, "Ben")
        if listen:
            self.duel(b, a, "Ben", first)
        else:
            c = self.fixture("Cy", "client")
            state = self.pose(c, [first, "Ben", "Cy"])
            if state["vitals"]["Ben"]["dead"] or math.dist(state["actors"]["Ben"], [12, 0.91, 6]) > 0.3:
                raise CheckFailed("late joiner missed the respawn")
        print("PASS survival", "listen" if listen else "dedicated")

    def npc_dedicated(self):
        self.npc(listen=False)

    def npc_listen(self):
        self.npc(listen=True)

    @staticmethod
    def npc_bandwidth(role, start, end):
        if "rx" in start and "rx" in end:
            rate = (end["rx"] - start["rx"]) * 60 / (end["tick"] - start["tick"])
            print(f"NPC {role.directory.name} received {rate:.0f} B/s (all game traffic)")

    def npc(self, listen):
        self.start(dedicated=not listen, friendly_fire=False)
        first = "Host" if listen else "Ada"
        a = self.server if listen else self.fixture(first, "client")
        self.state(a, [first])
        b = self.fixture("Ben", "client")
        self.state(b, [first, "Ben"])
        viewers = [b] if listen else [a, b]
        starts = [(v, self.pose(v, [first, "Ben"])) for v in viewers]

        self.order(self.server, op="npc_stage", place="split", first=first)
        self.sample(b, lambda s: s["npc_target"] == "Ben" and s["indicator"])
        self.sample(a, lambda s: s["npc_target"] == "Ben" and not s["indicator"])
        self.sample(self.server, lambda s: s["vitals"]["Ben"]["dead"])
        for v in viewers:
            self.sample(v, lambda s: s["npc_shots"] == 2)
        self.sample(self.server, lambda s: not s["npc_target"] and s["npc_behaviour"] == 7)
        self.order(self.server, op="npc_stage", place="reveal", first=first)
        self.sample(a, lambda s: s["npc_target"] == first and s["npc_shots"] >= 3)
        self.order(self.server, op="npc_stage", place="aim", first=first)
        self.sample(a, lambda s: s["wield"][first][0] == "Cogito_LaserRifle.tres")
        self.order(a, op="fire", ticks=30)
        settled = self.sample(self.server, lambda s: s["npc_dead"] and s["corpse_rest"])
        for v, start in starts:
            end = self.sample(v, lambda s: s["npc_deaths"] == 1 and s["npc_loot"] == 1
                              and s["corpse"] and math.dist(s["corpse"], settled["corpse"]) < 0.04)
            self.npc_bandwidth(v, start, end)
        expected = 102 - settled["vitals"][first]["health"]
        for v in viewers:
            if v.samples[-1]["npc_shots"] != expected:
                raise CheckFailed(f"shots {v.samples[-1]['npc_shots']} vs MP5 damage {expected}")
        if settled["npc_deaths"] != 1 or settled["npc_loot"] != 1:
            raise CheckFailed("duplicate or missing authoritative death/drop")
        if not listen:
            late = self.fixture("Cy", "client")
            self.state(late, [first, "Ben", "Cy"])
            baseline = self.sample(late, lambda s: s["npc_dead"] and s["npc_loot"] == 1
                                   and s["corpse"] and math.dist(s["corpse"], settled["corpse"]) < 0.04)
            if baseline["npc_deaths"] or baseline["npc_shots"] or baseline["indicator"]:
                raise CheckFailed("NPC baseline replayed live effects")
        self.order(self.server, op="npc_stage", place="drag", first=first)
        self.order(a, op="drag_corpse")
        self.sample(a, lambda s: s["carrying"])
        self.sample(b, lambda s: math.dist(s["corpse"], settled["corpse"]) > 0.25)
        if not listen:
            dragged = self.sample(late, lambda s: s["tick"] > baseline["tick"]
                                  and math.dist(s["corpse"], settled["corpse"]) > 0.25)
            self.npc_bandwidth(late, baseline, dragged)
        print("PASS authoritative NPC", "listen" if listen else "dedicated")

    def elements(self, a, b, first, cold=False):
        viewers = [b] if cold else [a, b]
        starts = [self.pose(v, [first, "Ben" if not cold else "Ada"]) for v in viewers]
        self.order(self.server, op="element_stage", place="cold" if cold else "fire", first=first)
        if cold:
            switch = "ColdStand/Console/FreezerSwitch/BasicInteraction"
            self.use(a, switch)
            self.sample(b, lambda s: s["vitals"]["Ada"]["locked"])
            frozen = self.sample(self.server, lambda s: s["vitals"]["Ada"]["locked"])
            self.order(b, op="walk")
            self.sample(b, lambda s: s["walk"] == 0 and s["vitals"]["Ada"]["locked"])
            held = self.pose(self.server, [first, "Ada"])
            if math.dist(held["actors"]["Ada"], frozen["actors"]["Ada"]) > 0.12:
                raise CheckFailed("frozen client moved while holding forward")
            self.use(a, switch)
            self.sample(b, lambda s: not s["vitals"]["Ada"]["locked"])
            self.order(b, op="walk")
            self.sample(b, lambda s: math.dist(s["actors"]["Ada"], held["actors"]["Ada"]) > 0.4)
        else:
            self.use(a, "FireStand/Console/CampfireSwitch/BasicInteraction")
            for viewer in viewers:
                self.sample(viewer, lambda s: s["flames"] and s["grass_burning"])
            self.sample(b, lambda s: s["vitals"]["Ben"]["health"] < 100)
            for viewer in [self.server, *viewers]:
                self.sample(viewer, lambda s: s["grass_removed"] and s["burn_removals"] == 1)
            late = self.fixture("Cy", "client")
            self.state(late, [first, "Ben", "Cy"])
            baseline = self.sample(late, lambda s: s["epoch"] and s["flames"] and s["grass_removed"])
            sample = self.sample(late, lambda s: s["tick"] >= baseline["tick"] + 60)
            if "rx" in baseline:
                rate = (sample["rx"] - baseline["rx"]) * 60 / (sample["tick"] - baseline["tick"])
                print(f"MP7 late Cy: {baseline['rx']} bytes through baseline, then {rate:.0f} B/s")
            self.stop(late)
        for viewer, start in zip(viewers, starts):
            end = viewer.samples[-1]
            if "rx" in end:
                rate = (end["rx"] - start["rx"]) * 60 / (end["tick"] - start["tick"])
                print(f"MP7 {viewer.directory.name} received {rate:.0f} B/s (all game traffic)")

    def friendly_fire_off(self):
        self.start(dedicated=True, friendly_fire=False)
        a = self.fixture("Ada", "client")
        self.state(a, ["Ada"])
        b = self.fixture("Ben", "client")
        self.state(b, ["Ada", "Ben"])
        self.pose(a, ["Ada", "Ben"])
        self.pose(b, ["Ada", "Ben"])
        self.duel(a, b, "Ada", "Ben", friendly_fire=False)
        self.elements(a, b, "Ada")
        print("PASS dedicated friendly_fire=false: protected rifle target, fire damage, burnout, late join")

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
        self.sample(first, lambda s: s["shared_quest"] == 5 and s["quest_events"] == 2)
        self.sample(second, lambda s: s["shared_quest"] == 5 and s["quest_events"] == 4)
        self.physics(first, second, "Ada", "Ben", roster)
        self.devices(first, second, "Ada", "Ben")
        self.inventories(first, second, "Ada", "Ben")
        holdings = self.combat(first, second, "Ada", "Ben")
        self.hazards(first, second, "Ada", "Ben")
        self.duel(first, second, "Ada", "Ben")
        self.order(first, op="inventory", action="use", item="Flashlight")
        self.order(first, op="fire", ticks=1)
        self.sample(second, lambda s: s["wield"]["Ada"] == ["Cogito_Flashlight.tres", True])
        late = self.fixture("Cy", "client")
        self.state(late, ["Ada", "Ben", "Cy"])
        self.state(first, ["Ada", "Ben", "Cy"])
        self.state(second, ["Ada", "Ben", "Cy"])
        baseline = self.sample(late, lambda s: s["epoch"] > 0)
        if baseline["shared_quest"] != 5 or baseline["quest_events"] or baseline["personal_quest"]:
            raise CheckFailed("late join did not restore only the shared journal silently")
        if (not baseline["open"] or not baseline["keydoor_open"] or baseline["locked"]
                or baseline["keydoor_locked"] or baseline["events"] or not baseline["wheel_open"]
                or not baseline["picked"] or not baseline["cut_used"] or baseline["cutscene_starts"]):
            raise CheckFailed(f"incorrect late-join world baseline: {baseline}")
        if (baseline["wield"]["Ada"] != ["Cogito_Flashlight.tres", True]
                or baseline["flights"] or baseline["shots"] or baseline["impacts"]):
            raise CheckFailed(f"incorrect combat baseline: {baseline}")
        expected = self.server.samples[-1]["vitals"]["Ada"]["fraction"]
        if (baseline["vitals"]["Ada"]["fraction"] != expected or baseline["vitals"]["Ben"]["dead"]
                or math.dist(baseline["actors"]["Ben"], [12, 0.91, 6]) > 0.3):
            raise CheckFailed("incorrect late-join survival baseline")
        if baseline["slot_id"] != "physics:box":
            raise CheckFailed("missing snapped crate on late join")
        self.sample(late, lambda s: math.dist(s["crate"], self.server.samples[-1]["crate"]) < 0.035)
        if baseline["loose"] or baseline["drop"]:
            raise CheckFailed("picked objects appeared on late join")
        self.order(self.server, op="inventory_stage", place="box", first="Cy")
        self.use(late, "SharedBox/BasicInteraction")
        self.sample(late, lambda s: s["box"] == {})
        self.order(late, op="close_box")
        self.stop(late)
        self.state(first, roster)
        self.state(second, roster)
        self.expect_rejection("old", "Content version mismatch", extra=("--content", "wrong"))
        # A second login with Ada's key takes over the live session (crashed-client rejoin).
        first.expected_failure = "Signed in from another session"
        taken = self.fixture("Ada", "client", copy_from=first)
        self.wait_line(first, lambda line: line.startswith("NET FAILED "))
        if self.state(taken, roster) != (ada, roster):
            raise CheckFailed("session takeover changed identity")
        self.state(second, ["Ben"])
        self.state(second, roster)
        self.stop(first)
        self.stop(taken)
        self.state(second, ["Ben"])
        self.pose(self.server, ["Ben"])
        self.pose(second, ["Ben"])
        again = self.fixture("Ada", "client", copy_from=taken)
        if self.state(again, roster) != (ada, roster) or self.state(second, roster) != (ben, roster):
            raise CheckFailed("client restart changed identities")
        self.sample(again, lambda s: s["inventory_ready"] and s["inventories"].get("Ada") == holdings)
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
        print("PASS dedicated + 2 clients: carry race, throw, seats, driving, snap, movement, collision, interaction retry, keypad, turnwheel, lockpick, private cutscene, pickup race, drops, container, purchase, rifle, dart recovery, flashlight, late join, session takeover, inventory reconnect, restart")

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
        self.sample(client, lambda s: s["personal_quest"] and s["quest_events"] == 4)
        self.sample(self.server, lambda s: not s["personal_quest"] and s["quest_events"] == 2)
        self.physics(self.server, client, "Host", "Ada", roster)
        self.devices(self.server, client, "Host", "Ada")
        self.inventories(self.server, client, "Host", "Ada")
        self.combat(self.server, client, "Host", "Ada")
        self.hazards(self.server, client, "Host", "Ada")
        self.duel(self.server, client, "Host", "Ada")
        self.duel(client, self.server, "Ada", "Host")
        self.elements(self.server, client, "Host", cold=True)
        self.stop(client)
        self.state(self.server, ["Host"])
        self.pose(self.server, ["Host"])
        self.stop(self.server)
        print("PASS listen host + 1 client: bidirectional carry, throw, seats, driving, snap, movement, interactions in both directions, turnwheel, lockpick, private cutscene, container trade, purchase, bidirectional shots, dart recovery, flashlight, host identity, freeze, thaw and departure")


    def persistent_dedicated(self):
        self.persistence(True)

    def persistent_listen(self):
        self.persistence(False)

    def persistence(self, dedicated):
        world = "restart"
        self.start(dedicated, world=world, autosave=2)
        original_server = self.server
        first_name = "Ada" if dedicated else "Host"
        first = self.fixture("Ada", "client") if dedicated else self.server
        self.state(first, [first_name])
        second = self.fixture("Ben", "client")
        names = [first_name, "Ben"]
        _, roster = self.state(second, names)
        self.state(first, names)
        for role in (first, second):
            self.sample(role, lambda s: s["epoch"] > 0)
        world_dir = self.directory / "world" / "worlds" / world
        if dedicated:
            (world_dir / "save.request").touch()
            self.wait_line(self.server, lambda line: line.startswith("NET SAVE OK generation="))
        else:
            self.order(self.server, op="save_world")
            self.wait_line(self.server, lambda line: line == "NET MANUAL World saved")
        self.order(self.server, op="inventory_stage", place="start", first=first_name)
        self.use(second, "LooseItem/PickupComponent")
        self.order(self.server, op="stage", first=first_name)
        self.use(first, "Door/Use")
        self.stationary(self.server, names)
        saved = self.order(self.server, op="wallet", who="Ben", value=43)
        self.sample(self.server, lambda s: s["generation"] > saved["generation"])
        (world_dir / "list.request").touch()
        self.wait_line(self.server, lambda line: line == "NET LIST OK count=2")
        for _ in names:
            line = self.wait_line(self.server, lambda line: line.startswith("NET PROFILE "))
            row = json.loads(line.removeprefix("NET PROFILE "))
            name = row["display_name"]
            if (row["player_id"] != roster[name] or row["last_level"] != "arena" or row["dead"]
                    or row["last_seen"] <= 0
                    or row["item_count"] != sum(saved["inventories"][name]["items"].values())):
                raise CheckFailed(f"wrong live profile listing: {row}")
        if dedicated:
            # Deliberately kill inside the NEXT transaction. Both identities are still live.
            self.order(self.server, op="interrupt_save", who="Ben", value=44)
            self.wait_line(self.server, lambda line: line == "NET STAGING")
            self.server.kill()
            first.kill()
            second.kill()
        else:
            self.stop(second)
            self.pose(self.server, [first_name])
            self.server.stopping = True
            self.order(self.server, op="quit_host", value=51)
            saved["inventories"][first_name]["wallet"] = 51
        while not self.server.exited:
            self.next_line()
        self.start(dedicated, restart=True, world=world,
                   host_identity=None if dedicated else original_server)
        owner = self.fixture("Ada", "client", first) if dedicated else self.server
        _, single = self.state(owner, [first_name])
        if single[first_name] != roster[first_name]:
            raise CheckFailed("first restored identity changed")
        self.sample(owner, lambda s: s["inventory_ready"] and s["epoch"] > 0)
        later = self.fixture("Ben", "client", second)
        if self.state(later, names)[1] != roster:
            raise CheckFailed("second restored identity changed")
        remote_names = names if dedicated else ["Ben"]
        for name in remote_names:
            if later.peer_ids[name] == second.peer_ids[name]:
                raise CheckFailed(f"{name}: expected a fresh peer ID after restart")
        for role, name in ((owner, first_name), (later, "Ben")):
            result = self.sample(role, lambda s: s["inventory_ready"] and len(s["actors"]) == 2
                                 and s["open"] and not s["loose"])
            if (saved["inventories"][name] != result["inventories"][name]
                    or math.dist(result["actors"][name], saved["actors"][name]) > 0.15):
                raise CheckFailed(f"{name}: restart changed holdings or placement: "
                                  f"{saved['actors'][name]} -> {result['actors'][name]}")
        if dedicated:
            self.order(self.server, op="wallet", who="Ben", value=61)
            self.stop(later)
            self.pose(self.server, [first_name])
            self.server.stopping = True
            owner.expected_failure = "Server disconnected"
            (world_dir / "stop.request").touch()
            self.wait_line(self.server, lambda line: line == "NET STOP OK")
            owner.kill()
            while not self.server.exited:
                self.next_line()
            self.start(True, restart=True, world=world)
            returned = self.fixture("Ben", "client", second)
            self.state(returned, ["Ben"])
            self.sample(returned, lambda s: s["inventories"].get("Ben", {}).get("wallet") == 61)
            self.stop(returned)
            self.pose(self.server, [])
            (world_dir / "rebind.request").write_text(f"{roster['Ben']} {roster[first_name]} force")
            self.wait_line(self.server, lambda line: line.startswith("NET REBIND OK "))
            moved = self.fixture("Ada", "client", first)
            self.state(moved, ["Ada"])
            self.sample(moved, lambda s: s["inventories"].get("Ada", {}).get("wallet") == 61)
            self.stop(moved)
            self.order(self.server, op="fail_final_write")
            self.server.expected_exit = 1
            self.server.stopping = True
            (world_dir / "stop.request").touch()
            self.wait_line(self.server, lambda line: line.startswith("NET FINAL SAVE "))
            while not self.server.exited:
                self.next_line()
        print("PASS world restart and offline profile", "dedicated" if dedicated else "listen")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    scenarios = ("dedicated", "listen", "friendly_fire_off", "npc_dedicated", "npc_listen",
                 "persistent_dedicated", "persistent_listen")
    parser.add_argument("--scenario", choices=scenarios)
    parser.add_argument("--file-transport", action="store_true", help="use a socket-free packet bus")
    parser.add_argument("--survival-only", action="store_true", help="run only MP5 scenarios")
    args = parser.parse_args()
    for name in ([args.scenario] if args.scenario else scenarios[:3] if args.survival_only else scenarios):
        started = time.monotonic()
        with tempfile.TemporaryDirectory(prefix=f"cogito-{name}-") as directory:
            scenario = Scenario(Path(directory), args.file_transport)
            try:
                if args.survival_only and name != "friendly_fire_off":
                    scenario.survival(listen=name == "listen")
                else:
                    getattr(scenario, name)()
            except (OSError, ValueError, KeyError, CheckFailed) as exc:
                print(f"FAIL {name}: {exc}", file=sys.stderr)
                for role in scenario.roles:
                    print(f"[{role.directory.name}]", *role.tail, sep="\n", file=sys.stderr)
                return 1
            finally:
                print(f"{name}: {time.monotonic() - started:.2f} s", flush=True)
                for role in reversed(scenario.roles):
                    role.kill()
    return 0


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
