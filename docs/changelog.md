# Daedalion 1.4.0

This release adds multiplayer to the Advanced demo and keeps independent travel between levels.

## Breaking changes

- Multiplayer peers must match protocol 20 and the server’s content version. Eligible owners receive a 568-byte v5 movement checkpoint. See [Networking](networking.md#owner-checkpoint-protocol-20).
- Multiplayer worlds use layout 1 with separate world, level and player records in the v2 JSON envelope. Solo slots keep their 1.3.1 format. Import a solo slot into a new world to designate its owner. See [Saves](saves.md#multiplayer-saves) and [world generations](save-format.md#multiplayer-world-generations).

## Added

- Host a listen session or join by address from the Multiplayer menu. Players can travel independently between Lobby and Laboratory. The Linux dedicated server includes a config, operator commands and a systemd unit. See [Networking](networking.md) and [Dedicated server](dedicated-server.md).
- The server owns interactions, inventories, equipment, damage, respawns, NPC perception and combat. Players can carry rigid objects and drag replicated corpses by a grip. World checkpoints retain level state and personal progression across restarts. See [Networking](networking.md).
- Owners predict on-foot motion, including stairs, slides, ladders, swimming, ledge climbs, landing rolls and door-driven moving supports. Corrections replay pending commands. See [Player controller](player-controller.md#movement-step).

## Changed

- Dedicated and listen servers run fixed-tick movement for the shipped Advanced prefab by default. Clients can opt out independently. See [owner prediction](networking.md#owner-prediction-and-replay-pr3pr8).
- The [release measurement](testing.md#release-measurement) records tick time, replay cost, corrections and payload rates in both demo scenes.

## Fixed

- A prediction-enabled client follows server poses when the host disables the movement kernel. Reconnects and forced pose changes clear stale movement history. See [Networking](networking.md#owner-checkpoint-protocol-20).

# Daedalion 1.3.1

Bug fixes for NPC combat. No breaking changes; the save format is unchanged.

## Fixed

- An NPC hit by a projectile was sent towards the level origin: projectiles fired by the pistol, the NPC blaster and throwables had no origin. Projectiles and thrown objects now record where they came from and who fired them (`CogitoObject.shooter`).
- Hits were ignored while an NPC was Alerted, Investigating or Searching. A hostile NPC shot by the player now chases that player from any calm state (including Idle); other hits alert it again towards the attacker. Use `CogitoNPC.attacker_of()` to find who caused a hit.
- An NPC that started a chase without investigating first fired from its holstered weapon, so shots came out of its body. A chase now draws the weapon, and an attack never fires a holstered weapon.

# Daedalion 1.3.0

Changes are relative to Cogito 1.2.0. Projects moving to this release should follow the [migration guide](migration-1.2-to-1.3.md).

## Breaking changes

- Godot 4.7.2 is the target. The project resources and import settings use the 4.7 format.
- `CogitoPlayerAdvanced` is the only bundled controller. Saves made with `CogitoPlayerSimple` appear as broken slots and cannot be converted.
- The Advanced save-state class was renamed from `CogitPlayerAdvancedState` to `CogitoPlayerAdvancedState`.
- Player detection uses `is CogitoPlayer`. Custom controllers must register with the scene manager and supply a `CogitoHud` implementation for `player_hud`.
- Replace the QuickAudio dependency with the `CogitoAudio` autoload. Update custom damage handlers to accept amount, source, hit direction and hit position.
- New saves use v2 JSON. The project name gives Daedalion its own user data directory. Existing Cogito profiles need an explicit transfer.

## Added

- [Interaction actions](interactions.md) let controllers query a component's choices and run one directly. HUDs and interactables can use the public player and interaction contracts.
- [Quickslot sets](quickslots.md) support arbitrary entry counts, data-driven actions, custom views and a radial wheel with submenus, including ammo choices.
- [Element states](elements.md) model buildup, resistance, heat, fuel, wetness, cold, shock and poison. Actors can slow, freeze, struggle or panic. The HUD shows their states. Four Laboratory stands demonstrate the reactions.
- [Save slots](saves.md) publish transactionally and identify objects by persistent ID. New snapshots distinguish a removed pickup from an object added in a level edit. New Game resets the playthrough and death reloads the newest valid save.
- [gdUnit4 suites and CI](testing.md) cover gameplay and persistence. Local checks include lint, engine warnings and three demo smoke scenes.

## Changed

- `PlayerInteractionComponent` delegates to targeting, carrying and wieldable child nodes. The player exposes node paths, item dropping, mouse mode, pause, resume and gravity hooks.
- Spinners follow angular motion from the mouse or stick and show the current input direction. The demo selects its own settings through `cogito/settings/settings_file`. Projects can use the addon without DemoScenes.
- The scene manager delegates slot storage, indexing, player and scene persistence, and transitions to helpers. Its public autoload API stays available.
- **Included from Cogito after 1.2.0.** `CogitoAudio` plays one-shot sounds and chooses layered `CogitoMusicState` resources by priority. SFX and Music feed Master. Saved bus volumes apply on load, and NPCs can request combat music.
- **Included from Cogito after 1.2.0.** Quests use `CogitoQuestObjective` resources with reveal, completion and failure conditions. Flag groups, the flag Inspector and objective localization support more complex quest progress.

## Fixed

- Overlapping saves and scene changes are guarded. A failed load leaves the current game available. Invalid slot names cannot corrupt history. Compatible legacy binary states convert during a successful save.
- Restoring health updates displays without triggering damage, loot or death again. Equipped ammo, magazine charge, empty inventory positions and quest progress restore with their saved owners.
- Burn damage passes the full `damage_received` arguments. Buttons and switches accept shorter and longer damage calls. NPCs handle unfamiliar attackers and ignore their own burn damage as an alert source.
- The player's `no_interaction_states` (rolling, free fall) now block interactions; the check was always false before.
- Carrying blocks unrelated direct actions. Listing pickup actions has no gameplay side effects. Other fixes cover elemental transitions, NPC chase range, search markers, loot rows and gamepad scrolling.
- Included from Cogito after 1.2.0 are fixes to quick load after transitions, the options menu, ledge climbing with hold-to-crouch and closing a door locked while open.

## Removed

- The Simple player scene, controller and state script were removed.
- The former sound plugin was removed from the dependency list. Cogito credited [QuickAudio by Bryce Dixon](https://github.com/BtheDestroyer/Godot_QuickAudio).
