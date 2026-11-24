Based on the Cogito wiki page Attribute System (https://codeberg.org/Phazorknight/Cogito/wiki/Attribute-System) by Philip Drobar and contributors, MIT.

# Attribute system

An attribute is a named numeric value on a node. Give a crate health, for example, or give a player stamina that drains while sprinting. Instance an attribute as a child of its owner. The player collects direct attribute children into `player_attributes` at startup and uses `attribute_name` as the key. Choose a unique lowercase name without spaces. The supplied player recognises names such as `health`, `stamina` and `visibility`.

## Define and display a value

[CogitoAttribute](../addons/cogito/Components/Attributes/cogito_attribute.gd) holds `value_start`, `value_current` and `value_max`. Set the starting value and maximum in the Inspector. Use `attribute_display_name`, `attribute_color`, `attribute_icon` and `attribute_visibility` for presentation. You can keep an attribute hidden and still use it in an interaction check.

Use `add()` or `subtract()` during play. Listen to `attribute_changed` for the name, current value, maximum and whether the change was an increase. `attribute_reached_zero` supplies the name and the two values. A health component can use zero to trigger death. A second attribute can listen for changes in the first, for example to adjust a maximum when strength changes.

## Health and stamina

`CogitoHealthAttribute` emits `damage_taken` when health decreases and `death` when it reaches zero. Use `sound_on_hit` for any hit, `sound_on_damage_taken` for a nonfatal hit and `sound_on_death` for death. Add child paths to `destroy_on_death` and packed scenes to `spawn_on_death` to replace a broken object with debris. `no_sanity_damage` sets the health cost per second when sanity is depleted.

`CogitoStaminaAttribute` exposes `run_exhaustion_speed` and `jump_exhaustion`. Set `auto_regenerate`, `stamina_regen_speed` and `regenerate_after` to control recovery. The controller can operate without its StaminaAttribute child if your game uses no stamina.

## Restore without replaying damage

`restore_attribute()` applies the saved maximum and current value with gameplay signals blocked, then emits `attribute_restored` for displays. If `dont_save_current_value` is set, the attribute keeps its current value within the restored maximum. Connect custom HUD bars to the restore notification as well as normal changes. Loading a broken object should refresh the bar without triggering another death sound or loot drop. [Save behaviour](saves.md).
