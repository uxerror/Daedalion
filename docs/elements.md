# Elements

A fire can damage a crate, ignite it, or do both. Damage changes health. Exposure builds an element level until the target changes state. Keep the two values separate when authoring an effect.

## Give a prop an elemental response

Instance [CogitoProperties.tscn](../addons/cogito/Components/Properties/CogitoProperties.tscn) under a `CogitoObject`. The scene includes the timers its script uses. Enable flammability in `elemental_properties` for a crate that can burn. Set `fuel` to give the fire a finite duration, choose a `burn_out_result` and set `heat_radius` if it should heat nearby targets. Resistance scales buildup and typed damage. A resistance of 100 grants immunity and a negative value makes the target more susceptible.

| Exposure | Response |
| --- | --- |
| Fire | Heats a flammable prop until it ignites. Heat first thaws ice or dries temporary wetness. Spent fuel can extinguish, char or destroy the prop. |
| Water | Douses a burning prop and can leave it wet. Wet targets take extra shock damage. |
| Shock | Can electrify a conductive or wet prop. A conducting volume can expose other occupants to shock. |
| Cold | Chills a dry target or freezes a wet one. Sufficient cold quenches fire. Heat can thaw the target. |
| Poison | Buildup can cause poisoning. The target takes periodic damage until the poison expires or is cured. |

For a scripted effect, use `CogitoProperties.apply_element_to()` for exposure and `CogitoProperties.deal_elemental_damage()` for immediate damage. For example, this applies water to a target before applying cold. The amounts needed depend on its thresholds and resistance.

```gdscript
func chill_wet_target(target: Node3D) -> void:
    CogitoProperties.apply_element_to(target, CogitoProperties.Element.WATER, 2.0, self)
    CogitoProperties.apply_element_to(target, CogitoProperties.Element.COLD, 2.0, self)
```

For a continuous source, attach `CogitoElementArea` to an area with a collision shape. Set its mask to the layers you want to affect, its `element` and `amount_per_second`. Exposure has to outpace decay. Set `damage_per_second` independently. A fire area can be doused and reignited. Use `conducts_shock` on a puddle to shock occupants. `FluidArea3D` also supports soaking and conduction in swimming volumes.

## Players and NPCs

`CogitoActorElements` binds an actor to its properties. Chill slows movement. Freezing locks movement and can block actions. Fresh movement presses let the player struggle free. Actors can have a short period of immunity to refreezing so they can leave the cold source. NPCs can struggle automatically. Shock can stun, and an [NPC](npc.md) that catches fire runs in panic. The player signals `elemental_damage_received` with the amount, element and source.

`CogitoElementStatusHud` shows buildup and active states with icons and a screen vignette. [Saves](saves.md) restore prop states and fuel, area state and actor timers. Visuals can refresh via `element_state_restored` without applying the original hit again.

Run the [Laboratory](../addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn) to try the fire, water/shock, cold and poison stands. Their [packed scenes](../addons/cogito/DemoScenes/DemoPrefabs/ElementStands) show the collision masks, sources and target properties together.

## Multiplayer

The server runs reactions and damage even outside observer range. Players in interest see the
current area and prop visuals and other actors' status effects. Only the owning player sees
their status HUD and vignette. The Laboratory switches, DROP BALL and RESET use the same
authority path as other interactions. See the [networking guide](networking.md#elements)
for damage attribution, update rates and custom components.
