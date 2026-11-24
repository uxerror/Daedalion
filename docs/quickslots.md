Based on the Cogito wiki page How to add more Quickslots (https://codeberg.org/Phazorknight/Cogito/wiki/How-To-Add-more-QuickSlots) by Philip Drobar and contributors, MIT.

# Quickslot sets

A `CogitoQuickslotSet` holds an ordered array of entries and a selected index. An empty slot keeps its position. A `CogitoQuickslotEntry` supplies a name, icon, count, availability and an activation method. The inventory bar and radial wheel can display the same set. Inventory bindings refer to stacks in `CogitoInventory.assigned_quickslots` and survive a save and load.

## Add a fifth inventory slot

1. Open [Player_HUD.tscn](../addons/cogito/PackedScenes/Player_HUD.tscn). Under **InventoryInterface > QuickSlots**, duplicate a `CogitoQuickslotContainer`. Position it and adjust focus neighbours so you can reach it with a controller.
2. Add an action such as `quickslot_5` in **Project Settings > Input Map** and bind a key. Set the new container's `input_action` to that name. Its input icon reads the same property.
3. On QuickSlots, append the new container to `quickslot_containers`. Keep the original entries in order because saved bindings use their indices. Check that its `quickslot_pressed` signal connects to `_on_bind_grabbed_slot_to_quickslot` on InventoryInterface, like the four existing containers.
4. To expose the key in Options, add your new action and a translation key to `rebind_entries` on the active settings resource. Add translations for that key.
5. Run the level, open the inventory, pick up a stack with the cursor and click the new slot. Close the inventory and press the bound key. Older inventories get empty slots appended to fit the new bar.

`CogitoQuickslots` reads actions from the configured containers. Its default mode activates on press. The select-then-confirm mode uses `confirm_action` to activate the selected entry.

## Use the wheel

Hold `quickslot_wheel` (X or left shoulder in the default map). Point with relative mouse movement or the right stick. By default, releasing activates the highlighted entry. A marked entry can open a submenu with primary action. Back returns to its parent. A multi-ammo wieldable can offer its ammo types here. Selecting a type for a quickslotted, unequipped gun also equips that gun. The separate `change_ammo_type` action defaults to T or Misc1.

## Supply other entries and views

Extend `CogitoQuickslotEntry` and implement `activate(context)` for a spell or ability. Implement `get_icon()` and `get_display_name()` for the view. Call `emit_changed()` when its count or availability changes. Return a stable set from `get_submenu()` if the entry opens a second menu.

For an independent set, call `resize()` before `bind()`, then `select()` or `activate()` by index. Assign the set to a `CogitoQuickslotView`. A custom inventory view goes in the bar's `views` array and receives the inventory set automatically. Override `_on_slot_changed()` and `_on_selection_changed()` to redraw. Return true from `handle_quickslot_input()` when the view consumes an event. The supplied `CogitoQuickslotWheel` also uses `context_set` for the equipped wieldable. [Wheel implementation](../addons/cogito/InventoryPD/Quickslots/cogito_quickslot_wheel.gd).
