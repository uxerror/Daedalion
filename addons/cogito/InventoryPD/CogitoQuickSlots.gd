extends CogitoQuickslotView
class_name CogitoQuickslots

## Coordinates the player's quickslots: owns the inventory quickslot set, handles quickslot input
## and displays the set with its quickslot containers (the default quickslot bar).
## The number of quickslots equals the number of quickslot_containers, each container's input_action activates it.
## The bindings are stored in CogitoInventory.assigned_quickslots, which is what gets saved.
### This script directly references the player inventory a lot, so make sure that reference is set correctly before using.

enum SlotInputMode {
	## Pressing a quickslot action activates the slot right away.
	ACTIVATE_ON_PRESS,
	## Pressing a quickslot action selects the slot, confirm_action activates the selected slot.
	SELECT_THEN_CONFIRM,
}

## If true, the player can assign the same item to multiple quickslots.
@export var allow_multiple_quickslot_binds : bool = true
## When multiple wieldables are quickslotted, cycling will unequip the last wieldable found before cycling back to the first wieldable found
@export var allow_unequip_when_cycling_wieldables: bool = true
## One container per quickslot. Each container's input_action activates its quickslot.
@export var quickslot_containers : Array[CogitoQuickslotContainer]
var player_interaction_component: PlayerInteractionComponent

@export var inventory_reference : CogitoInventory:
	set(passed_inventory):
		if inventory_reference and inventory_reference != passed_inventory:
			_disconnect_inventory_signals(inventory_reference)
		inventory_reference = passed_inventory
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Inventory reference (re)set!")
		
		# Connecting unbind signal from inventory
		if !inventory_reference.unbind_quickslot_by_index.is_connected(on_unbind_quickslot_by_index):
			inventory_reference.unbind_quickslot_by_index.connect(on_unbind_quickslot_by_index)
		if !inventory_reference.picked_up_new_inventory_item.is_connected(on_auto_quickslot_new_item):
			inventory_reference.picked_up_new_inventory_item.connect(on_auto_quickslot_new_item)
		
		set_inventory_quickslots(inventory_reference)
		
@export_group("Input")
## ACTIVATE_ON_PRESS: quickslot actions activate their slot. SELECT_THEN_CONFIRM: they select it and confirm_action activates it.
@export var slot_input_mode : SlotInputMode = SlotInputMode.ACTIVATE_ON_PRESS
## Activates the selected quickslot when slot_input_mode is SELECT_THEN_CONFIRM.
@export var confirm_action : String = ""
## Equips the previous quickslotted wieldable.
@export var previous_wieldable_action : String = "quickslot_prev_wieldable"
## Equips the next quickslotted wieldable.
@export var next_wieldable_action : String = "quickslot_next_wieldable"
@export_group("")
## Additional views (for example a CogitoQuickslotWheel) that display a quickslot set (see get_view_set()).
## They get the player's quickslot input first through CogitoQuickslotView.handle_quickslot_input().
@export var views : Array[CogitoQuickslotView]

## The quickslot set of the player inventory, displayed by this node's containers.
var inventory_set : CogitoQuickslotSet = CogitoQuickslotSet.new()
var inventory_is_open : bool


func _init() -> void:
	inventory_set.slot_changed.connect(_store_assigned_quickslot)
	quickslot_set = inventory_set


func _ready() -> void:
	# Connecting to unbind signal to enabling clearing of inventory slot reference on unbind.
	for quickslot in quickslot_containers:
		quickslot.quickslot_cleared.connect(unbind_quickslot)
		if quickslot.input_action != "" and !InputMap.has_action(quickslot.input_action):
			push_warning("CogitoQuickSlots: Input action '" + quickslot.input_action + "' of " + quickslot.name + " doesn't exist in the Input Map, this quickslot can't be activated.")

	inventory_set.resize(quickslot_containers.size())
	refresh_view_sets()
	
	set_quickslot_focus(false) # Setting focus mode on quickslots to NONE on ready.
	
	await get_tree().process_frame
	var player := CogitoSceneManager._current_player_node as CogitoPlayer
	if player:
		player_interaction_component = player.player_interaction_component


# Using this to either set up new inventory or load quickslot of existing inventory
func set_inventory_quickslots(passed_inventory: CogitoInventory) -> void:
	if passed_inventory.assigned_quickslots.is_empty():
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "set_inventory_quickslots: assigned_quickslots were empty.")
	else:
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "set_inventory_quickslots: assigned_quickslots were NOT empty, updating quickslot data...")
	on_inventory_updated(passed_inventory)


## Rebuilds the inventory quickslot set from the inventory's assigned_quickslots.
func on_inventory_updated(passed_inv: CogitoInventory) -> void:
	CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "on_inventory_updated called.")
	# One assigned quickslot per container. Saves with fewer quickslots get padded with empty slots.
	passed_inv.assigned_quickslots.resize(quickslot_containers.size())
	inventory_set.resize(quickslot_containers.size())
	for i in quickslot_containers.size():
		var slot_data : InventorySlotPD = passed_inv.assigned_quickslots[i]
		inventory_set.bind(i, CogitoItemQuickslotEntry.new(slot_data, passed_inv) if slot_data else null)


func unbind_quickslot(quickslot_to_unbind: CogitoQuickslotContainer) -> void:
	# Finding the passed quickslot in the containers and saving it's index.
	var slot_index : int = quickslot_containers.find(quickslot_to_unbind, 0)
	
	if slot_index != -1:
		inventory_set.unbind(slot_index)
	else:
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "quickslot wasn't found in the quickslot_container array.")


func on_unbind_quickslot_by_index(passed_index: int) -> void:
	if passed_index != -1:
		inventory_set.unbind(passed_index)


func bind_to_quickslot(itemslot_to_bind: InventorySlotPD, quickslot_to_bind: CogitoQuickslotContainer):
	var slot_index : int = quickslot_containers.find(quickslot_to_bind, 0)
	
	if slot_index > -1:
		if !allow_multiple_quickslot_binds:
			unbind_itemslot_from_quickslots(itemslot_to_bind)
		inventory_set.bind(slot_index, CogitoItemQuickslotEntry.new(itemslot_to_bind, inventory_reference))
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Assigned quickslot " + str(slot_index) + " to " + itemslot_to_bind.inventory_item.name )
	else:
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "quickslot wasn't found in the quickslot_container array.")


func unbind_itemslot_from_quickslots(itemslot_to_unbind: InventorySlotPD):
	for i in inventory_set.size():
		var item_entry := inventory_set.get_entry(i) as CogitoItemQuickslotEntry
		if item_entry and item_entry.slot_data == itemslot_to_unbind:
			inventory_set.unbind(i)


func on_input(event: InputEvent) -> void:
	if !self.visible:
		return
	
	if inventory_is_open:
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Inventory is open, no item used.")
		return
	
	for view in views:
		if view and view.handle_quickslot_input(event, _get_activation_context()):
			return
	
	for i in quickslot_containers.size():
		var action : String = quickslot_containers[i].input_action
		if action == "" or !InputMap.has_action(action) or !event.is_action_released(action):
			continue
		if !inventory_set.get_entry(i):
			CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Nothing assigned in quickslot " + str(i + 1) + "...")
			return
		if slot_input_mode == SlotInputMode.SELECT_THEN_CONFIRM:
			CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Selecting quickslot " + str(i + 1) + "...")
			inventory_set.select(i)
		else:
			CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Using quickslot " + str(i + 1) + "...")
			inventory_set.activate(i, _get_activation_context())
		return
	
	if slot_input_mode == SlotInputMode.SELECT_THEN_CONFIRM and _is_action_released(event, confirm_action):
		inventory_set.activate_selected(_get_activation_context())
		return
	
	# This can get called before assigning the reference, such as when loading, so check if player_interaction_component is null first
	if player_interaction_component and player_interaction_component.can_cycle_quickslots:
		if _is_action_released(event, previous_wieldable_action):
			_cycle_through_quickslotted_wieldables(false)
		elif _is_action_released(event, next_wieldable_action):
			_cycle_through_quickslotted_wieldables(true)


## Returns the set a view displays. By default every view displays the inventory set.
## Extend this to show another set in a view, for example a wieldable's own set in the wheel, and call refresh_view_sets().
func get_view_set(_view: CogitoQuickslotView) -> CogitoQuickslotSet:
	return inventory_set


## Gives every view the set returned by get_view_set().
func refresh_view_sets() -> void:
	for view in views:
		if view:
			var view_set := get_view_set(view)
			if view.quickslot_set != view_set:
				view.quickslot_set = view_set


func update_inventory_status(is_open: bool):
	inventory_is_open = is_open
	# Sets unhandled key input to the opposite of what is_open is.
	set_process_unhandled_input(!is_open)
	set_quickslot_focus(is_open)


func on_auto_quickslot_new_item(slot_data: InventorySlotPD) -> void:
	if !slot_data.inventory_item.can_auto_slot: # Checking if this item can auto slot.
		return
	
	for i in inventory_set.size():
		var item_entry := inventory_set.get_entry(i) as CogitoItemQuickslotEntry
		if !item_entry or !item_entry.get_item():
			continue
		if item_entry.get_item().name == slot_data.inventory_item.name:
			CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", slot_data.inventory_item.name +
			" already in quickslot " + str(i))
			return
	
	for i in inventory_set.size():
		# Ensure the quickslot is empty before binding the new item
		if !inventory_set.get_entry(i):
			if slot_data.inventory_item.slot_number == -1 or slot_data.inventory_item.slot_number == i+1:
				bind_to_quickslot(slot_data, quickslot_containers[i])
				CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Auto-quickslotted " + slot_data.inventory_item.name)
				return


func set_quickslot_focus(enabled:bool) -> void:
	if enabled:
		for i in range(quickslot_containers.size()):
			quickslot_containers[i].focus_mode = Control.FOCUS_ALL
	else:
		for i in range(quickslot_containers.size()):
			quickslot_containers[i].focus_mode = Control.FOCUS_NONE
	CogitoGlobals.debug_log(true,"CogitoQuickSlots.gd", "Set quickslot containers focus_all to " + str(enabled) )


# Displays the slot in its container (CogitoQuickslotView).
func _on_slot_changed(index: int) -> void:
	if index < quickslot_containers.size():
		quickslot_containers[index].display_entry(inventory_set.get_entry(index))


# Keeps CogitoInventory.assigned_quickslots (the saved form of the inventory set) in sync with the set.
func _store_assigned_quickslot(index: int) -> void:
	if !inventory_reference:
		return
	if inventory_reference.assigned_quickslots.size() < inventory_set.size():
		inventory_reference.assigned_quickslots.resize(inventory_set.size())
	var item_entry := inventory_set.get_entry(index) as CogitoItemQuickslotEntry
	inventory_reference.assigned_quickslots[index] = item_entry.slot_data if item_entry else null


func _disconnect_inventory_signals(inventory: CogitoInventory) -> void:
	if inventory.unbind_quickslot_by_index.is_connected(on_unbind_quickslot_by_index):
		inventory.unbind_quickslot_by_index.disconnect(on_unbind_quickslot_by_index)
	if inventory.picked_up_new_inventory_item.is_connected(on_auto_quickslot_new_item):
		inventory.picked_up_new_inventory_item.disconnect(on_auto_quickslot_new_item)


func _get_activation_context() -> Object:
	return inventory_reference.owner if inventory_reference else null


func _is_action_released(event: InputEvent, action: String) -> bool:
	return action != "" and InputMap.has_action(action) and event.is_action_released(action)


func _is_wieldable_entry(entry: CogitoQuickslotEntry) -> bool:
	return entry is CogitoItemQuickslotEntry and (entry as CogitoItemQuickslotEntry).get_item() is WieldableItemPD


func _cycle_through_quickslotted_wieldables(cycle_up: bool) -> void:
	if player_interaction_component.is_changing_wieldables:
		return
		
	if player_interaction_component.is_carrying:
		CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Can't cycle wieldables while carrying.")
		return
	
	if player_interaction_component.interactable:
		for node: InteractionComponent in player_interaction_component.interactable.interaction_nodes:
			if node.input_map_action == "interact2" and not node.is_disabled:
				CogitoGlobals.debug_log(true, "CogitoQuickSlots.gd", "Looking at an interactable that" +
				" uses this input action eventdon't attempt to cycle wieldables")
				return

	_cycle_wieldables(cycle_up, player_interaction_component.equipped_wieldable_item)


func _cycle_wieldables(cycle_up: bool, current_equipped_wieldable: WieldableItemPD) -> void:
	var quickslotted_wieldable_indexes : Array[int] = inventory_set.find_indexes(_is_wieldable_entry)
	if quickslotted_wieldable_indexes.is_empty(): # No quickslotted wieldables, do nothing
		return
	
	# Select the quickslot of the currently equipped wieldable (the last one if it's quickslotted multiple times).
	var current_wieldable_quickslot_index : int = -1
	for i in quickslotted_wieldable_indexes:
		if (inventory_set.get_entry(i) as CogitoItemQuickslotEntry).get_item() == current_equipped_wieldable:
			current_wieldable_quickslot_index = i
	inventory_set.select(current_wieldable_quickslot_index)

	if current_wieldable_quickslot_index == -1: # Not wielding, equip the first/last quickslotted wieldable
		var first_index : int = inventory_set.select_next(_is_wieldable_entry) if cycle_up else inventory_set.select_previous(_is_wieldable_entry)
		inventory_set.activate(first_index, _get_activation_context())
		return

	if quickslotted_wieldable_indexes.size() == 1: # Wielding the only quickslotted wieldable, unequip it
		inventory_set.select(-1)
		current_equipped_wieldable.put_away()
		return

	# Cycle to the prev/next quickslotted wieldable. Past the last/first one, either unequip or wrap around.
	var wrap : bool = !allow_unequip_when_cycling_wieldables
	var cycle_to_index : int = inventory_set.select_next(_is_wieldable_entry, wrap) if cycle_up else inventory_set.select_previous(_is_wieldable_entry, wrap)
	if cycle_to_index == -1:
		current_equipped_wieldable.put_away()
	else:
		inventory_set.activate(cycle_to_index, _get_activation_context())
