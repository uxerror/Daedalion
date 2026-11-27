# Daedalion seamless world implementation plan

**Status:** Approved for **Daedalion 2.0** (2026-11-27); the recommended defaults in section 10 are accepted, and the connected demo gets an early offline "World (preview)" entry after WS3. Work starts after the 1.4 release, whose MP10 delivers independent per-player level travel; WS7 adapts that coordinator instead of replacing a missing MP10. Baseline is the MP9b snapshot. Stage sizes and performance targets below are estimates.

## 0. Direction and acceptance

A playthrough has one world root, one `World3D`, one physics space and one navigation map per running game instance. An authored sector is an ordinary `.tscn` placed in that world. A player can walk through a doorway, push a crate through it, hear a shot on the other side and turn back without changing scenes.

Offline uses one player's surroundings. The authority loads the union of all players' surroundings. Each remote client loads its own surroundings. A listen host simulates that union and presents the host player's view. The main menu is a separate scene. Only world boot may show a loading screen. `docs/dev/multiplayer-plan.md:27–32`, `project.godot:13–16`.

| Decision | Implementation consequence |
| --- | --- |
| Standard Godot 4.7.2, approximately ±8 km per axis | Use fixed world coordinates, metre units and local asset origins. No origin shifts. Version coordinate representations so a later precision build can read the same world. |
| Unloaded sectors freeze | Capture an entity under its current owner. Resume timers from their remaining duration. Crossing the boundary can change the owner before either sector unloads. |
| Interiors are geometry | Floors, caves and buildings can have their own sectors. Doors operate in the shared space. A future teleport component would have its own destination-readiness contract. |
| Independent movement | Preserve each player's actor, identity, input sequence and life across boundaries. Replace MP10 travel with the WS stages below. |
| Compatibility | Keep the old offline reader and deprecated transition code through 1.x. Remove transition authoring from the demo and user guides. Remove the deprecated implementation in 2.0. |

The identity provider, death policy, shared and personal quests, manual saves, autosave, departure checkpoints, reconnect placement and operator rebind continue to apply. The change is the spatial scope under those systems. `docs/dev/multiplayer-plan.md:9–26`.

**Release test.** On dedicated and listen servers, two players separate until their client sector sets are disjoint. One moves an authored object and completes a shared objective. They meet again, save, stop the server and reconnect in opposite sectors. There must be one copy of the object, the correct inventory for each player, one shared completion, and no loading screen during traversal.

Paths beginning with `SceneManagement/`, `Networking/`, `DemoScenes/`, `CogitoNPC/` and other addon directories are relative to `addons/cogito/`. Test, tool and documentation paths are relative to the repository root. Proposed files are identified in the stage table.

## 1. What MP0–MP9 actually provide

MP0b implements useful scoping, but its isolation boundary is a whole simulation. The host synchronously loads and instantiates a scene inside a 2 × 2 `SubViewport`, enables `own_world_3d`, disables rendering and listeners, and frees the viewport on unload. Normal online gameplay can also mark a root in an ordinary window. `SceneManagement/cogito_level_host.gd:8–52`, `SceneManagement/cogito_level.gd:35–65`.

MP9 already captures several live roots. The first bound `net_players` endpoint owns admissions and avatars. Each additional root gets another endpoint with its own object, body and spawn services and shared inventory and quests. The secondary endpoint returns before binding the roster. Moving an occupied player between endpoints was never delivered. `Networking/net_players.gd:123–194`, `Networking/net_persistence.gd:316–348`, `docs/networking.md:910–917`.

Keep one session endpoint, one roster and one set of authoritative gameplay services. Give those services sector indexes, incremental registration and per-peer subscriptions. Keep the useful distinction between *which world may interact* and *which sector must be saved*. They now answer different questions.

### Counted dependency inventory

The inventory below counts production `.gd` files under `addons/cogito`. Counts are distinct source lines, including declarations, keys and diagnostics, after stripping `#` comments. Categories overlap. They give a review checklist, not an estimate of changed lines.

| Named dependency | Lines / files | Replacement |
| --- | ---: | --- |
| Root and identity helpers, hosted-root metadata and `entities.root` | 150 / 41 | Explicit world lookup, ownership lookup, local presentation lookup or sector capture, according to caller |
| Level/root/key/index/ready/active-level names and layout-1 active keys | 368 / 40 | World catalog, owner sector, per-sector state, per-peer set or layout-1 reader. Element intensity variables named `level` are excluded. |
| Current scene, boot destinations, connectors, scene swaps and start-scene settings | 68 / 17 | Explicit world boot, menu exit or compatibility reader |
| Epoch, client binding and `world.binding()` | 87 / 13 | World session, sector incarnation and observer subscription generation |
| MP0b viewport type and `own_world_3d` | 4 / 1 | Same-world sector mount. Keep isolated worlds for independent test peers. |
| Adapter metadata, observer/event gates, scene-state and transition facade terms | 123 / 36 | Keep adapter APIs, supply world services and target-specific observers. Route old facade operations through compatibility. |
| **Union** | **722 / 87** | Direct named dependencies. Important indirect behavior is called out below. |

Narrow counts make this reproducible across revisions. In non-comment production GDScript there are **88 qualified `CogitoLevel` calls in 36 files**: 27 `root_of`, 24 `spawn_parent`, 20 `nodes_in_group`, 8 `local_player`, 5 `hosted_root` and one each of `tree_of`, `current_root`, `mark_network_root` and `unmark_network_root`. All four native group-query calls are inside `cogito_level.gd:64–82`.

There are **8 literal `current_scene` references in 5 files**. Two select or attach the network bootstrap, two implement offline fallback, one selects the solo save root, one selects the death-restart scene and two swap the loaded scene. `Networking/cogito_net.gd:85,278`, `SceneManagement/cogito_level.gd:32,103`, `SceneManagement/cogito_save_slots.gd:75`, `SceneManagement/cogito_scene_transitions.gd:45`, `SceneManagement/loading_screen.gd:63,69`.

`level_key` or `_level_key` occurs **48 times on 45 lines in 14 files**. Literal `epoch` occurs **94 times on 81 lines in 12 files**. `peer_in_level(` occurs **13 times in 9 files**, including its definition. Search those separately from avatar lifetime, equip generation, request ID and object revision. Those four mechanisms still have distinct jobs. `Networking/net_players.gd:259–300,582–609`, `Networking/net_interactions.gd:239–264`, `Networking/net_world_state.gd:233–265`.

The line index gives the full direct inventory. Directory headings expand to paths under `addons/cogito/`. Within each group, apply the scope in the heading and the exceptions described after the index.

```text
SceneManagement/ — world boot, sector ownership/capture, or the deprecated 1.x reader
cogito_level.gd:1,6,9,15,28,32,36,37,39,47,49,50,56,57,63,79,91,99,103
cogito_level_host.gd:1,5,8,9,12,15,19,20,21,28,29,31,33,37,44,45,47,48,51,56,57,61,62
cogito_persist_nodes.gd:13,14,15,16,25,52,106,129,146,230
cogito_persistent_id.gd:8,16,18,23,24,25,41,45,49,50,51,52,53,58,65,66,74,78,79,92,93,96,97,100,103,109,110,113,115,118,119,120,126,127
cogito_player_advanced_state.gd:81,217
cogito_player_persistence.gd:37
cogito_player_state.gd:23,24,59,60,61
cogito_save_slots.gd:50,53,58,59,75,76,78,79,82,91,94,109,123,147,149,155
cogito_scene.gd:4,6,24,49,51,55,56,57,63,72,74,75,79,87
cogito_scene_manager.gd:18,55,57,58,59,60,77,105,107,110,200,201,208,209,278,279,283,284,294,295,301,302,309,310,318,319,322,323,325,337,338,346,347,350,359
cogito_scene_persistence.gd:16,17,18,23,24,26,29,33,34,60,63,64,65,66,71,72,73,74,79,80,94,108,109,110,133,134,137,139,140,144,161,176,205,206
cogito_scene_state.gd:23,24,31,68,69
cogito_scene_transitions.gd:14,16,18,20,24,45,46,50,53,56,57,58,59,84,94,97,99,100,108,109,118,127,139,140,142,157
cogito_slot_files.gd:21,22,29,30,75,76,77,82,99,101,103,105,107,109,110
cogito_world_files.gd:142,146,147,152,153,154,162,164,170,171,187,244,251,261,270,274,281,315,317,318
loading_screen.gd:11,12,13,20,22,26,32,34,37,38,41,43,54,62,63,66,67,68,69,71,73,74,76,79,82,83,84,86,87,90,92,93

Networking/ — one session, sector records and addressed observer sets
cogito_net.gd:85,87,165,174,178,184,278
cogito_respawn_policy.gd:7,8,21,33,34
dedicated_server.gd:24,27,29,31,34,37,38,39
net_actions.gd:21,23
net_bodies.gd:137,139,169,170,174,175,178,179,205,207,211,212
net_carry.gd:53,54,58,60
net_combat_events.gd:54,55,57,59,64,75,112,117,121,127,135,149,186,206
net_config.gd:6,21,54
net_containers.gd:64,120,124,127
net_death.gd:205,232,233,269,271,272,274
net_devices.gd:96,129,130,134,138,139,183,200,307,308,310,312,316,318
net_elements.gd:118,120,125,126,130,131,134,135
net_entities.gd:10,12,21,22,23,24,27,43,60,128,165
net_interactions.gd:176,188,189,218,221,243,244,258,259,463,468,470,478,492,538
net_inventory.gd:192,214,242,312
net_npc_listeners.gd:82,86,88
net_perception.gd:264
net_persistence.gd:19,41,52,53,55,70,86,87,96,100,101,103,104,155,156,157,158,159,164,178,199,200,201,208,210,241,242,243,245,322,323,324,326,327,329,343,378,379,380,386
net_players.gd:60,65,67,70,78,91,109,114,118,119,123,126,128,129,130,132,134,136,137,140,141,159,162,164,169,171,179,184,187,194,198,199,200,201,205,207,217,220,221,223,224,225,228,230,234,238,240,245,259,269,285,288,290,294,299,300,304,309,325,351,385,390,420,482,484,485,496,556,569,634,644,675
net_profile_tools.gd:63
net_profiles.gd:43
net_projectiles.gd:84,85,118,171,175,176,258,259,260,261,265,266
net_quests.gd:35,36,37
net_reconnect_policy.gd:9,10,19,24
net_solo_import.gd:19,20,22,27,28,33,81,88,103,112,113,114,115,125,126,128,136,174
net_spawner.gd:177,248,250
net_world_state.gd:22,67,72,96,130,146,184,227,229,233,234,236,243,252,256,258,314,323,327,328

CogitoObjects/ — world service for actions, owner for durable spawns, listener for presentation
cogito_button.gd:109,132,139,140,153
cogito_door.gd:230,239,249,264,272,282,291,299,327,342,349,360,384
cogito_keypad.gd:155
cogito_loot_drop_container.gd:76,253,254,305
cogito_lootable_container.gd:84,104
cogito_object.gd:250
cogito_player.gd:323
cogito_player_advanced.gd:1945
cogito_pressure_plate.gd:57,65,66,90
cogito_projectile.gd:78,82,142,165
cogito_sittable.gd:228,263,297,323,510
cogito_snap_slot.gd:62,114,123,149,156,169,221,292,294
cogito_switch.gd:149,150,176,192,199,221
cogito_turnwheel.gd:79
cogito_vehicle.gd:24
cogito_vendor.gd:48,93

Other addon paths — apply the operation-specific scope below
CogitoNPC/cogito_npc.gd:146,207,447,485,488
CogitoNPC/detection/hearing_detection.gd:140
CogitoNPC/detection/sight_detection.gd:252
Components/Attributes/cogito_health_attribute.gd:50,80,81
Components/HitboxComponent.gd:41
Components/ImpactSounds.gd:36,37
Components/Interactions/SpinnerInteraction.gd:277
Components/Interactions/lockpick_interaction.gd:194
Components/LootComponent.gd:56,80,89,137,151,163
DemoScenes/DemoPrefabs/ElementStands/element_stand.gd:37,59,73,74
DemoScenes/main_menu_boot.gd:32,33,34,35,36,37,38
DynamicFootstepSystem/Scripts/footstep_surface_detector.gd:185
EasyMenus/Scripts/cogito_death_screen.gd:153,154
EasyMenus/Scripts/pause_menu_controller.gd:301,302,305,306
InventoryPD/cogito_loot_generator.gd:24,25,26,73,107,108,109,111,114,119,120,121,152,153,154
QuestSystem/Components/cogito_quest_updater.gd:25,26
Scripts/bullet_decal_pool.gd:11
Scripts/cogito_audio.gd:42
Scripts/cogito_cutscene_trigger.gd:36,46
Scripts/cogito_meter.gd:76
Scripts/cogito_spawnzone.gd:26
Scripts/player_hud_manager.gd:173
Scripts/scene_transition_zone.gd:4,6,8,29
Wieldables/npc_wieldable.gd:70,105,183
Wieldables/wieldable_laser_rifle.gd:162
Wieldables/wieldable_throwable.gd:80
Wieldables/wieldable_toy_pistol.gd:95
cogito_settings.gd:16,73
```

Several dependencies are expressed through ordinary names such as `root`, `bind`, `clear`, `position` and `records()`. The following are implementation boundaries in their own right.

| Caller or operation | Required scope |
| --- | --- |
| `root_of`, group queries, `find_in_level` | Add explicit `world_of(context)`, `sector_of(context)`, `members_owned_by(sector, group)` and world-ID lookup. Autoloads receive the emitter or world explicitly. A player in an adjacent sector remains visible to a sensor. A sector save enumerates only its owners. `SceneManagement/cogito_level.gd:12–41,60–94`, `SceneManagement/cogito_scene_state.gd:20–48`. |
| Runtime parent | Put movable entities under a stable world `Dynamic` branch. Record ownership separately. Put attached audio/decals on the emitter, short-lived free effects under world presentation, and player HUD under the local player. `CogitoObjects/cogito_player.gd:323`, `Scripts/cogito_audio.gd:37–59`, `Scripts/bullet_decal_pool.gd:9–32`. |
| Registry and spawner | Incrementally add/remove sector contributions. `bind()` currently scans descendants, and spawner bind clears live objects and bag archetypes. Unbinding one sector must release only its entries. `Networking/net_entities.gd:20–80,102–130`, `Networking/net_spawner.gd:15–42,198–250`, `Networking/net_world_state.gd:133–155`. |
| Device adapters | Preserve `net_state`, `apply_net_state`, signals, local animation coordinates and authored links. Metadata can point to a stable world service. Resolve a target's current owner at use time. `Networking/net_world_state.gd:65–111,158–180,349–369`. |
| AI, hearing and elements | Query live nearby actors/contacts in the world, including across seams. Run server simulation independently of observer readiness. `Networking/net_perception.gd:47–74,257–267`, `Networking/net_npc_listeners.gd:55–80`, `Networking/net_elements.gd:86–110`. |
| Inventories and quests | Owner-private state follows identity. Shared progression and uniqueness use the world. Spatial triggers and visible pickups have sector owners. `Networking/net_quests.gd:33–58,198–243`, `Networking/net_spawner.gd:111–134`. |
| Menus and startup | Boot a catalog once. Keep return-to-menu and dedicated bootstrap scene changes. Preserve the separate save-world name and content selection. `DemoScenes/main_menu_boot.gd:22–43`, `Networking/cogito_net.gd:74–89,123–151,173–184`, `Networking/net_config.gd:5–24,45–61`. |
| Viewports | Retire the sector-per-viewport host from gameplay. A viewport per simulated **peer** remains useful in same-process tests. The offline light meter has a rendering viewport of its own. The online avatar already removes it. `tests/net/memory_session_suite.gd:39–51,78–98`, `Components/Attributes/LightMeterAttribute.tscn:15–38`, `Networking/net_avatar.gd:44–68`. |

## 2. World and sector authoring

### Scene contract

```text
DemoWorld                  Node3D, identity transform, owns catalog and runtime
  WorldEnvironment         one environment for the world
  Sun                      optional global directional light
  Sectors                  active sector shells at catalog placements
    lobby                  sector-local static geometry, regions, devices, markers
    laboratory
  Dynamic                  mobile NPCs, bodies, drops and runtime entities
  Players                  stable parent across every sector crossing
  Presentation             local listener, area settings and transient effects as needed
```

Use a small catalog Resource. Store a stable world-definition ID, content revision, default entry, and an ordered list of placements. Each placement has a stable `sector_key`, scene UID with path fallback, rigid placement transform, local ownership volumes, streaming bounds, entry markers, optional dependencies and optional chunk paths. Keep sector scene references lazy. A hard `PackedScene` reference from the catalog to every room would load its resource dependencies during boot.

The named saved world, such as `expedition`, is a playthrough instance of a definition such as `daedalion_demo`. Keep both IDs in the manifest. The existing `--world` selects a save directory and `--level` selects content. Introduce a world-definition setting without silently changing the meaning of `--world`. `Networking/net_config.gd:10–24,45–56`, `Networking/cogito_net.gd:123–130`.

A sector is a `Node3D` scene, authored near its own origin at unit scale. Its placement supplies translation and optionally rotation. Author local bounds in metres. Use a list of boxes for stepped or irregular footprints. Use separate, vertically bounded volumes for stacked floors. Streaming bounds enclose relevant geometry, collision, triggers and spillover. Ownership volumes determine where a mobile anchor belongs. Adjacent streaming bounds may overlap substantially.

| Content | Contract |
| --- | --- |
| Geometry, collision and occluders | Sector-owned. Give each floor, doorway collider and occluder one author. Mesh detail may straddle a seam within declared bounds. Split large meshes and CSG collision ahead of time. |
| Local lights, fog, reflection or GI volumes | Sector-owned and bounded. Local shadowed lights need an explicit range. Keep sun, sky and the single `WorldEnvironment` on the world root. Bake local GI with explicit bounds and test simultaneous neighbours. |
| Navigation | A sector may own several prebaked `NavigationRegion3D` nodes on the world map. Use the same bake settings along a shared walking surface. Door and lift traversal can use explicitly enabled links. |
| Audio, music and environment zones | Sector-owned volumes describe acoustic bus/reverb, ambient loops, music and camera environment. A listener resolves overlapping zones by priority, then stable key, and blends on entry/exit. A sector entering the tree must not change everybody's music. `SceneManagement/cogito_scene.gd:66–80`, `CogitoNPC/cogito_npc.gd:141–152`. |
| Spawns | Place named entry and respawn markers. NPC spawners have durable IDs, an allowlisted archetype and saved population/cooldown records. A sector mount cannot award starter gear or repopulate a dead NPC. Runtime living NPCs currently need an adapter. `Networking/net_players.gd:303–352`, `docs/networking.md:910–916`. |
| Players and global services | The world creates the offline player or MP avatars. A sector contains no player controller, current gameplay camera, HUD, session, save coordinator, second world environment or level transition zone. A cutscene camera may be present and explicitly activated. |

**Open terrain.** Start with roughly 128 m tiles, a proposed authoring default. Align terrain and navigation bake edges. Place a cave or multistorey building as additional 3D volumes. Use a grid or spatial hash to find candidate volumes quickly. Designers retain control of ownership independently of the grid.

**Compact buildings.** One room or one small building may be one sector. Split by a corridor, floor or heavy systems room when there is a measurable benefit. Give a tiny world a `resident` option. With one or two resident sectors, load at boot, register once and stop scheduling residency scans. It still exercises the same registration, save and load path.

**Editing.** In the world scene, place lightweight sector markers and edit their transforms. Double-click a marker to open its source `.tscn` in local coordinates. Add a Cogito editor dock that shows the current sector and selected neighbours at their placements, with bounds, apertures and navigation edges. Draw ghosts/gizmos or editor-only visual instances under a disposable preview root. Preview nodes have no saved `owner`, gameplay processing, active cameras or persistent-ID stamping. Saving a sector must produce no neighbour edits. `addons/cogito/cogito_plugin.gd:11–46`, `SceneManagement/cogito_persistent_id.gd:90–115`.

**Validation.** Run the same catalog validator in the dock and headless CI. Print both sector keys, node paths and world coordinates for conflicts. Check the following before merging content.

- Resolve every placement and archetype. Reject duplicate keys, non-finite transforms, scaled physics roots, bounds outside ±8,000 m and missing default entries.
- Expand instanced scenes for ID validation. Check explicit IDs, generated authored IDs, component paths, reused prefabs, parent references, migration aliases and reserved namespaces across the whole world, including unloaded scenes.
- Show streaming overlaps as normal. Reject unresolved ownership overlaps of equal priority, uncovered walkable gaps and duplicate colliders at seams. Allow authored nesting with a deterministic priority. Show winning owners on a floor-by-floor map.
- Flag forbidden root services, active player cameras, unbounded geometry, a spawn outside its owner, cross-sector raw `NodePath`/signal dependencies, and any chunk larger than the measured activation budget.
- Compare seam endpoints, bake settings and collision clearance. Run a capsule crossing, a two-way navigation path and a ray through each declared opening. A successful visual preview alone cannot establish traversability.

## 3. Streaming runtime

### Interest and scheduling

The world tracks reference-counted interest sources. An admitted player's authoritative position is the primary source. A server-approved cutscene camera, spawn/reconnect destination or quest may acquire a bounded pin with an owner, reason and release condition. An ordinary journal entry needs no pin. A spectator or remote camera requires explicit game policy.

Use distance from the point to each **volume**, including height. A large sector remains resident while the player is inside it, even if its origin is far away. Start testing at load distance **112 m**, release distance **144 m**, and **5 s** outside release range. These are proposed defaults. They leave a margin around MP4's 96 m replication radius. Use smaller paired values for a compact demo profile or a test that needs to force eviction. `Networking/net_bodies.gd:5–6,143–164`.

Compute an additional look-ahead from velocity, measured cold activation latency and braking distance. Query swept bounds for vehicles, moving platforms and fast bodies. Recompute candidates on meaningful movement, changed pins and a coarse fallback tick, initially 5 Hz. Physics checks the immediate safe frontier every tick. Coalesce overlapping sources. On the authority, a release requires zero player references and zero required pins.

| State | Work and exit condition |
| --- | --- |
| Absent → requested | Allocate an incarnation and priority. Use `ResourceLoader.load_threaded_request` for the shell and needed chunks. Deduplicate requests for a shared asset. |
| Requested → prepared | Poll `load_threaded_get_status`. Call `load_threaded_get` only after `THREAD_LOAD_LOADED`. Cache shared immutable resources. Hold instance-local materials, inventories and state separately. |
| Prepared → activating | On the main thread instantiate bounded chunks, attach, restore and register. Prioritize structural collision and the route ahead. Keep gameplay, triggers and replica presentation muted during partial construction. |
| Activating → ready | Finish dependency resolution, apply tombstones and records, then wait for collision and navigation registration at a physics synchronization point. Only this version of the sector may admit an actor or acknowledge readiness. |
| Ready → cooling | Retain live simulation during hysteresis. New interest immediately cancels cooling. |
| Cooling → frozen → absent | At the authority tick barrier finish ownership transfers, capture a frozen record and hand it to the writer queue. Detach events, unregister indices, remove local views/regions and free the chunks. Replicas discard their views without writing authoritative state. |

Each queued callback carries the world session, sector key and incarnation. An abandoned resource request may finish and warm the cache. Its completion cannot attach an obsolete node. A new request during eviction either cancels before capture or restores the newest frozen record after capture. Existing deferred element restore already checks a weak root before applying. Extend it with incarnation checks. `SceneManagement/cogito_scene_persistence.gd:32–56,172–191`.

### Frame cost and an unfinished boundary

The current screen threads resource loading, waits an artificial 0.5 s, then calls `packed.instantiate()` once. The host uses synchronous `load()` and a single `instantiate()` as well. Neither bounds main-thread work. `SceneManagement/loading_screen.gd:7–8,19–37`, `SceneManagement/cogito_level_host.gd:18–39`.

**Measured on this snapshot.** Two headless Godot 4.7.2 probe processes loaded the imported Laboratory from an anonymous in-memory pack and timed `PackedScene.instantiate()` with `Time.get_ticks_usec()`. Each made one first instance and six more from the same resource. The scene had **5,736 expanded nodes**, including its authored player. First instantiations were **63.42 and 59.32 ms**. Warm medians were **24.01 and 24.41 ms**, with a combined range of **21.76–26.93 ms**. Resource load was timed separately at **0.72 and 0.64 s**. Scene input is `DemoScenes/COGITO_4_Laboratory.tscn:1,467–493,5251–5273`.

These measurements exclude `add_child`, `_ready`, physics registration, navigation sync, disk seek and rendered frames. Logging/user-data destinations were read-only. Use the detached measurement to size the work: even a warm whole-Laboratory allocation exceeds one 60 Hz frame. The in-memory load times are unsuitable for estimating cold disk latency.

Start with **2 ms of main-thread streaming work per rendered frame**, and a separately measured 2 ms allowance per dedicated tick. `instantiate()` is indivisible. Yielding after a 24 ms call cannot meet that budget. Split oversized sectors into independent `.tscn` chunks, starting with static shell, collision, room props and expensive actors. A logical sector keeps one key and one record regardless of chunk count. Extract meshes and baked collision before considering per-node construction in GDScript.

Instrument request latency, individual allocation, tree entry/`_ready`, restore/index, first physics sync, first rendered traversal and teardown separately. Record first-use and warm p50/p95/p99/max, peak memory and concurrent writer cost. Profile an exported client with rendering and a headless server limited to one vCPU. Bake or split any single operation that repeatedly exhausts the allowance. Time-budget freeing large branches as well as adding them.

**If a player outruns streaming**, sweep the authoritative capsule or vehicle assembly against the ready frontier. Stop its outward motion at the last collision-safe point, allow turning and retreat, prioritize the missing sector, and resume on readiness. Apply the same rule to an owner whose client has not acknowledged the geometry. A physical door can stay closed until ready. On open terrain use the movement guard. Other players and the world clock continue. On repeated load failure keep the boundary safe, release stale jobs and report the sector and reason to the affected player/operator.

**Navigation.** Bake adjacent sectors against common neighbouring source geometry, then clip their output to matching edges. Agree on cell size/height, agent parameters, transforms and edge-connection margin. Activate regions on the same map, wait for a map iteration that includes them, then test the path in both directions. Use `NavigationLink3D` only for an intentional connection such as a lift. On unload invalidate paths into that region, stop at the frontier and repath when ready. The Laboratory's baked mesh already uses a 0.6 m agent radius and a 0.2 m border. `DemoScenes/COGITO_4_Laboratory.tscn:230–234,697–699`, `CogitoNPC/npc_states/npc_state_panic.gd:60–71`.

**Visibility and sound.** Stream local occluders and room lights with geometry. Hide distant presentation on a listen host while its colliders, AI and gameplay light/visibility zones remain authoritative. Strip presentational chunks on dedicated before `_ready`. Preserve gameplay shapes, aim anchors and animation-driven events. Use a local camera environment override for area-specific grading/fog, and one listener to blend ambient loops, music and reverb. Headless hearing uses authoritative noise positions. `Networking/net_avatar.gd:44–78`, `Networking/net_npc_listeners.gd:55–80`, `Scripts/cogito_audio.gd:37–59`.

Reserve an optional visual-only stand-in path in the catalog. Ship ordinary mesh LOD, authored sightlines and sufficient prefetch first. Add distant terrain HLOD/impostors when an outdoor benchmark needs them. A stand-in has no interaction IDs, collision, AI, navmesh, audio triggers or save record.

## 4. Ownership, identity and migration

Give every durable object an immutable world-unique `cogito_id`. For authored objects, stamp the placement key and stable local author ID, with an explicit override for moved or renamed content. Preserve an object's **birth** identity for its lifetime. Allocate runtime IDs from a world allocator and persist its high-water mark, including reservations for frozen and destroyed objects. Today `persist:` uses `ResourceUID.create_id()`, `level:` uses an authored path, and `runtime:<serial>` is minted by each spawner. `SceneManagement/cogito_persistent_id.gd:12–27,90–121`, `Networking/net_spawner.gd:198–205,290–295`.

The routed address is `(world_id, current_sector_key, cogito_id)`. Durable references use `(world_id, cogito_id)` and may cache a sector hint. A component key is relative to its registered entity. Store ownership as data, independently of scene parentage. Keep a world ID-to-owner index for migrants and an owner-to-live-members index for capture. Avoid scanning the world on every lookup.

At the end of each physics tick, classify each moved anchor against ownership volumes. Preserve its previous owner in a boundary tolerance band. Outside the band use authored priority, then stable key. Keep the last owner during a short uncovered transit and stop at the ready frontier. An uncovered navigable route is a validation error.

Transfer ownership once at that tick. Preserve transform, velocities, sleep, joints, actor identity, object revision and interaction claims. In one transaction update the source and destination member sets, home-sector suppression for a migrated authored object, the world locator and both dirty revisions. A removal caused by migration must never enter the gameplay destruction or loot path. `Networking/net_entities.gd:80,103–130`, `Networking/net_spawner.gd:198–205,273–295`, `SceneManagement/cogito_scene_state.gd:20–24`.

| Entity or relationship | Rule |
| --- | --- |
| Static doors, switches, containers and spawners | Their authored sector owns their state and timers. Intra-sector links may use ordinary node paths. A cross-sector link uses a durable ID. A required synchronous mechanism pins both parts. A deferred setter records an idempotent desired state for the dormant target. |
| Rigid body, corpse, drop | Use body centre or an authored anchor. A loose pickup comes under the sector at its actual drop position. Preserve runtime archetype, stock/charge, pose, velocity and sleep. `Networking/net_bodies.gd:18–47`, `Networking/net_spawner.gd:46–74,183–216`. |
| Held body, seat, vehicle, snap joint | Transfer an assembly together. A carried object's owner follows the carrier, with collision dependencies for its swept extent. A snap attachment follows its support. Seats retain the same occupant across a live crossing. Apply MP9's existing release rules on disconnect/restart. `Networking/net_carry.gd:53–60`, `Networking/net_seats.gd:1–133`, `Networking/net_world_state.gd:26–40,54–60`, `docs/networking.md:198–207`. |
| NPC | Keep one live actor in `Dynamic`. Transfer chart, velocity, health, elements, target ID/life, patrol reference and remaining perception timers. Resolve a dormant patrol target lazily, retain last-known position and repath when available. A migrated authored NPC needs a recreatable archetype even while its home scene is absent. `CogitoNPC/cogito_npc.gd:404–450,480–492`, `Networking/net_perception.gd:26–44`, `Networking/net_npc_state.gd:113–154`. |
| Ragdoll and loot dependencies | Save an allowlisted corpse/bag archetype independent of whether the source NPC or loot component is live. Current corpse restore looks up the NPC and an index, and a bag uses a path from the bound root. A body may travel farther than its source. `Networking/net_spawner.gd:15–21,175–195,209–224`, `Networking/net_npc_corpse.gd:16–48`. |
| Projectile | Own by current flight position. Sweep the whole step in one physics space, hand off at the crossing, apply one impact, and create any recoverable pickup at impact. Carry shooter identity/life and an archetype independent of a visible shooter. Use bounded look-ahead. If the next segment lacks collision, freeze at the last safe segment until ready or checkpoint the flight. On process restart preserve MP9's NPC-flight and expired player-life rules. `Networking/net_projectiles.gd:21–53,127–171,192–225`. |
| Elements, water, contact damage | A source area has one owner. Each affected actor/body owns its own buildup and remaining timers. Process cross-border contacts once per source/target in the world. Pin neighbouring collision for a live effect footprint. Rebuild overlaps silently on thaw, then resume ticks. Store remaining durations so wall time outside residency cannot burn or poison an actor. `SceneManagement/cogito_scene_persistence.gd:159–191`, `Networking/net_element_state.gd:133–135,164–206`, `tests/net/net_elements_test.gd:76–124`. |
| Quest triggers and unique loot | The trigger belongs to a sector. Its one-shot receipt belongs to the shared ledger or the subject's personal ledger and uses the immutable trigger ID. Migrate old `[level_key, id]` receipts. Count unique holdings in loaded sectors, frozen sector summaries, connected and disconnected inventories exactly once. Live possession objectives retain MP8's connected-party policy. `QuestSystem/Components/cogito_quest_updater.gd:17–27`, `Networking/net_quests.gd:121–146,198–229`, `Networking/net_spawner.gd:111–134`, `docs/quests.md:17–25`. |

On reload, create static parents and mobile archetypes first, restore local fields and owner indexes, then resolve links. Keep a deferred reference to a dormant target rather than loading arbitrary sectors through reference chains. Reserve an off-screen simulation hook over a versioned frozen record. The default does no work and advances no timers.

## 5. Persistence and compatibility

### One capture model

Reuse the MP9 data-only envelope and records. Introduce **world layout 2**, independently of codec version 2. The current reader requires `layout == 1`, an `active` member indexed in `levels`, and profiles naming one of those levels. The current writer explicitly emits layout 1. Implement both dispatch and validation before switching writers. `SceneManagement/cogito_world_files.gd:111–166,170–199,259–285`, `SceneManagement/save_codec.gd:20–44`.

| Logical member | Layout 2 |
| --- | --- |
| `world.v2.json` | Save-world ID, world-definition UID/path and revision, layout, generation, committed physics tick, sector and profile digest indexes, shared ledger/flags, custom shared fields, runtime allocator and migration/unique-item indexes. The catalog supplies the default entry. Zero loaded sectors and zero connected players are valid. |
| `scene_<sector-token>.v2.json`, kind `world_scene` | Stable sector key, content revision, record revision/freeze tick, authored manifest, state and tombstones, migrated-out IDs, incoming mobile archetypes/poses, runtime lifecycle, physics, containers, NPC memory, flights, elements and timers. Keep portable tokens and the hashed fallback. |
| `player_<digest>.v2.json`, kind `profile` | Server-issued ID, owner sector hint, explicit pose space, world pose or sector-local pose with its placement revision, private MP9 fields, death, inventory, currencies, attributes, elements and personal ledger. Keep credentials in the separate identity registry. |
| Offline slot metadata | Slot name/history, timestamp, screenshot/placeholder, selected manual slot and autosave behavior. A stable solo profile owns the full Advanced controller payload, including chart, child transforms, seat and quickslots. The world owns shared flags and quests. |

Prefer a tagged **sector-local pose** in durable mobile/profile records and a world transform in live simulation. Reconstruct from the saved placement revision on upgrade. Parent-relative component and animation transforms retain their existing meanings. Today a profile uses `actor.position`, MP4 saves `body.transform`, a runtime spawn may carry `global_transform`, and the spinner's pose is local. A blanket translation of every `pose` corrupts saves. `Networking/net_profiles.gd:38–63`, `Networking/net_bodies.gd:18–46`, `Networking/net_world_state.gd:26–40,217–224`.

**At tick T**, complete authoritative actions, physics outcomes and ownership transfers. Capture the shared ledger/allocator and dirty live profiles/sectors together on the main thread. Use immutable records for previously frozen sectors and retained departures. Carry forward verified digests for clean members. A frozen record from tick F represents its state at T because nothing simulated after F. Include both ends of every transfer in the same generation. Never build a nominal one-tick snapshot by sampling different live sectors on successive frames.

Track a dirty revision per sector, profile and shared index. Cover authored adapters, runtime birth/removal, body movement and final rest, carried transfers, timers, NPC memory, container stock and custom writes. Keep a bounded active set for continuously changing bodies/timers. Offer `mark_sector_dirty` for game code and a conservative capture/compare fallback for uninstrumented legacy saveables. MP9's single dirty flag and thresholded player check do not detect every physical change in a clean sector. `Networking/net_persistence.gd:142–150,378–398,403–454`, `Networking/net_world_state.gd:269–292`.

**On unload**, capture the complete owned state before removing registrations. Retain the newest unpublished record in memory and request a coalesced checkpoint through the same MP9b writer as manual save, autosave and departure. On rapid return, consult retained state ahead of committed disk. On completion, clear only the captured revision if it still matches. On failure retain the record, old complete generation and retry deadline. Impose backpressure on further evictions if retained bytes exceed budget. `Networking/net_persistence.gd:85–92,147–173,194–245,351–375`.

Keep the default 60 s dirty autosave, `0` to disable periodic saves, the 250 ms departure checkpoint window, manual requests, failure backoff, one writer claim, guarded rebind and bounded final flush. World publication must work with an empty live set. The worker receives immutable data and no live nodes. `Networking/net_config.gd:54–61`, `Networking/net_persistence.gd:27–39,254–308,428–454`, `Networking/net_world_write.gd:16–32,43–57`.

### Many visited sectors

MP9 currently recaptures **every live level** and admitted avatar, copies old flat files into staging, writes changed members, then hashes and decodes all indexed files to verify the generation. It also keeps decoded scene records in memory. Marking sectors dirty only at the caller would leave substantial disk traffic and RAM use. `Networking/net_persistence.gd:316–348`, `SceneManagement/cogito_slot_storage.gd:121–137,174–194`, `SceneManagement/cogito_world_files.gd:150–166,291–332`.

Use immutable member files in a store scoped to the world's save directory. A digest can address `members/<digest>/scene_<token>.v2.json` or `members/<digest>/player_<digest-of-id>.v2.json`. The transaction stages and verifies new bytes, then atomically publishes a small generation manifest. Keep the existing claim, rollback and recovery preference. Introduce a member-store operation beside the flat slot copier, which currently rejects directories and links. Avoid a dependency on filesystem hard links.

A clean sector costs an index entry per manifest and zero sector-payload writes. New bytes scale with dirty payload plus the manifest. Keep cold-open integrity verification and verify all referenced members before accepting a generation, using streaming hashes where possible. Verification reads and manifest serialization still grow with visited count. Decode sector state on demand, with a bounded cache. Keep only inventory/identity summaries needed for world-wide decisions resident.

Garbage-collect unreferenced members after successful publication, under the writer claim, considering current, rollback/recoverable ready generations and outstanding writer jobs. Offline named slots must own or durably reference all of their members after `temp` is cleared. A damaged member cannot become an empty default sector. Test 1,000 visited sectors, one dirty sector, a failed publish, missing clean member and a restart. Report captured nodes, bytes read/written, directory count, capture stall, worker time and peak memory separately. `docs/save-format.md:191–210`.

### Offline slots and 1.3 migration

Use the same sector scheduler, ownership records and world-generation publisher offline. Supply the Advanced solo profile adapter directly. Offline starts no ENet session, command serializer, observer-baseline machinery or network tick. Keep named slots, separate autosave, `saves.data`, screenshot behavior and latest-loadable death restart. With no loadable slot, start fresh at the current sector entry or the world default. `docs/saves.md:3–21`, `docs/save-format.md:66–92`, `SceneManagement/cogito_save_slots.gd:21–82,164–181`.

Detect layouts before activating a slot. Read supported 1.3 `player_state.v2.json` plus every visited `scene_<root>.v2.json`, or the configured binary equivalent when v2 is absent. A malformed v2 remains an error. Preserve the existing retired Simple-controller result. Prepare and validate in memory/staging while the original slot and running world remain available. Publish the upgraded layout on the next successful save. `SceneManagement/cogito_slot_files.gd:17–47,55–110`, `docs/save-format.md:41–64`, `tests/saves/world_import_test.gd:16–63`.

| 1.3 root / UID | Demo mapping |
| --- | --- |
| `Cogito03Lobby`, `uid://e31n36p8i6an`, old Lobby resource path | `daedalion_demo/lobby`, placement identity |
| `Cogito04Laboratory`, `uid://6hh7o77unixk`, old Laboratory resource path | `daedalion_demo/laboratory`, proposed translation `(-64, 0, 0)` |
| Old connector strings | Accept as compatibility aliases for an entry fallback. A valid saved player pose takes precedence. The new corridor starts from authored defaults. |

1. Match current and inactive files by root name, UID and historical path. Convert **both** rooms if both were visited. A missing room snapshot starts from authored content. Distinguish an absent authored-ID manifest from an explicitly empty one. `Networking/net_solo_import.gd:103–136`, `SceneManagement/cogito_scene_state.gd:4–24`, `tests/saves/persist_compat_test.gd:21–58`.
2. Build an old-to-new ID map per source room, including old `level:<path>`, relative non-Persist IDs, explicit overrides, generated IDs, root `"."` and `/root/<old-root>/…`. Rewrite parent IDs, saved nodes/states, destroyed children, attributes, elements, seat/patrol/attention references, quest receipts and runtime ownership. Keep component paths relative to their matched entity. Resolve pre-ID rows using the existing prefab/parent matching and game override. Report unresolved required parents or ambiguous content before publication. `SceneManagement/cogito_persistent_id.gd:44–80`, `SceneManagement/cogito_persist_nodes.gd:72–94,99–165,225–233`, `Networking/net_solo_import.gd:32–99`.
3. Apply the old-room-to-world transform **once** to old world-space positions, waypoints and player pose. Reconcile Advanced `player_transform` as well as `player_position`, since the loader reapplies the root transform. Convert global swim and seated references according to their fields. Preserve local body/head/neck/camera, bone and nested prop transforms. Rotate directional quantities only if the legacy placement rotates. `SceneManagement/cogito_player_state.gd:59–74`, `SceneManagement/cogito_player_advanced_state.gd:69–101,119–129,161–175,191–223`, `SceneManagement/cogito_persist_nodes.gd:177–211`.
4. Restore ordered inventory and quickslots, action/equipment state, currencies, flags, objectives and starter-item receipt before gameplay resumes. Keep the full solo state through offline conversion. The MP import deliberately projects it into a smaller network profile. Import into multiplayer remains an explicit copy to a designated identity. `docs/save-format.md:138–157`, `Networking/net_solo_import.gd:10–28,139–201`.
5. Support existing MP9 layout-1 worlds on the same reader dispatch. Their active key may be a resource path, a game key such as `lab`, or an imported inactive root name. Use a game-provided mapping for custom worlds. Remap per-level `runtime:1` collisions, flight serials, bag sources and references before reserving world IDs. Preserve player IDs, credentials, saved death, ledgers and rebind protections. `Networking/net_persistence.gd:68–92,153–165`, `Networking/net_profiles.gd:11–34`, `docs/save-format.md:185–200`.

For Cogito projects, ship an explicit legacy mapping resource with old name/path/UID, new placement, ID overrides and renamed entries. A standalone former level can be a one-sector world. An unmapped custom 1.3 slot stays readable through the deprecated offline route during 1.x, or reports the exact missing mapping if conversion was requested. Never guess placement for two unknown rooms. Keep the old script/resource paths loadable. Move transition examples out of user-facing guides and retain compatibility fixtures until the 2.0 removal. `Scripts/scene_transition_zone.gd:3–29`, `SceneManagement/cogito_scene_transitions.gd:14–46,83–94`, `SceneManagement/loading_screen.gd:59–93`.

## 6. Networking

### Authority, residency and subscription

Use one stable RPC endpoint per session. The server chooses initial sectors from the authenticated profile or world entry before the avatar is placed. It subsequently computes interest from the **server-simulated pose**. Send the client sector keys, placements/content revision and priority. Client look-ahead can warm an authorized resource. Client coordinates, camera requests and ready acknowledgements cannot enlarge gameplay interest.

Keep one identity and avatar lifetime through a sector crossing. A roster member may exist with no visible remote actor on a particular client. On interest exit release the remote representation and its listener effects. On entry spawn a current representation even if its life number is unchanged. Distinguish visibility entry from death/respawn and reconnect. Today `_spawn` ignores a life it already has, and `_release_subscription` also releases carry and seats. Those behaviors require separate visibility and lifecycle paths. `Networking/net_players.gd:238–300,343–404,407–445`.

- **World session generation** scopes this server run and invalidates packets from a previous session. Authenticate and compare the protocol, content revision and catalog identity before streaming. Protocol is currently **12**. `Networking/net_config.gd:5–6,27–41`, `Networking/net_session.gd:87–155`.
- **Sector incarnation** is issued by the authority each time a sector is activated. Keep its counter above the lifetime of the sector node. Reusing the same key within a session never reuses an incarnation.
- **Subscription generation** is per peer and sector. It changes on leave/re-entry even if the server kept the sector resident for someone else. Track `wanted`, `content_ready`, `baseline_pending` and `live` separately.
- **Entity ownership revision** rejects stale actions after migration, including an A → B → A return. Retain per-object revisions, request-result deduplication, avatar life, input acknowledgements and equipment generations. Persist durable identity and allocator state. Negotiate fresh session/subscription generations after restart.

Replace the single `_ready_levels[peer]`, per-root `_generation`, `_client_binding`, and `matches(key, epoch)` with those explicit scopes. Never clean up all of a peer's other subscriptions when one ends. `Networking/net_players.gd:60–73,228–290`, `Networking/net_world_state.gd:64–69,128–155,183–199`, `Networking/net_entities.gd:163–165`.

### Sector baseline and delivery

1. The server offers a sector and subscription token. The client loads matching local geometry, disables authored replica simulation and one-shots, then acknowledges content readiness. Bootstrap geometry and the owner avatar independently so neither waits for the other's final baseline.
2. At a server tick/revision watermark, send reliable baseline chunks on channel 3. Include authored suppressions/tombstones, runtime archetypes, mobile ownership revisions, current device state, dependency links, body/rest poses, current NPC/element state and flights within interest. Dormant or far authored interactables in a loaded shell stay hidden/inactive on the replica until their current state is known.
3. Instantiate dependencies first. Apply state silently, resolve references, then acknowledge the exact incarnation, subscription and watermark. Buffer newer changes per subscription. Put a byte/time limit on the queue. On overflow discard the partial baseline and issue a fresh one. Treat duplicate chunks/acks idempotently. `Networking/net_world_state.gd:194–265,325–365`.
4. Enable live delivery after the acknowledgement. Interest re-entry produces no opening, ignition, death, reward, shot, music cue or pickup sound. A flight already in progress gets a silent visual at its current position. Unsubscribe explicitly and reject old packets on **every** channel, including delayed unreliable motion and epoch-only launch/end RPCs. `Networking/net_bodies.gd:143–190`, `Networking/net_elements.gd:113–141`, `Networking/net_projectiles.gd:168–188,258–266`.
5. A peer seeing both sides of a migration receives one ownership update for the existing proxy. Source-only observers lose it without a death event. Destination-only observers receive a silent current baseline. Apply owner revisions monotonically so reordered remove/add messages cannot delete the new proxy.

Use ready sectors **and** entity distance. Always include a player's own data and required carrier/seat/attachment dependencies. Use surface/extent distance for large areas or long mechanisms. Route a positional event by its origin or affected footprint. Owner-private results, inventory and death UI use identity. Shared quests and party flags reach all admitted players, personal quests only the owner. Send their silent admission/reconnect baseline once, outside the per-sector loop. `Networking/net_players.gd:378–385,482–498`, `Networking/net_quests.gd:198–243`, `Networking/cogito_net.gd:267–284`.

Server commands still resolve the sender and validate life, target revision, component, range, line of sight and gameplay permissions. A neighbouring sector can be valid across an open door. A matching sector token alone grants no access. Cancel a private device/container view when the actor loses reach or its target unloads. Preserve a valid carried assembly across a seam. `Networking/net_interactions.gd:227–265,270–331`, `Networking/net_devices.gd:129–139,307–318`, `Networking/net_containers.gd:120–127`.

**Respawn and reconnect.** Record the sector of death. Apply the existing private delay, enabled-point policy and inventory policy there. Fall back to the sector entry, then a safe world entry. Before live reconnect placement, pin the saved sector and required neighbour collision, restore it, and perform the standing/crouched shape query in world coordinates. A blocked pose or a dead returnee uses the respawn policy. Do not replay the death or pay its cost twice. Retain the replaceable hooks. `Networking/net_death.gd:203–235,269–274`, `Networking/cogito_respawn_policy.gd:6–35`, `Networking/net_reconnect_policy.gd:6–24`, `Networking/net_profiles.gd:74–101`.

### Bandwidth and one-vCPU operation

Keep the initial rates close to the actual implementation: 60 Hz physics, 25 Hz avatar snapshots, body motion up to 20 Hz within 24 m, 5 Hz for more distant moving bodies within 96 m, reliable entry/final rest, and 10 Hz periodic element samples plus urgent changes. Current row-count limits of 32 for world baselines and element chunks are useful upper bounds. Also budget encoded bytes and reliable backlog. `docs/networking.md:325–329,638–653,775–798`, `Networking/net_bodies.gd:97–105,143–165`, `Networking/net_world_state.gd:7–9`, `Networking/net_elements.gd:4–7,74–110`.

Index live bodies, NPC candidates, emitters and observers by sector and spatial cell. Today body collection can scan bodies × players and again bodies × observers, element sampling loops observers × components, and perception visits the roster for every NPC. An interest filter at the last RPC would save bandwidth while retaining those CPU costs. Query candidate cells first, sample each entity once, prioritize gameplay physics and adapt cosmetic delivery under load. `Networking/net_bodies.gd:107–139,147–164`, `Networking/net_elements.gd:86–110`, `Networking/net_perception.gd:47–74`, `Networking/net_npc_listeners.gd:55–80`.

Budget baseline traffic separately from motion and control. Start with the MP plan's **64 KiB/s per-client steady-state target**. Measure co-located players, the same players dispersed, an observer entering a dense sector, and a stalled client. Record application payload and ENet/IP bytes separately. The file-bus harness measures only the former. `docs/dev/multiplayer-plan.md:162–170`, `docs/networking.md:702–706`.

For release, profile an exported headless server constrained to one vCPU at 60 Hz. Suggested gate: p95 simulation plus streaming under 12 ms, p99 under 16.7 ms, bounded backlog during join, autosave and unload. Report roster, loaded sectors, awake bodies, AI count, LOS rays, cold activation, writer CPU, memory and snapshot age. Two players far apart can nearly double live content even when each receives the same bandwidth. Publish measured capacity with hardware and fixtures. Apply admission limits before accepting an unsustainable roster. Never evict occupied collision to meet a soft memory target.

## 7. Precision and coordinates

At 8,000 m a binary32 coordinate lies in `[4096, 8192)`. Adjacent representable values are `2^(12−23)` m apart, **0.48828125 mm**. At 8,192 m spacing on the larger-magnitude side doubles to **0.9765625 mm**. These are component spacings. Contact solving, subtraction, camera transforms and interpolation can amplify the visible error.

| Path | Actual representation and range |
| --- | --- |
| Avatar snapshots | `actor.position` and velocity are ordinary `Vector3` fields in a dictionary. Angles and head height are scalar fields. The 4 m value detects a discontinuity, and the 100/50 ms values control interpolation/extrapolation. There is no small signed-integer position range. ±8 km is representable. Use world-space poses under the identity player branch. `Networking/net_snapshot.gd:4–6,14–33,38–55,75–97`. |
| Body snapshots | Rows carry a global `Transform3D` and two `Vector3` velocities. The 24/96 m values are interest distances. Save/restore currently uses the parent-local transform. There is no position grid or int16 clamp. ±8 km is representable. Review `is_equal_approx` on absolute transforms when deciding whether a slow NPC or resting body moved. Use explicit displacement/angular tolerances. `Networking/net_bodies.gd:18–46,113–128,143–165`, `Networking/net_body_timeline.gd:14–28,32–47`. |
| Elements | Spatial selection uses `anchor.global_position.distance_squared_to`. Payloads use `PackedInt32Array` for flags, levels ×32, fuel and deadlines ×10, health ×100, speed multiplier ×1000. The positive level range is about 67.1 million units and a positive decisecond deadline spans about 6.8 years. None encodes XYZ. Preserve remaining timers in saves. `Networking/net_elements.gd:89–107,113–140`, `Networking/net_element_state.gd:46–55,133–135,168–206`. |

Keep vertices, skeleton roots, attachment sockets, animation tracks and navigation bake inputs sector- or actor-local. Avoid world-space coordinates in tiny oscillations and accumulated root motion. Inspect distant camera/weapon alignment, contacts on thin steps, slow body replication, water, decals and world-space triplanar materials. Prefer model/view-relative shader calculations for fine detail. `Networking/net_avatar.gd:28–40`, `Assets/Shader/Material3DConversion.gd:382–396,453–463`, `Assets/Shader/ViewmodelSpace.gd:34`.

Validate finite values and bounds at data boundaries. Keep sector keys and IDs discrete. Use tagged transforms with documented units, origin and basis. Avoid serializing raw `real_t` memory, hard-coding a 12-byte vector, or adding absolute centimetre int16 coordinates. If compression becomes necessary, negotiate a versioned sector-local codec with checked range and an escape representation. A double-precision engine/export and cross-build save reads require dedicated testing. Mixed-precision network peers require explicit codec negotiation.

Test mirrored fixtures near `0`, `+7999` and `−7999` m, including a rotated sector, standing/crouched reconnect, capsule seams, joints, patrol/navigation, slow body movement, decals and save/network round trips. Compare against absolute physical tolerances. Confirm shader and animation behavior on a rendered build.

## 8. Connected demo

### Measured baseline

Counts are from the two source scenes and their expanded detached instances. Static bounds below merge transformed local shape AABBs for enabled `CollisionShape3D` children of `StaticBody3D`, excluding the player and nested viewports. They describe a measured envelope, not the full playable volume or generated CSG collision.

| Measurement | Lobby | Laboratory |
| --- | ---: | ---: |
| Source bytes / source lines | 839,792 / 7,995 | 389,523 / 5,274 |
| Authored node headers / external resources / subresources | 1,235 / 115 / 276 | 1,495 / 90 / 52 |
| Instanced node headers / expanded nodes including player | 439 / 3,385 | 1,294 / 5,736 |
| Static bounds, min → max in local metres | `(-16.75,-2.95,-24)` → `(9.97,7.76,17.5)` | `(-45,-3.2,-31)` → `(17,7,29.2)` |
| Expanded scene lighting, excluding player | 1 sun, 1 environment, 19 omni, 2 spot, 2 fog volumes | 1 sun, 1 environment, 3 spot |
| Navigation | No authored navigation region | One region, 562 baked vertices, 641 polygons. Local nav X extent about `−26.25..8.25`, short of the east doorway. |

Both environments specify a sky, low ambient contribution, SSAO, glow and volumetric fog. Both suns have the same transform, colour and shadow settings. Neither scene declares a `VoxelGI`, `LightmapGI`, reflection probe or occluder instance, or explicitly enables SDFGI. Local lights also come from instanced prefabs. `DemoScenes/COGITO_3_Lobby.tscn:122–142,3353–3379,6412`, `DemoScenes/COGITO_4_Laboratory.tscn:97–117,230–234,467–490,697–699`, `DemoScenes/DemoPrefabs/lamp_square_ceiling.tscn:95`, `PackedScenes/ceiling_lamp.tscn:44`.

### Proposed placement

Keep **Lobby at `(0,0,0)`** and place **Laboratory at `(-64,0,0)`**, both with identity rotation. Cut a west-facing opening in the Lobby vestibule at approximately `(-16,0,-4.75)` and an east-facing opening in the Laboratory vestibule at local `(17,0,-4.75)`, world `(-47,0,-4.75)`. Join them with a **31 m** level corridor, initially **3 m** clear width. Rebuild the two short approach turns and colliders. The old trigger planes face along Z. Simply translating one marker onto the other would leave the approaches misaligned. `DemoScenes/COGITO_3_Lobby.tscn:3762–3780`, `DemoScenes/COGITO_4_Laboratory.tscn:493–499,648–682`.

Give each room one authored half of the corridor, meeting at `x = −31.5`. Divide the floor collision and navigation polygons at that plane. Use one owner for a physical door if fitted. Check capsule, wheelchair-sized prop, carried torso, shot and NPC path in both directions. The aperture coordinates are proposed cuts and require a rendered collision walk-through.

| Scene | Content change |
| --- | --- |
| World root | One environment and sun, Lobby default entry, stable player/dynamic branches, catalog and streamer. Keep the two existing scene UIDs and authoring roots for migration. Preserve menu boot at `project.godot:15`. |
| Lobby | Remove `TransitionZone_LAB`, its shape, connector export/marker, `save_temp_on_enter`, embedded player and duplicate global lighting. Convert the player transform `(3.03073,0.905039,-17.9321)` to an entry marker. Add a respawn marker, upper corridor collision/nav and a Lobby music zone. Retain fog, local lights and laptop/fridge/archive gameplay. `DemoScenes/COGITO_3_Lobby.tscn:3353–3379,3762–3780`, `docs/quests.md:17–23`. |
| Laboratory | Remove the reciprocal zone/marker, connector export, embedded player and global lighting. Preserve the old player transform `(5.13854,0.8,-5.43073)` as a local entry. Preserve `Respawn1` and `Respawn2`, including their 1.6 m Z separation. Retain both NPCs, patrol paths, target range, element stands, spinner wiring and combat music zone. Rebake the route into the corridor and Lobby. `DemoScenes/COGITO_4_Laboratory.tscn:467–493,667–699,3973–3984,4012–4027,5166–5177,5251–5263`. |
| Entry settings | Point offline New Game and online default content to the world. They currently point to Lobby and Laboratory respectively. Preserve a test/debug start at the Lab entry. Remove loading-screen and transition settings from the demo resource. `DemoScenes/DemoCogitoSettings.tres:5,18–26`, `Networking/net_config.gd:5–6,45–56`. |

Preserve the authored player inventory overrides as entry/new-life configuration where appropriate. Grant them once per new profile. Extract heavy geometry into chunks without changing gameplay component-relative paths or the ID mapping. The compact demo may naturally keep both rooms resident. Use deliberately small radii or a separate distant-sector fixture to prove actual eviction.

## 9. Stages and verification

Each row is a reviewable stage with at most two implementation batches. Sizes include tests. Ship new paths behind an explicit world-definition entry until the corresponding offline, listen and dedicated fixtures pass. The old entry keeps existing tests executable during conversion. Remove the temporary adapters from normal gameplay at cutover.

**Merge gate for every row:** lint, warnings, full gdUnit, demo smoke and the existing seven process scenarios. Keep old compatibility cases alongside new world cases. The stored reports contain a 372-test run and a later focused 28-test run, both green. They are historical evidence. This research ran detached headless probes, not the suite, a rendered playtest or a live network session. `reports/report_143/results.xml:2`, `reports/report_144/results.xml:2`, `tools/check.sh:14–21,49–81`, `tools/check_multiplayer.py:933–949`, `.github/workflows/checks.yml:43–57`.

| Stage | Batches and principal files | Automated acceptance | Manual check |
| --- | --- | --- | --- |
| **WS0 — fixtures and measurements · S** | A: add a translated two-sector fixture and isolated per-peer world wrapper under `tests/levels/` and `tests/net/`. B: extend `tools/check_multiplayer.py` and add the detached/activation benchmark. | Existing scenarios pass. Record whole-Lab load, instantiate, tree entry and physics-ready separately. Two test peers have distinct spaces. Two sectors of one new fixture share one space. | Profile Lab cold/warm on a rendered client and one-vCPU headless server. |
| **WS1 — world contract and authoring · M** | A: new world, catalog and sector types in `SceneManagement/`, stable local IDs and placement metadata. B: validator and neighbour preview in `cogito_plugin.gd`. Depends on WS0. | Reject duplicate IDs, ambiguous ownership, invalid range and unresolved references. Accept nested floors and repeated prefab placements with distinct IDs. Preview/save produces no neighbour changes. | Place an outdoor tile and two stacked floors, edit one with neighbours visible. |
| **WS2 — shared-space residency · L** | A: streamer, source sets, threaded resource queue and per-frame chunk activation. B: ready frontier, common nav map and listener zones. Use a read-only fixture with default state. Depends on WS1. | Hysteresis, stale jobs, failed loads, fast motion, shared collision/rays and two-way nav pass. One-sector resident mode stops scheduling. Enforce per-chunk timing on the benchmark runner. | Sprint, reverse, drive and follow an NPC across a deliberately slow seam. |
| **WS3 — identity and owned capture · M** | A: adapt `cogito_level`, `cogito_persistent_id`, `cogito_persist_nodes`, `cogito_scene_persistence`, `cogito_scene_state`. B: split group queries, apply scoped registration and deferred restore. Depends on WS1–2. | Save A excludes B and players. Distinct authored IDs, component paths, null/empty manifests and stale deferred restore survive unload/reload. | Rename a crate using an override, reload beside a sector with the same authored prefab. |
| **WS4 — ownership transfers · L** | A: world dynamic registry, transfer barrier, home suppression and world allocator. B: adapt NPC/body, carry/seat, drop, corpse/bag archetype and flight ownership in the two-sector fixture. Depends on WS3. | A → B → A, unload of birth sector, source-only/destination-only restore, moving assembly and projectile impact each yield one live entity and one owner. Timers freeze. | Drag a corpse, throw a body and lead an NPC across the seam, then revisit its home. |
| **WS5 — generation layout and writer · L** | A: layout-2 dispatch, immutable member store, clean digest reuse and layout-1 reader in `cogito_world_files`, `cogito_slot_storage`. B: adapt `net_persistence`, `net_world_write`, `net_profiles`, profile tools and dirty tracking. Depends on WS3–4. | One-tick transfer/save, zero residents, first unload before first save, re-entry during write, failure/retry, stop, rebind and GC all preserve a verified generation. In a 1,000-sector fixture a one-sector edit writes one sector payload. | Stop during staging, restart with disconnected profiles and inspect bytes and timings. |
| **WS6 — solo slots and migration · L** | A: route menu New/Save/Load/death through the world and retain the full Advanced profile. B: 1.3 demo mapping, supported binary/v2 readers and `net_solo_import` conversion. Depends on WS5. | Golden saves for each active room and both visited, moved/removed items, seat/swim, NPC, personal/shared quests and broken v2. Verify source bytes, translated Lab pose, working state and slot history on failure. | Load real 1.3 Lobby and Lab copies, save a new slot, reload after death and explicitly import into MP. |
| **WS7 — session and player interest · L** | A: bind one world in `cogito_net`, `net_players`, `net_session`, `net_config`, dedicated/menu bootstrap. B: per-peer offers/readiness, avatar visibility, world-space spawn, respawn and reconnect policies. Depends on WS2, WS4–5. | Two clients split/rejoin with stable lives, no global reset, private data leak or duplicate actor. A slow client blocks only its own boundary. Reconnect loads saved-sector collision before placement. | Run listen and dedicated with the host stationary and another player moving away. |
| **WS8 — sector baselines and interactions · L** | A: incrementally bind `net_entities`, `net_world_state`, `net_spawner`, chunk/ack queues and transfer revisions. B: adapt actions, interactions, devices, containers, inventory and linked displays. Depends on WS7. | Stale or reordered traffic after unload/re-entry and A → B → A cannot mutate the new owner. Adjacent door works by ray/reach. Late join sees current stock, tombstones and spinner position silently. | Join during a move and while a second player operates a Lab device. |
| **WS9 — spatial gameplay streams · L** | A: adapt bodies, carry, seats, projectiles and combat events. B: NPC perception/listeners, elements, quest receipts and world uniqueness. Depends on WS8. | Across a seam get one contact/hit, one drop, correct holder, sight/hearing, element tick and quest award. Distant private/UI state stays private. Crossing during baseline or death is silent on re-entry. | Carry and shoot across the doorway, burn a prop outside observer interest, complete a quest with the other player far away. |
| **WS10 — connect the demo · M** | A: convert both demo scenes, cut corridor, bake nav, extract measured chunks and author lighting/audio zones. B: switch settings, smoke and four Lab fixtures, deprecate legacy entry points and update user guides. Depends on WS6 and WS9. | Main menu, solo and both MP topologies start the same definition. Walk between rooms without an actor replacement or load screen. Existing Lab mechanics and both legacy save mappings pass. | Walk both directions, inspect lighting/audio, patrols and shadows. Play the range, element stands, laptop delivery and archive. |
| **WS11 — scale, precision and release gates · M** | A: one-vCPU, dispersed-client, ±8 km and large-save scenarios in `tools/` and `tests/`. B: publish measured budgets and revise `docs/networking.md`, `docs/levels.md`, `docs/saves.md`, `docs/save-format.md` and the MP plan. Depends on WS10. | Bound frame/tick tails and queues under the declared roster. Old packets, write faults and failed sector loads recover. Exported artifacts traverse, save, restart and reconnect. | Run the outdoor benchmark and compact demo on target client hardware and an exported dedicated build. |

**Fixture changes.** There are 51 direct `bind_level`/`load_level`/`unload_level` references in 14 test scripts, plus 77 `current_scene` references in 25 test scripts. Some install or clean up a test's root, which remains legitimate. Change the fixture contract before bulk-renaming assertions.

- `tests/levels/level_instances_test.gd:15–50,53–85,88–138,190–247` currently expects identical `level:Crate` IDs and isolated physics/navigation. Keep that coverage for separate worlds and legacy lookup. Add shared-space contact, hearing and nav assertions for adjacent sectors, and sector-local capture/deferred-restore assertions within that world.
- `tests/net/memory_session_suite.gd:39–51,78–98` should build one isolated world **per branch**, with one or more sectors inside it. Preserve distinct `SceneMultiplayer` roots. Keep `tests/net/process_arena.gd:109` as a one-sector world fixture. Add a second translated arena and an optional slow-activation barrier.
- Port movement/interest, stale epoch and adapter tests through the new session entry. Preserve rejection tests, interpolation, authority-only gameplay and owner-private UI. Extend `tests/net/net_entities_test.gd:10–59`, `tests/net/net_movement_test.gd:19–93`, `tests/net/net_elements_test.gd:76–149`, `tests/net/net_npc_test.gd:120–200` and the existing body, physics-action, survival, inventory and wield suites.
- Four fixtures load the actual Laboratory path: `tests/net/net_lab_devices_test.gd:3–34`, `tests/net/net_elements_lab_test.gd:3–32`, `tests/net/net_quests_lab_test.gd:3–57`, `tests/net/net_persistence_lab_test.gd:3–66`. Supply a world wrapper and Lab-local helper for test positions and component paths. Exercise at least one non-identity placement. Keep the authored range, knob, digits, stands and restart assertions.
- Extend `tests/net/net_world_restart_test.gd:69–182,228–300,339–403` from empty secondary levels to **occupied, then frozen** sectors. Keep `tests/saves/world_files_test.gd:34–119`, `world_import_test.gd:16–63`, `persist_compat_test.gd:21–58` and `load_failure_test.gd:88–116,159–192`. Update `tests/saves/real_slot_check.gd:67–72` to assert world plus owner sector. Keep `tests/saves/transition_level.tscn:6–14` as a 1.x compatibility fixture.
- Replace direct room smoke boots with menu, connected world and focused sector-wrapper boots. Add split, converge, late join, dormant reconnect, migration during write and slow-client scenarios to the seven delivered process scenarios. Use deterministic barriers and independent user directories. `tools/check.sh:16–21,49–81`, `tools/check_multiplayer.py:822–827,933–949`.

**MP plan edits.** Mark the earlier “Levels” row and “Consequences of independent travel” as historical. Update sections 1–4 where they prescribe one active level, same-level observers, one viewport per level or travel readiness. Keep MP0b and MP1–MP9 as delivered history with links to their WS adaptations. Replace MP10's XL coordinator row and risk row with a delivery reference to WS0–WS11 and the split/converge/restart test. `docs/dev/multiplayer-plan.md:20,27–45,162–170,190–219,245–257,273`.

Keep **MP11 · M** for Host/Join UI, solo-import UI, exported dedicated bootstrap/config and operator documentation. Its UI selects a world and entry, shows initial boot/admission progress, and handles cancellation or a failed join. Its release gate consumes the connected demo and WS11 performance results. Keep `--world` for named saves and document the content option and legacy CLI mapping. `docs/dev/multiplayer-plan.md:26,221–229,258–260,274`.

## 10. Maintainer choices and recommended defaults

| Choice or risk | Recommended default and sign-off |
| --- | --- |
| Authoring grid versus volumes | Authored 3D ownership volumes with a spatial hash. Start outdoor examples at 128 m. Demonstrate two floors at the same X/Z and a one-sector building. |
| Residency and an outrun client | Start with 112/144 m, 5 s grace, velocity prefetch and a per-actor safe frontier. Tune from cold p99. A slow peer must not pause another. |
| Budget and content granularity | Start at 2 ms main-thread streaming work. Split indivisible chunks that exceed it. Require rendered and one-vCPU profiles before publishing limits. |
| Save cost and immutable storage | Adopt layout 2 with digest-addressed members, verified manifests and bounded cold-record caching. Keep full recovery validation and measure its read cost. |
| Identity, compact seams and frozen dependencies | Use world-unique birth IDs, one owner at a tick, explicit synchronous pins and deferred durable references. Test unloading an authored object's home before its destination. |
| Respawn, unknown legacy worlds and future precision | Default to death/saved sector, then world entry. Require explicit mappings for unknown multi-room saves. Keep precision/build compatibility versioned. |
| Demo placement and visual scope | Use the 31 m corridor and identity rotations. Approve after collision/nav and lighting playtests. Defer HLOD, teleport doors and off-screen simulation until a game needs them. |
| Capacity on one vCPU | Publish measured roster, awake bodies, loaded sectors and p99 tick cost. Use configuration and admission limits derived from that result. ENet's ceiling is a transport limit. `Networking/net_config.gd:5–9,44–54`. |
