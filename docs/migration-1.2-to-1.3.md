# Migrate a Cogito 1.2 project to Daedalion 1.3

## 1. Start with the release project

Keep a copy of your game and save directory. Open a fresh Daedalion working copy with Godot 4.7.2. Bring your scenes, scripts and assets into it. The two repositories have different commit histories. Preserve resource UIDs when moving assets and keep the old paths available where legacy binary saves depend on them. Check the input map, autoloads, physics layers and translations against [Getting started](getting-started.md).

## 2. Replace the player scene and save type

Replace instances of the retired `CogitoPlayerSimple` scene with [cogito_player_advanced.tscn](../addons/cogito/PackedScenes/cogito_player_advanced.tscn). Reapply your movement settings, child components and signal connections. Replace explicit type references to `CogitPlayerAdvancedState` with `CogitoPlayerAdvancedState`. The Advanced state script keeps its filename. Saves produced by the retired controller show “Cannot read player state.” in the slot menu, including legacy binary saves.

For a custom controller, extend `CogitoPlayer`, register it in its ready callback and implement `create_new_state()`. Your state subclass implements `populate_save_data(player, slot)` and `populate_player_data(player)`. Use `save_common_data()` and `load_common_data()` for shared inventory, attributes and world data. Assign a `CogitoHud` implementation to `player_hud`. Check [the player contract](player-controller.md) when replacing your HUD or controller.

## 3. Update player lookups

**Before (Cogito 1.2)**

```gdscript
func on_body_entered(body: Node3D) -> void:
    if body.is_in_group("Player"):
        print(body.name)
```

**After (Daedalion 1.3)**

```gdscript
func on_body_entered(body: Node3D) -> void:
    if body is CogitoPlayer:
        print(body.name)
```

Elsewhere, replace reads of `CogitoSceneManager._current_player_node` with `CogitoSceneManager.get_player()`. It returns null before registration or after the player has been freed. Advanced registers itself. In a custom controller's ready callback call `CogitoSceneManager.register_player(self)`.

## 4. Rewire targeting, carrying and equipment

Use the shipped [interaction component scene](../addons/cogito/Components/PlayerInteractionComponent.tscn) in a custom player, or add its InteractionTargeting, CarryHandler and WieldableHandler children with the matching scripts. Assign the raycast, carry position and wieldable references as on Advanced. Set the player's `player_interaction_component_path`, `body_path` and `head_path` to your nodes. The raycast in Advanced is under **Body/Neck/Head/Eyes/Camera/InteractionRaycast**.

**Before (Cogito 1.2)**

```gdscript
func held_item(player: CogitoPlayerAdvanced):
    return player.player_interaction_component.carried_object
```

**After (Daedalion 1.3)**

```gdscript
func held_item(player: CogitoPlayer):
    return player.player_interaction_component.carrying.carried_object
```

Use `targeting.interactable` for the current target and `wieldables.equipped_wieldable_item` for the equipped item. Existing forwarding members cover many old calls. Replace private interaction calls with `start_interaction()` for an input action or `perform_action()` for a listed component action. Route inventory drops through `player.drop_item(slot_data)` and handle a false return.

## 5. Update sound, damage and quests

Remove the old QuickAudio plugin and its autoload from your project. Enable Cogito for Godot to register `CogitoAudio`. Use `CogitoAudio.play_sound()` for a UI sound and `CogitoAudio.play_sound_3d()` for sound at a world position. Carry over the [bus layout](../default_bus_layout.tres) and assign music and combat states on your level root. For example, this receiver accepts both a short damage call and the full burn or projectile arguments.

```gdscript
@export var hit_sound: AudioStream

func on_damage_received(amount: float, _source = null,
        _direction := Vector3.ZERO, hit_position := Vector3.ZERO) -> void:
    if amount > 0.0:
        CogitoAudio.play_sound_3d(hit_sound, hit_position)
```

Port custom quests into the `quest_objectives` array. Assign each objective its ID, description and flag groups. Check reveal, completion and failure in order against your existing world or inventory flags. The [demo objectives](../addons/cogito/QuestSystem/Quests/DemoSceneObjectives) are working examples.

## 6. Reconnect quickslots

On your inventory HUD, keep containers in their saved index order, add each to `quickslot_containers` and set its `input_action`. Add missing actions and bindings to the Input Map. Register extra views in `views`. Follow [Quickslots](quickslots.md) for the inventory signal, rebinding entries and wheel controls. Remove custom branches added solely to handle extra numbered keys.

## 7. Transfer and exercise a save

Daedalion uses its own user data directory. From Godot's **Project > Open User Data Folder** in each project, copy the backed-up Cogito `saves/` directory, including slot directories and history, into the fresh Daedalion profile. Check the legacy filename prefixes in your settings. A loadable legacy Advanced slot converts to JSON on the next successful save. Keep the original until you have reloaded the new slot and revisited another level.

If a placed object moved in the editor, set its `cogito_persistent_id` metadata to its original level ID. Older snapshots without IDs use legacy restore rules. Test a pickup, a renamed object, a manual save, an autosave, New Game and reload after death. See [Saves](saves.md) and the [format reference](save-format.md).
