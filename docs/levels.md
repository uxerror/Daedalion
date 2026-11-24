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
viewport and its children at the end of the frame. The host currently runs in integration tests.

A save keeps its existing level filename and IDs relative to the authored root.
Pass distinct level names when writing different instances into the same slot.
The two-argument save/load facade and `CogitoPersistentId.find(tree, id)` use the
offline level by default. See the [save format](save-format.md).
