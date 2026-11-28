Based on the Cogito wiki page Player Controller (https://codeberg.org/Phazorknight/Cogito/wiki/Player-Controller) by Philip Drobar and contributors, MIT.

# Player controller

Instance [cogito_player_advanced.tscn](../addons/cogito/PackedScenes/cogito_player_advanced.tscn) for the first-person player. `CogitoPlayerAdvanced` is the only controller shipped in 1.3.0. Run your level over a collidable floor and tune movement in the Inspector. Mouse sensitivity and inversion also depend on the player's saved options.

## Movement and scene layout

Godot State Charts runs three parallel branches in the packed scene. Moving handles locomotion, BodyPosture handles standing and crouching, and PushingObjects handles pushing. The controller can sprint, slide, climb stairs and ladders, sit, swim and pull itself onto a ledge. A shape cast checks clearance above and ahead before a ledge climb. The player can crouch partway up to enter a low opening. For a swimmable volume, use [water_area.gd](../addons/cogito/Scripts/water_area.gd) on an area with a collision shape and the Water physics layer. Use jump to rise and crouch to dive.

Use `no_pause_menu_states` to restrict the pause menu in specific states. Entering a state in `no_interaction_states` (Rolling and FreeFall by default) clears `is_in_interaction_state`, and the interaction component rejects input interactions and direct actions while it is false. A custom controller can expose the same `is_in_interaction_state` property to get this behaviour. The camera's InteractionRaycast sets the player's reach. Carry and wieldable placement are assigned on the player interaction component. See [Interactions](interactions.md) for the child nodes and public API.

## Movement step

`CogitoMovementStep` computes ground acceleration and speed, air control and gravity, jumps and
landing thresholds, crouch clearance and head height, static stair candidates, slides and movement
stamina costs. Offline and with the network switch off, Advanced calls these phases from its chart callbacks. It accelerates using
the stored direction, saves the requested velocity, queries stairs, then carries the adjusted
momentum into the next tick. The controller owns the sweeps, shape changes and `move_and_slide()`.
The chart, Timers and stamina attribute still advance on their respective clocks and commit effects.

For a simulation starting at a physics boundary, call `capture_movement_state()` and
`capture_movement_profile()` on the configured actor. Both return independent values. Timer
remainders are in seconds. Pass the sampled command values and fixed delta to the phases, and supply
fresh contact observations at each solve. The live actor reuses its scratch records and reads tuning
when each rule runs. The golden runner exercises checkpoint restoration during a jump and a slide.

Games overriding Advanced can keep their existing callbacks, exports and stair queries. A callback
that calls `super` runs the shared rules there. A custom movement mode can supply its own profile,
contact observations and mode memory. Ladder, water, ledge, roll and platform handling continue
through their existing Advanced callbacks.

The online opt-in hook is `authority_movement_profile()`. Advanced matches its shipped
scene and script. A different prefab or controller uses its own chart by default. A game
using the same on-foot rules, chart events and standing/crouching shapes can opt in from
its Advanced subclass by returning `capture_movement_profile()` from this hook. Return
`null` for custom movement that the shared step does not implement. Set your movement
exports before spawn. On-foot integrators can use `movement_grounded()` and
`movement_floor_normal()` for the committed contacts. The environment switch and
authority lifecycle are described in [Networking](networking.md#fixed-tick-authority-movement-pr1b).

On a predicting network owner, `get_aim_transform()` returns the simulation head's
world transform with current body, neck and head look. After a restore, the interaction
ray, carry marker and drop cast already follow the corrected eye when the next command
is sampled and its edges dispatched. The actor receives its final pose after the live
movement step. Movement checks the checkpoint's active hull and
clearance in the bound physics space. `movement_grounded()` and `movement_floor_normal()`
expose the predicted contacts. The camera and its viewmodel receive a decaying position
offset after reconciliation. Mouse motion received between samples keeps its current
orientation. On suspension the authored camera paths and server-pose presentation resume.
Offline aim continues to use the animated eye.

## Per-actor input and presentation

Advanced samples one `CogitoPlayerInputSource` at the start of each physics tick, before its child
state chart runs. The default local source reads the Input Map through the player's existing
`InputRouter` callback. Mouse look updates on the routed motion event. The stick uses the configured
deadzone, sensitivity and per-physics-tick rotation. Each actor owns its own source and frame.

Set `is_local_presentation` and, optionally, `input_source` **before adding the instance to the tree**.
The demo uses the default local role. Only that role registers with the scene manager, captures the
mouse and creates an active first-person view and HUD. The current camera supplies the viewport's
default audio listener. A non-local instance retains the animated eye transform, casts, spatial audio
and chart. Its default source emits stationary commands. An injected source can drive it headless.
Use `get_aim_transform()` to aim from the acting player. Use `CogitoSceneManager.get_player()` to find
the local presentation owner.

`CogitoPlayerCommand` contains a sequence, movement inside the unit disc, body yaw, head pitch and
neck yaw in radians. These absolute local angles allow a later receiver to recover aim from a single
frame after a lost update. Neck yaw preserves the difference between looking and walking during
free look. The held mask supplies continuous actions such as jump, sprint and swim descent.
Ordered byte edges retain every press and release, including a complete tap between ticks.
`last_consumed_sequence` advances when the controller accepts a newer command. Repeated sequences
cannot replay an edge.

`encode()` and `decode()` use a 28-byte header plus one byte per edge. The header contains a uint32
sequence, five float32 values and a uint32 button word. Bits 30 and 31 encode the actor’s crouch
preference and suppressed input respectively.
Edge IDs follow `CogitoPlayerCommand.Action`, with bit 7 set for a release. Simulation uses full
precision locally. The codec and sequence are available for MP1b. They are independent of save slots.

A scripted source can use the same controller as the demo. For example, this source walks forward
along the actor's current facing.

```gdscript
extends CogitoPlayerInputSource


func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
	var command := super.sample(actor, sequence)
	command.move = Vector2.UP
	return command
```

Custom offline controllers may keep their existing input handling. To adopt this contract, keep a
source per instance, sample it before movement, apply the frame's aim and held state, then dispatch
its edges once per accepted sequence. Override `neutral_command()` for rig-specific look axes and
`get_aim_transform()` for the actor's eye origin. The bundled local sampler uses Advanced's first-person
rig. A different rig can provide its own device sampler.

## What other scripts can rely on

`CogitoPlayer` is the abstract base. An area that receives a body can test `body is CogitoPlayer`. For code outside the scene, `CogitoSceneManager.get_player()` returns the registered player or null. Advanced registers the local presentation owner when it becomes ready.

- Set `player_interaction_component_path`, `body_path` and `head_path` relative to the player root. Keep the interaction component a direct child. The head anchors objects such as the lockpick minigame. The body supplies orientation for saves and scene connectors.
- Assign `player_hud` to a `CogitoHud` implementation. The supplied `CogitoPlayerHudManager` handles hold progress and inventory visibility. Interfaces restore the player's `gameplay_mouse_mode` on close.
- To drop inventory into the level, call `drop_item(slot_data)` with an `InventorySlotPD`. It checks clearance with `item_drop_shapecast` and returns whether placement succeeded. A custom controller can override it.
- A custom controller implements `create_new_state()` and returns a `CogitoPlayerState` subclass. The supplied state is `CogitoPlayerAdvancedState`. Its population methods save and restore controller-specific movement as well as shared player data. Call `setup_attributes_and_currencies()` during setup and `setup_elements()` for elemental effects.
- `pause()`, `resume()` and `override_gravity()` have empty base implementations. Override them to suspend movement during loading or death and to respond to gravity zones.

The included scene has health, stamina, oxygen, sanity, visibility and strength. See [Attributes](attribute-system.md), [Elements](elements.md) and [Saving the player](saves.md).
