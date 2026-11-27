# Level instances

Pass a node from the level when looking up game content. For example, a sensor can
use `CogitoLevel.nodes_in_group(self, &"Player")` to enumerate players in scene-tree
order. Use `first_node_in_group(self, group)` when you only need the first match.
In ordinary offline play both helpers return the native tree result directly.
With hosted levels, matching uses the nearest marked ancestor, including for nodes
under a nested viewport.

| Operation | Game code |
| --- | --- |
| Find this node's level root | `CogitoLevel.root_of(self)` |
| Spawn a projectile or drop | `CogitoLevel.spawn_parent(self).add_child(spawn)` |
| Play a positional one-shot | `CogitoAudio.play_sound_3d_in(self, stream, global_position)` |
| Resolve a saved ID, including a duplicate in another level | `CogitoPersistentId.find_in_level(self, id)` |
| Save or restore an instance | `CogitoSceneManager.save_scene_state(level_name, slot, root)` and `load_scene_state(level_name, slot, root)` |

Autoloads, menus, detached players and HUDs outside a hosted level resolve to the
registered offline root, then to the current scene. An autoload handling an event
from a hosted level should pass the emitter as context. During an offline transition
the incoming root can be registered before the current scene changes. Spawns keep
their historical offline parent. The projectile pin joint uses the root window
through `spawn_parent(self, true)`.

`CogitoLevelHost.load_level(path, key)` returns the root for that key. Each instance
owns a 2 × 2 SubViewport with a separate World3D, physics space and navigation map.
Rendering updates and audio listeners are disabled. `level(key)` and `levels()`
return live roots. `unload_level(key)` releases the key immediately and frees the
viewport and its children at the end of the frame. Online sessions also use the host for each live room.

A save keeps its existing level filename and IDs relative to the authored root.
Pass distinct level names when writing different instances into the same slot.
The two-argument save/load facade and `CogitoPersistentId.find(tree, id)` use the
offline level by default. See the [save format](save-format.md).

## Multiplayer levels

Use a `CogitoScene` root and give each doorway a `SceneTransitionZone`. Set its
`target_scene_path` and `target_connector` to a scene and an entry in that scene's
`connectors` array. Resource UID paths work for the demo doors. Give the arrival
marker clear standing space and leave room around it for simultaneous arrivals.
The optional `level_display_name` is a translation key used in travel hints.
The fallback is the authored scene filename without its extension.

The authority keeps one independent physics and navigation world per live level.
Only the local player's room has an active presentation surface on a listen host.
A remote client loads its assigned room on admission or travel. Use an actor, zone
or device as the context for level lookups. The server's starting scene can differ
from the actor's level, including after reconnect. Empty rooms stay resident for
`level_grace_seconds` (default 60) and then checkpoint through the world writer.

See [multiplayer travel, policy hooks and recovery](networking.md#independent-level-travel).
