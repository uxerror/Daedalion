# Multiplayer sessions

Daedalion 1.4 MP0 provides direct-address ENet sessions, persistent player identities and a shared roster. The demo still starts in single-player. MP1 will bind player actors to the roster. Movement, independent level instances and world replication come in later stages.

## Open a session

Connect to `CogitoNet.session_ready` and `CogitoNet.session_failed` **before** opening a session. A listen host or dedicated server can become ready during the opening call. A client becomes ready after the server admits it, its local identity is saved and its initial roster is available.

```gdscript
# Listen host on a LAN interface. Use the host machine's actual address.
var err := CogitoNet.host({
	"bind": "192.168.1.10",
	"port": 7777,
	"max_players": 4,
	"display_name": "Sam",
})
```

```gdscript
# On a different instance of the game
var err := CogitoNet.join("192.168.1.10", 7777, {"display_name": "Alex"})
```

Both calls return an immediate Godot `Error`. A client receiving `OK` can still fail asynchronously during connection or admission. Call `disconnect_session()` to leave or shut down. A lost server or rejected handshake also returns the client to offline mode.

| `mode()` | Authority | Local identity |
| --- | --- | --- |
| `Mode.OFFLINE` | Local | Empty. The singleton uses the engine's offline peer and adds no children, timers or frame callbacks. |
| `Mode.LISTEN_HOST` | Server | One admitted player on peer 1 |
| `Mode.CLIENT` | Remote server | Assigned on admission |
| `Mode.DEDICATED` | Server | Empty, including when clients are present |

Use `is_server()`, `is_online()` and `is_dedicated()` to query these roles. `is_online()` includes a client waiting for admission. `is_server()` is true in offline mode.

`players()` returns copies of admitted records with `player_id: String`, `peer_id: int` and `display_name: String`. `player_for_peer(peer_id)` and `player_for_id(player_id)` return a record or an empty dictionary. `local_player_id()` returns the local ID or an empty string. `local_player()` returns null throughout MP0. Use `player_joined(player_id)` and `player_left(player_id)` for roster changes. `peer_rejected(peer_id, reason)` runs on the server and `session_failed(reason)` reports a refusal to the client. Treat display names as labels. Connection IDs can change on every join.

## Dedicated server

From the project root, start a loopback server with a private world directory.

```sh
godot --headless --path . -- --server --bind 127.0.0.1 --port 7777 --max-players 8 --save-dir user://net/server
```

A successful boot writes `NET READY port=7777` to stdout. Invalid configuration or a bind failure exits with a nonzero status. A normal build recognizes `--server` after `--`. An export with the `dedicated_server` feature selects the same role automatically. You can also select the scene explicitly.

```sh
godot --headless --path . res://addons/cogito/Networking/dedicated_server.tscn -- --server --config server.cfg
```

Use a Godot ConfigFile with a `[server]` section. CLI options override file settings in any order. Programmatic hosts and `start_server(config)` take the same keys in a dictionary.

```ini
[server]
bind="127.0.0.1"
port=7777
max_players=8
save_dir="user://net/server"
content_version="my-game-1.0"
```

| Key | Default and meaning | CLI override |
| --- | --- | --- |
| `bind` | `127.0.0.1`. Supply a local interface IP for LAN access, or `*` for all interfaces. | `--bind` |
| `port` | UDP 7777, valid range 1–65535. | `--port` |
| `max_players` | ENet supports up to 4095 remote connections. Omitting the limit requests that ceiling. A listen host counts its local player, allowing up to 4096 total. | `--max-players` |
| `save_dir` | `user://net/server`. Give each server its own writable directory. | `--save-dir` |
| `content_version` | The `version` string from `addons/cogito/plugin.cfg`. Include the plugin config in an export or supply a game release or content hash. Set the same value in client join credentials. | Config file |
| `display_name` | `Host` for the listen player. Clients supply their own name in join credentials, default `Player`. | Config file |

The protocol version is a networking-code constant. Both protocol and content must match. Direct internet connections require the selected UDP port to reach the server. ENet support in MP0 covers native direct-address connections and LAN.

The dedicated scene runs without a player, camera or HUD. The default demo boot prevents the menu subtree from entering the tree. Dedicated startup skips solo save recovery and cleanup, the fade panel, game options, graphics and input-map setup by Cogito's menu autoload. The engine still loads project resources, Cogito settings and the existing autoload nodes, including InputHelper, DebugLine, InputRouter, audio and quest services. Full export stripping is scheduled for MP11.

## Identity and recovery

Each normalized address and port has its own profile in `user://net/identity.cfg`. The ConfigFile section name is the SHA-256 hex digest of the lowercase, trimmed address followed by a slash and the decimal port, for example `127.0.0.1/7777`. The listen host uses a separate profile keyed by its server save directory. Using a different hostname or port creates a different profile. All processes running a game should have exclusive use of their client data directory.

On first admission the client generates a random 96-byte secret. The server sends a fresh 32-byte nonce. The client returns an HMAC-SHA256 proof and, for enrollment only, a SHA-256 verifier. HMAC normalizes a key this long to its SHA-256 digest, allowing the server to check the proof with the stored verifier. The server issues a random 128-bit ID and persists the verifier in `<save_dir>/identities.cfg`. On reconnect the client presents its ID and answers a new challenge using only the proof. A second live connection claiming the same ID receives a rejection. An unknown ID starts a new enrollment with a fresh secret.

Keep the verifier registry private. A verifier is sufficient to produce proofs, and native ENet sends registration traffic without encryption. The default provider is intended for trusted networks. Back up both stores to retain identities. With the game stopped, removing the client profile (or the entire client file) starts a new identity on the next join. Removing the server registry resets every binding in that server directory. There is no account-recovery flow in MP0.

A game can assign a subclass of `addons/cogito/Networking/net_identity.gd` to `CogitoNet.identity_provider` before opening a session. Override `open_server`, `load_client`, `is_known`, `respond`, `authenticate` and `save_client` to implement enrollment, proof and persistence. Join credentials are available to `load_client`. Only the claimed ID, versions, response and display name travel over the control endpoint. A custom provider should put only wire-safe values in its response. The server always applies the capacity and single-login checks.

For a transport extension, assign a zero-argument `Callable` to `CogitoNet.transport_factory`. It returns an `enet_transport.gd` subclass implementing `open_server(config, listen)` and `open_client(address, port)` and exposing its resulting `MultiplayerPeer` through `peer`. The built-in adapter uses ENet. Session RPCs use reliable channel 0 at `/root/CogitoNet/Session`.

## Verification

`tools/check.sh multiplayer` runs two headless process scenarios over loopback after import. Each process gets a temporary user data directory. The harness copies a saved identity to simulate a client restart or duplicate login and reuses the server save directory for a server restart. Use `GODOT_BIN` to select the executable and `NICE` to override the local default of `nice -n 19`. The socket-free gdUnit tests under `tests/net/` also run with the regular test suite.
