extends InventoryItemPD
class_name WieldableItemPD

# Signal that gets sent when the wiedlable charge changes. Currently used to update Slot UI
signal charge_changed()

@export_group("Wieldable settings")
@export var wieldable_scene : PackedScene
## Icon that is displayed on the HUD when item is wielded. If NULL, the item icon will be used instead.
@export var wieldable_data_icon : Texture2D
@export var wieldable_crosshair : Texture2D
## Check this if your wieldable doesn't use reload (for example melee weapons)
@export var no_reload : bool = false
## Message to display when wieldable is empty (no ammo in clip/no charge). Leave empty if you don't want to show any message.
@export var hint_on_empty: String
## The maximum charge of the item (this equals fully charged battery in a flashlight or magazine size in guns)
@export var charge_max : float
## Index of the ammo_types array that is currently selected.
@export var current_ammo_type : int
## Accepted ammo types that can be switched between
@export var ammo_types : Array[AmmoItemPD]
## Current charge of item (aka how much is in the magazine).
@export var charge_current : float
## Used for weapons
@export var wieldable_range : float
## Used for weapons
@export var wieldable_damage : float

@export_group("Hints")
## Hint that gets displayed when changing ammo types
@export var hint_changed_ammo_type : String = "HINT_changed_ammo_type"
## Hint that gets displayed when attempting to change ammo types but none are available.
@export var hint_no_other_ammo_types : String = "HINT_no_other_ammo_type"

@export_group("Quickslots")
## If true and this item has more than one ammo type, get_quickslot_set() returns one CogitoAmmoQuickslotEntry per ammo type:
## the quickslot wheel offers them as the submenu of this item's quickslot (equipped or not) and while it is equipped.
@export var ammo_quickslot_set : bool = true

var _ammo_quickslot_set : CogitoQuickslotSet
# The inventory whose changes refresh the ammo counts of _ammo_quickslot_set, null while not watching one.
var _ammo_quickslot_inventory : CogitoInventory

#var wieldable_data_text : String

func use(target) -> bool:
	# Target should always be player? Null check to override using the CogitoSceneManager, which stores a reference to current player node
	if target == null:
		CogitoGlobals.debug_log(true,"WieldableItemPD.gd", "Bad target pass. Setting target to " + CogitoSceneManager.get_player().name )
		target = CogitoSceneManager.get_player()
	# Call after assigning a null target to avoid throwing a null ref
	if target.is_in_group("external_inventory"):
		CogitoGlobals.debug_log(true,"WieldableItemPD.gd", "Can't use wieldable that is not in your inventory." )
		return false
	
	player_interaction_component = target.player_interaction_component
	if player_interaction_component.carrying.carried_object != null and !player_interaction_component.carrying.carried_object.is_carryable_while_wielding:
		# Automatically drop the carried object when selecting a wieldable via quickslot, or inventory
		if !player_interaction_component.wieldables.is_wielding:
			CogitoGlobals.debug_log(true,"WieldableItemPD.gd", player_interaction_component.name + " is dropping " + (player_interaction_component.carrying.carried_object.get_parent() as CogitoObject).cogito_name + " to take out wieldable " + name )
			player_interaction_component.wieldables.setup_wieldable_to_auto_equip(self)
			player_interaction_component.carrying.drop_carried_object()
			take_out()
			return true
		
		player_interaction_component.send_hint(null,"Can't equip item while carrying.")
		return false
	if is_being_wielded:
		CogitoGlobals.debug_log(true,"WieldableItemPD.gd", player_interaction_component.name + " is putting away wieldable " + name )
		put_away()
		return true
	else:
		CogitoGlobals.debug_log(true,"WieldableItemPD.gd", player_interaction_component.name + " is taking out wieldable " + name )
		take_out()
		return true


# Functions for WIELDABLES
func take_out():
	if player_interaction_component.wieldables.is_changing_wieldables:
		return
	
	is_being_wielded = true
	update_wieldable_data(player_interaction_component)
	player_interaction_component.wieldables.change_wieldable_to(self)


func put_away():
	if player_interaction_component.wieldables.is_changing_wieldables:
		return
	
	is_being_wielded = false
	update_wieldable_data(player_interaction_component)
	player_interaction_component.wieldables.change_wieldable_to(null)


func update_wieldable_data(_player_interaction_component : PlayerInteractionComponent):
	var current_ammo : AmmoItemPD = get_current_ammo()
	if _player_interaction_component: #Only update if something get's passed
		if is_being_wielded:
			if !no_reload:
				_player_interaction_component.updated_wieldable_data.emit(self,get_item_amount_in_inventory(current_ammo),get_ammo_item(current_ammo))
			else:
				_player_interaction_component.updated_wieldable_data.emit(self,0,null)
		else:
			_player_interaction_component.updated_wieldable_data.emit(null, 0, null)

func subtract(amount):
	charge_current -= amount
	if charge_current < 0:
		charge_current = 0
	
	if is_being_wielded:
		update_wieldable_data(player_interaction_component)
	
	charge_changed.emit()

func send_empty_hint():
	if hint_on_empty:
		player_interaction_component.send_hint(null, tr(name) + ": "+ tr(hint_on_empty) )


func add(amount):
	charge_current += amount
	if charge_current > charge_max:
		charge_current = charge_max
	
	if is_being_wielded:
		update_wieldable_data(player_interaction_component)
	charge_changed.emit()


# Function to get the AmmoItemPD
func get_ammo_item(item_to_check_for: AmmoItemPD) -> InventoryItemPD:
	var inventory = player_interaction_component.get_inventory()
	if inventory:
		var matched = inventory.find_slots(item_to_check_for.name)
		return matched.front().inventory_item if not matched.is_empty() else null
	return null

# Function to get the amount of ammo in the player inventory
func get_item_amount_in_inventory(item_to_check_for: AmmoItemPD) -> int:
	var item_count : int = 0
	var inventory = player_interaction_component.get_inventory()
	if inventory:
		for slot in inventory.find_slots(item_to_check_for.name):
			item_count += slot.quantity
	return item_count
	
# Get the current ammo for the item, if this item has no ammo types returns a null item
func get_current_ammo() -> AmmoItemPD:
	if ammo_types.is_empty():
		var null_item = AmmoItemPD.new()
		null_item.name = "null"
		return null_item
	return ammo_types[current_ammo_type]

func unload_wieldable():
	var inventory = player_interaction_component.get_inventory()
	if charge_current > 0:
		var unloaded_ammo = InventorySlotPD.new()
		unloaded_ammo.create(get_current_ammo(), int(charge_current))
		inventory.pick_up_slot_data(unloaded_ammo)
		charge_current = 0

## Attempts a switch to another available ammo type. Returns true if it was successful.
func switch_to_next_ammo_type() -> bool:
	if len(ammo_types) <= 1:
		player_interaction_component.send_hint(square_icon, "There are no other ammo types for this weapon.")
		return false
	var next_type = current_ammo_type
	for _i in range(len(ammo_types)):
		next_type = wrapi(next_type+1, 0, len(ammo_types))
		if next_type != current_ammo_type and switch_to_ammo_type(next_type):
			return true
	player_interaction_component.send_hint(square_icon, tr(hint_no_other_ammo_types) )
	return false


## Attempts a switch to the ammo type at index in ammo_types. Only works if that ammo is in the inventory
## and it isn't the current type. Unloads the current ammo into the inventory and sends the changed ammo hint.
## Returns true if it was successful. Doesn't touch the wieldable node, see CogitoWieldable.change_ammo_to().
func switch_to_ammo_type(index: int) -> bool:
	if index < 0 or index >= len(ammo_types) or index == current_ammo_type:
		return false
	var next_ammo = get_ammo_item(ammo_types[index])
	if !next_ammo:
		return false
	# Unload the Wieldable if it is currently loaded, change ammo type
	unload_wieldable()
	current_ammo_type = index
	if _ammo_quickslot_set:
		_ammo_quickslot_set.select(current_ammo_type)
	player_interaction_component.send_hint(next_ammo.square_icon, tr(hint_changed_ammo_type) + " " + tr(next_ammo.name) )
	return true


## One CogitoAmmoQuickslotEntry per ammo type if there is more than one (see ammo_quickslot_set), otherwise null.
## The set is built once per item and its counts follow the inventory of passed_player_interaction_component
## (stored as player_interaction_component, like use() does).
func get_quickslot_set(passed_player_interaction_component: PlayerInteractionComponent = null) -> CogitoQuickslotSet:
	if passed_player_interaction_component:
		player_interaction_component = passed_player_interaction_component
	if !ammo_quickslot_set or ammo_types.size() <= 1:
		return null
	if !_ammo_quickslot_set:
		_ammo_quickslot_set = CogitoAmmoQuickslotEntry.create_set(self)
	_watch_ammo_quickslot_inventory()
	return _ammo_quickslot_set


# Connects to the player inventory so the ammo counts refresh. Item resources outlive the player and their wieldable nodes,
# so the connection is dropped again once this item isn't in that inventory any more (see _on_ammo_quickslot_inventory_updated()).
func _watch_ammo_quickslot_inventory() -> void:
	var inventory : CogitoInventory = player_interaction_component.get_inventory() if is_instance_valid(player_interaction_component) else null
	if inventory == _ammo_quickslot_inventory:
		return
	_stop_watching_ammo_quickslot_inventory()
	_ammo_quickslot_inventory = inventory
	if inventory:
		inventory.inventory_updated.connect(_on_ammo_quickslot_inventory_updated)


func _stop_watching_ammo_quickslot_inventory() -> void:
	if _ammo_quickslot_inventory and _ammo_quickslot_inventory.inventory_updated.is_connected(_on_ammo_quickslot_inventory_updated):
		_ammo_quickslot_inventory.inventory_updated.disconnect(_on_ammo_quickslot_inventory_updated)
	_ammo_quickslot_inventory = null


# Refreshes the ammo entries (counts, availability). Doesn't touch the selection, the wheel may be hovering a slot.
func _on_ammo_quickslot_inventory_updated(inventory: CogitoInventory) -> void:
	if !inventory.inventory_slots.any(func(slot: InventorySlotPD) -> bool: return slot != null and slot.inventory_item == self):
		CogitoGlobals.debug_log(true, "WieldableItemPD.gd", name + " left the inventory, its ammo quickslot set stops following it.")
		_stop_watching_ammo_quickslot_inventory()
	if !_ammo_quickslot_set:
		return
	for i in _ammo_quickslot_set.size():
		var entry := _ammo_quickslot_set.get_entry(i)
		if entry:
			entry.emit_changed()

func save():
	var saved_item_data = {
		"resource" : self,
		"charge_current" : charge_current,
		"current_ammo_type" : current_ammo_type
	}
	return saved_item_data


## Restoring a magazine must not unload it, consume ammunition or send a switch hint.
func restore_charges(entry: Dictionary) -> void:
	charge_current = entry.get("charge_current", charge_current)
	var index: int = entry.get("current_ammo_type", current_ammo_type)
	current_ammo_type = index if index >= 0 and index < ammo_types.size() else 0


func build_wieldable_scene():
	var scene = wieldable_scene.instantiate()
	scene.item_reference = self
	return scene
