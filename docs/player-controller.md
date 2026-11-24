Based on the Cogito wiki page Player Controller (https://codeberg.org/Phazorknight/Cogito/wiki/Player-Controller) by Philip Drobar and contributors, MIT.

# Player controller

Instance [cogito_player_advanced.tscn](../addons/cogito/PackedScenes/cogito_player_advanced.tscn) for the first-person player. `CogitoPlayerAdvanced` is the only controller shipped in 1.3.0. Run your level over a collidable floor and tune movement in the Inspector. Mouse sensitivity and inversion also depend on the player's saved options.

## Movement and scene layout

Godot State Charts runs three parallel branches in the packed scene. Moving handles locomotion, BodyPosture handles standing and crouching, and PushingObjects handles pushing. The controller can sprint, slide, climb stairs and ladders, sit, swim and pull itself onto a ledge. A shape cast checks clearance above and ahead before a ledge climb. The player can crouch partway up to enter a low opening. For a swimmable volume, use [water_area.gd](../addons/cogito/Scripts/water_area.gd) on an area with a collision shape and the Water physics layer. Use jump to rise and crouch to dive.

Use `no_pause_menu_states` to restrict the pause menu in specific states. Entering a state in `no_interaction_states` clears `is_in_interaction_state`. The 1.3.0 interaction dispatcher does not reject an action on that flag alone. If your custom controller requires this restriction, check the flag before dispatch. The camera's InteractionRaycast sets the player's reach. Carry and wieldable placement are assigned on the player interaction component. See [Interactions](interactions.md) for the child nodes and public API.

## What other scripts can rely on

`CogitoPlayer` is the abstract base. An area that receives a body can test `body is CogitoPlayer`. For code outside the scene, `CogitoSceneManager.get_player()` returns the registered player or null. Advanced calls `CogitoSceneManager.register_player(self)` when it becomes ready.

- Set `player_interaction_component_path`, `body_path` and `head_path` relative to the player root. Keep the interaction component a direct child. The head anchors objects such as the lockpick minigame. The body supplies orientation for saves and scene connectors.
- Assign `player_hud` to a `CogitoHud` implementation. The supplied `CogitoPlayerHudManager` handles hold progress and inventory visibility. Interfaces restore the player's `gameplay_mouse_mode` on close.
- To drop inventory into the level, call `drop_item(slot_data)` with an `InventorySlotPD`. It checks clearance with `item_drop_shapecast` and returns whether placement succeeded. A custom controller can override it.
- A custom controller implements `create_new_state()` and returns a `CogitoPlayerState` subclass. The supplied state is `CogitoPlayerAdvancedState`. Its population methods save and restore controller-specific movement as well as shared player data. Call `setup_attributes_and_currencies()` during setup and `setup_elements()` for elemental effects.
- `pause()`, `resume()` and `override_gravity()` have empty base implementations. Override them to suspend movement during loading or death and to respond to gravity zones.

The included scene has health, stamina, oxygen, sanity, visibility and strength. See [Attributes](attribute-system.md), [Elements](elements.md) and [Saving the player](saves.md).
