extends CogitoQuickslotEntry
class_name CogitoItemQuickslotEntry

## Quickslot entry for an inventory item stack (InventorySlotPD).
## Activating it uses the item from the inventory, it shows the stack amount
## and it expires once the stack runs out. Its submenu is the item's own set (InventoryItemPD.get_quickslot_set()),
## for example the ammo types of a toy pistol, whether the item is equipped or not.

## The inventory slot this entry points to.
var slot_data : InventorySlotPD:
	set(value):
		if slot_data and slot_data.stack_has_changed.is_connected(emit_changed):
			slot_data.stack_has_changed.disconnect(emit_changed)
		slot_data = value
		if slot_data and !slot_data.stack_has_changed.is_connected(emit_changed):
			slot_data.stack_has_changed.connect(emit_changed)
		emit_changed()

## The inventory that is used when this entry gets activated.
var inventory : CogitoInventory


func _init(passed_slot_data: InventorySlotPD = null, passed_inventory: CogitoInventory = null) -> void:
	inventory = passed_inventory
	slot_data = passed_slot_data


func get_item() -> InventoryItemPD:
	if !slot_data:
		return null
	return slot_data.inventory_item


func get_icon() -> Texture2D:
	var item := get_item()
	if !item or !item.icon:
		return null
	return item.square_icon


func get_display_name() -> String:
	var item := get_item()
	return item.name if item else ""


## Only stacks bigger than 1 show a counter.
func get_count() -> int:
	if slot_data and slot_data.quantity > 1:
		return slot_data.quantity
	return -1


func is_expired() -> bool:
	return !slot_data or slot_data.quantity < 1


## The item's quickslot set (InventoryItemPD.get_quickslot_set()), or null.
func get_submenu() -> CogitoQuickslotSet:
	var item := get_item()
	if !item:
		return null
	return item.get_quickslot_set(_get_player_interaction_component())


func activate(_context: Object) -> bool:
	if !slot_data or !inventory:
		return false
	inventory.use_slot_data(slot_data.origin_index)
	return true


# The inventory belongs to the player (CogitoInventory.owner), items need its interaction component for their sets.
func _get_player_interaction_component() -> PlayerInteractionComponent:
	if !inventory or !is_instance_valid(inventory.owner):
		return null
	return inventory.owner.get("player_interaction_component") as PlayerInteractionComponent
