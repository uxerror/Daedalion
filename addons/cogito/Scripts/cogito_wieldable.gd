@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoWieldable.svg")
extends Node3D
class_name CogitoWieldable

@export_group("General Wieldable Settings")
## Item resource that this wieldable refers to.
var item_reference : WieldableItemPD
## Visible parts of the wieldable. Used to hide/show on equip/unequip.
@export var wieldable_mesh : Node3D
## Which ammo type the Wieldable is currently using. Set by the WieldableItemPD
@export var current_ammo_type : int = 0
@export var audio_stream_player_3d: AudioStreamPlayer3D
@export var show_debug: bool = false

@export_group("Animations")
@export var animation_player: AnimationPlayer
@export var anim_equip: String = "equip"
@export var anim_unequip: String = "unequip"
@export var anim_action_primary: String = "action_primary"
@export var anim_action_secondary: String = "action_secondary"
@export var anim_reload: String = "reload"

@export_group("Quickslots")
## If true and the item has more than one ammo type, get_quickslot_set() returns one CogitoAmmoQuickslotEntry per ammo type,
## so the quickslot wheel can switch to a specific ammo type while this wieldable is equipped.
@export var ammo_quickslot_set : bool = true

var player_interaction_component : PlayerInteractionComponent
var _ammo_quickslot_set : CogitoQuickslotSet

### Every wieldable needs the following functions:
### equip(_player_interaction_component), unequip(), action_primary(), action_secondary(), reload()

func _ready():
	if !audio_stream_player_3d:
		var players: Array[Node] = find_children("", "AudioStreamPlayer3D")
		if len(players): audio_stream_player_3d = players[0]
	
	if !animation_player:
		var anim_players: Array[Node] = find_children("", "AnimationPlayer")
		if len(anim_players): animation_player = anim_players[0]
		
	if wieldable_mesh:
		wieldable_mesh.hide()


# Function called when wieldable is unequipped.
func equip(_player_interaction_component: PlayerInteractionComponent):
	animation_player.play(anim_equip)
	player_interaction_component = _player_interaction_component


# Function called when wieldable is unequipped.
func unequip():
	animation_player.play(anim_unequip)


# Primary action called by the Player Interaction Component when wieldable is wielded.
func action_primary(_passed_item_reference:InventoryItemPD, _is_released: bool):
	pass


# Secondary action called by the Player Interaction Component when wieldable is wielded.
func action_secondary(_is_released: bool):
	pass


# Function called when wieldable reload is attempted
func reload() -> bool:
	var player: CogitoPlayer = player_interaction_component.player if player_interaction_component else CogitoSceneManager._current_player_node
	var inventory: CogitoInventory = player.inventory_data
	# Some safety checks if reload should even be triggered.
	if inventory == null:
		CogitoGlobals.debug_log(true,"CogitoWieldable", "Could not get reference to player inventory!")
		return false

	if animation_player.is_playing():
		CogitoGlobals.debug_log(true,"CogitoWieldable", "Cannot reload during animation")
		return false

	# If the item doesn't use reloading, return.
	if item_reference.no_reload:
		CogitoGlobals.debug_log(true,"CogitoWieldable", "This wieldable does not do reloading!")
		return false

	var ammo_needed: int = abs(item_reference.charge_max - item_reference.charge_current)
	if ammo_needed <= 0:
		CogitoGlobals.debug_log(true,"CogitoWieldable", "Wieldable is already fully loaded")
		return false

	if item_reference.get_item_amount_in_inventory(item_reference.get_current_ammo()) <= 0:
		CogitoGlobals.debug_log(true,"CogitoWieldable", "You have no ammo for this wieldable.")
		return false

	for slot: InventorySlotPD in inventory.inventory_slots:
		if ammo_needed <= 0:
			break
		if slot == null or slot.inventory_item.name != item_reference.get_current_ammo().name:
			continue

		var ammo_used: int
		var slot_ammo: AmmoItemPD = slot.inventory_item
		var quantity_needed: int = ceili(float(ammo_needed) / slot_ammo.reload_amount)

		if slot.quantity <= quantity_needed:
			ammo_used = slot_ammo.reload_amount * slot.quantity
			inventory.remove_slot_data(slot)
		elif slot.quantity > quantity_needed:
			ammo_used = slot_ammo.reload_amount * quantity_needed
			slot.quantity -= quantity_needed

		item_reference.add(ammo_used)
		ammo_needed -= ammo_used

	inventory.inventory_updated.emit(inventory)
	item_reference.update_wieldable_data(player_interaction_component)
	return true

# Function called when wieldable ammo change is attempted
func change_ammo():
	pass
	
func set_ammo_type(index: int) -> void:
	pass


## Switches to exactly the ammo type at index of item_reference.ammo_types (used by CogitoAmmoQuickslotEntry).
## Blocked while an animation plays. Returns true if the ammo type changed.
## Override this if your wieldable changes ammo differently.
func change_ammo_to(index: int) -> bool:
	if animation_player and animation_player.is_playing():
		player_interaction_component.send_hint(null, tr("HINT_ammo_change_blocked"))
		return false
	if !item_reference.switch_to_ammo_type(index):
		return false
	apply_current_ammo_type()
	return true


## Applies item_reference.current_ammo_type to this node after the item switched ammo types, then reloads.
func apply_current_ammo_type() -> void:
	set_ammo_type(item_reference.current_ammo_type)
	item_reference.update_wieldable_data(player_interaction_component)
	reload()
	_refresh_ammo_quickslot_set()
	if _ammo_quickslot_set:
		_ammo_quickslot_set.select(item_reference.current_ammo_type)


## Virtual: the quickslot set this wieldable offers while it is equipped (fire modes, ammo types, spells...), or null for none.
## CogitoQuickslots gives it to views with shows_wieldable_set as their context set: the quickslot wheel offers it as a
## submenu next to the inventory quickslots (and opens in it, see CogitoQuickslotWheel.open_in_wieldable_set). The quickslot bar doesn't change.
## Entries get the same activation context as inventory entries (the player node), so they can reach
## player.player_interaction_component and its equipped_wieldable_node / equipped_wieldable_item.
## It gets asked once the wieldable is equipped, entries should call emit_changed() when their data changes.
## By default this returns one entry per ammo type if the item has more than one (see ammo_quickslot_set).
func get_quickslot_set() -> CogitoQuickslotSet:
	if !ammo_quickslot_set or !item_reference or item_reference.ammo_types.size() <= 1:
		return null
	if !_ammo_quickslot_set:
		_ammo_quickslot_set = CogitoAmmoQuickslotEntry.create_set(self)
		# Ammo counts follow the inventory. Connected to this node, so it disconnects when the node gets freed on unequip.
		var inventory : CogitoInventory = player_interaction_component.get_inventory() if player_interaction_component else null
		if inventory and !inventory.inventory_updated.is_connected(_on_ammo_inventory_updated):
			inventory.inventory_updated.connect(_on_ammo_inventory_updated)
	return _ammo_quickslot_set


# Refreshes the ammo entries (counts, availability). Doesn't touch the selection, the wheel may be hovering a slot.
func _refresh_ammo_quickslot_set() -> void:
	if !_ammo_quickslot_set:
		return
	for i in _ammo_quickslot_set.size():
		var entry := _ammo_quickslot_set.get_entry(i)
		if entry:
			entry.emit_changed()


func _on_ammo_inventory_updated(_inventory: CogitoInventory) -> void:
	_refresh_ammo_quickslot_set()
	
# Override this with your debug stats
func debug(id, data):
	if player_interaction_component:
		player_interaction_component.player.debug(id, data)
