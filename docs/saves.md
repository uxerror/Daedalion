# Saves and scene persistence

Named saves live under `user://saves/` in Daedalion's project data directory. A manual slot captures the player and the visited levels together. The configured autosave (normally `autosave`) is separate. It leaves your selected manual slot alone. The working directory `temp` carries state between levels in the current playthrough.

Game code still calls the [scene manager autoload](../addons/cogito/SceneManagement/cogito_scene_manager.gd). Its [slot storage](../addons/cogito/SceneManagement/cogito_slot_storage.gd), [save index](../addons/cogito/SceneManagement/cogito_save_index.gd) and [transition logic](../addons/cogito/SceneManagement/cogito_scene_transitions.gd) now live in separate helpers.

## Start, save and restart

- **New Game** calls `CogitoSceneManager.start_new_game()`. It clears working state and restores the configured starting world, quests and starter items. Named saves and manual history stay available.
- **Save** builds and validates a complete slot in staging before publishing it. **Load** checks the player state and destination level before replacing the current scene or working files. A broken slot shows a reason in the slot menu. A missing screenshot uses the placeholder.
- **Transitions** save the outgoing scene. A busy guard returns `ERR_BUSY` for overlapping saves or loads. It covers the fade, level restore and connector placement. A level with `save_temp_on_enter` takes its working snapshot after placement.
- **Reload after death** chooses the newest loadable manual save or autosave by player timestamp, including slots missing from history. The search skips broken and working slots. With no loadable slot it starts fresh at the current level entry, or at the configured first level if there is no level path.

## What survives a load

| Owner | Examples of saved state |
| --- | --- |
| Player | Position and controller state, attributes and currencies, inventory stacks and quickslot indices, equipped item, its magazine and ammo selection, quest objectives and world flags. |
| Objects | Each saveable object's data, including its transform and references. Rigid bodies also restore linear and angular velocity. Containers can retain their inventories. |
| NPCs | Behaviour state, patrol and attention references, health and elements. Retained dead NPCs stay dead. A persistent ragdoll can restore its bone pose. Suspicion and perception timers start fresh. |
| Components | Health on static interactables, destroyed children, elemental buildup and actor timers. Attribute restore refreshes displays without replaying damage, death or loot. |

## Edit a level that players have already visited

The [level root script](../addons/cogito/SceneManagement/cogito_scene.gd) records authored saveable nodes in the `Persist` group at startup. For an object that should persist, use the group's exact case and implement `save()` as in [cogito_object.gd](../addons/cogito/CogitoObjects/cogito_object.gd). A runtime spawn also needs a saved prefab and parent so the loader can recreate it.

Authored IDs default to `level:` followed by the path from the level root. On load, matching objects receive their saved state in place. An object known to the old level but absent from the snapshot stays gone. An object newly added to the level starts with its authored defaults. A runtime object gets a generated ID.

When moving or renaming a crate, add String metadata `cogito_persistent_id` to the node and give it its original ID, for example `level:Storage/Crate`. Keep IDs unique. Otherwise the moved crate can appear alongside a respawned copy of the saved one. Keep component paths within the object stable and retain the level root name, which keys the level file. Older snapshots without the authored ID list use older removal rules.

New saves use data-only v2 JSON. A compatible legacy binary state is read when its v2 file is absent and converted on the next successful save. Saves from the retired player controller appear as broken slots. See [file format and compatibility rules](save-format.md) and [migration from 1.2](migration-1.2-to-1.3.md).

## Multiplayer saves

The listen host's **Save** button and the dedicated server's `save.request` publish one
world generation, including offline players. Start the same named world to resume it.
An explicit solo import copies a slot to a new world and designates one profile as its
owner. See [multiplayer world saves and import](networking.md#save-and-reopen-a-world).
