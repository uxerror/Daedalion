# Dedicated server on Linux

The server starts its world and simulates it with zero connected players. Use the
same Daedalion content and protocol on clients and server. The supplied preset
targets Linux x86-64.

## Build and check

Install Godot 4.7.2 and its matching Linux release export template using the
editor's **Manage Export Templates** dialog. In the project directory, run

```sh
nice -n 19 godot --headless --path . --import
tools/export_dedicated.sh "$PWD/build/daedalion-server"
tools/check_dedicated_export.sh
```

Keep the executable and the adjoining `daedalion-server.pck` together. The smoke
test uses a temporary config, an empty world and a normal headless client. It
prints SKIP if the matching release template is missing. To build in the editor,
choose **Project → Export → Linux dedicated server → Export Project**.

The dedicated preset strips visual resources and selects the simulation main
scene via the engine's `dedicated_server` feature. Scene customization removes
authored audio players, cameras and the Advanced HUD and retains its aim transform,
casts and quickslot configuration. Weapon definitions carry their exported
simulation settings and animation timings, so equipping an item takes no
first-person scene instance. Physics rooms have separate non-rendering
viewports. Skeletons, animations, collision shapes, navigation and gameplay
scripts still run. Games adding scene types can extend the scene customization
in `addons/cogito/Networking/dedicated_export.gd`.

Release builds buffer stdout by default, so status lines such as `NET READY` would
reach a log file or the journal late. `project.godot` therefore sets
`application/run/flush_stdout_on_print.dedicated_server=true`. Keep that override
in a game's own project settings.

## Install on Debian

From the project root on a Debian test host with systemd, install the files and
create the service account once.

```sh
sudo useradd --system --user-group --home-dir /var/lib/daedalion --shell /usr/sbin/nologin daedalion
sudo install -d -m 0755 /opt/daedalion
sudo install -m 0755 build/daedalion-server /opt/daedalion/
sudo install -m 0644 build/daedalion-server.pck server/server.cfg /opt/daedalion/
sudo install -m 0755 server/daedalion-server-ctl /usr/local/bin/
sudo install -m 0644 server/daedalion-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now daedalion-server
sudo journalctl -u daedalion-server -f
```

Expect `NET BOOT dedicated_server=true` and `NET READY port=7777`. The unit
runs in `/opt/daedalion` and systemd creates `/var/lib/daedalion` for its state.
For a foreground run, use `nice -n 19 /opt/daedalion/daedalion-server --headless`.

## Config and reachability

Fixed-tick movement is enabled on dedicated and listen servers. To use chart-driven
movement, set `COGITO_AUTHORITY_MOVEMENT=0` in the server process environment. For the
systemd unit, add `Environment=COGITO_AUTHORITY_MOVEMENT=0` under `[Service]` in an
override and restart the service. All clients then follow authoritative movement.
Owners can also opt out individually with `COGITO_OWNER_PREDICTION=0` on their client.
Omitting either variable or setting it to `1` selects the enabled default.

The binary reads `server.cfg` beside the executable. An explicit
`-- --config /path/to/server.cfg` selects another file. CLI flags after `--`
override the file. The sample documents every key and default. The unit sets
`--save-dir /var/lib/daedalion --world default`. When changing either value, also
update its ExecStop path using a systemd drop-in. Restart to apply settings.

The default bind address accepts loopback clients. For LAN play, set `bind` to
the host's LAN interface IP or `"*"`. Allow inbound **UDP** on the configured
port. For example, on a host using UFW, adapt the subnet before running
`sudo ufw allow from 192.168.1.0/24 to any port 7777 proto udp`. For direct
internet access, forward that UDP port at the router as well. Players enter the
reachable address and port in **Multiplayer → Join**. Set `max_players` to a
capacity tested on your server hardware. [Configuration reference](networking.md#dedicated-server)

## World files and backups

```text
/var/lib/daedalion/
  identities.cfg
  worlds/default/
    writer-<pid>-<token>.lock
    current/
      world.v2.json
      scene_*.v2.json
      player_*.v2.json
```

The manifest gives the generation, active room, shared state and checksums of
the room and player records. Recovery can also use the previous or staged-ready
generation. Each operator request belongs alongside `current/`. Limit access
to the service account and administrators. The verifier registry belongs with
the worlds it authenticates. Players keep their own key files on their machines.
[World format](save-format.md#multiplayer-world-generations)

For a consistent backup, use `sudo systemctl stop daedalion-server`, wait for
`NET STOP OK`, copy the entire world directory and `identities.cfg`, then restart.
For an online backup, request a save, wait for `NET SAVE OK generation=N` and
take a filesystem snapshot while that complete generation is current. If copying
files on a live filesystem, verify the generation and member hashes afterwards
or repeat the copy while stopped. Restore backups with the service stopped.

## Operate a running world

```sh
world=/var/lib/daedalion/worlds/default
sudo -u daedalion daedalion-server-ctl "$world" save
sudo -u daedalion daedalion-server-ctl "$world" list
sudo -u daedalion daedalion-server-ctl "$world" kick "Player name"
sudo -u daedalion daedalion-server-ctl "$world" rebind OLD_ID NEW_ID
sudo -u daedalion daedalion-server-ctl "$world" stop
sudo journalctl -u daedalion-server --since '5 minutes ago'
```

The helper atomically publishes one request per filename and reports queueing.
The server polls about once per second and writes results to stdout/stderr.
`list` prints saved profile rows and a `NET CONNECTED` JSON row per live player
including their ID, current level and RTT. Use a player ID for duplicate names.
A successful kick removes the peer immediately and allows reconnect. An unknown
name or ID returns `NET KICK Does not exist`.

If a player loses their key, have them join once to enroll a new ID, then
disconnect. Rebind their old profile to that ID with both identities offline.
Replacing a target with progress requires the additional literal argument
`force`. The move affects that world's private profile. The dedicated CLI can
also execute `--profile-command 'list'` or `'rebind OLD_ID NEW_ID'` against a
stopped world. [Profile recovery](networking.md#list-and-rebind-profiles)

For service management, `sudo systemctl stop daedalion-server` creates
`stop.request` and waits for process exit. The final flush has a three-second
budget. The unit allows 15 seconds for polling, flush and exit. Godot headless
on Linux can exit on SIGTERM without running the flush. Check the journal for
`NET STOP OK` before a restart or upgrade.

## Upgrades and troubleshooting

- Stop, back up, replace both the binary and PCK, then start. Retain the service
  user's state and config. Update clients together. The default content version
  follows the bundled Cogito plugin version. Games overriding it must pass the
  same content version to their clients. A custom content version marks a build
  for admission. Test save migration separately on a copied world. Never
  overwrite the PCK of a running server and then restart: `install` and `cp`
  rewrite the file in place, the old process reads scenes from the new pack
  during its final save, and that save fails with `File corrupt`.
- **Cannot bind** means another process owns the port or the interface is
  unavailable. Check `ss -lunp`, the bind address and the unit's journal.
- **World is locked** means another writer has a claim. Stop it and wait for
  exit. Inspect the PID before removing a stale claim manually. Keep world
  storage on a local filesystem in one PID namespace.
- **NET SAVE** or **NET STOP** errors warrant checking disk space, directory
  ownership and the last verified generation. Restore a backup if recovery
  finds no valid generation.
- **Version mismatch**, **server full** and **timeout** appear on the Join
  screen. Check build versions, capacity, destination IP and UDP reachability.
  **Kicked by host** appears on the client's main menu.
