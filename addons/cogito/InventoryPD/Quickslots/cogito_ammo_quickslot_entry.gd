extends CogitoQuickslotEntry
class_name CogitoAmmoQuickslotEntry

## Quickslot entry for one ammo type of an equipped wieldable (see CogitoWieldable.get_quickslot_set()).
## Shows the ammo icon, name and how much of it is in the inventory. Activating it switches the wieldable
## to exactly this ammo type with CogitoWieldable.change_ammo_to() (same rules as changing ammo with the reload/ammo key).

## The wieldable node whose ammo type this entry switches to.
var wieldable : CogitoWieldable
## Index into wieldable.item_reference.ammo_types.
var ammo_index : int = -1


func _init(passed_wieldable: CogitoWieldable = null, passed_ammo_index: int = -1) -> void:
	wieldable = passed_wieldable
	ammo_index = passed_ammo_index


## Builds a set with one entry per ammo type of the wieldable's item, with the current ammo type selected.
static func create_set(passed_wieldable: CogitoWieldable) -> CogitoQuickslotSet:
	var ammo_set := CogitoQuickslotSet.new()
	var item := passed_wieldable.item_reference
	ammo_set.display_name = item.name
	ammo_set.resize(item.ammo_types.size())
	for i in item.ammo_types.size():
		ammo_set.bind(i, CogitoAmmoQuickslotEntry.new(passed_wieldable, i))
	ammo_set.select(item.current_ammo_type)
	return ammo_set


## The wieldable's item, null if the wieldable is gone.
func get_wieldable_item() -> WieldableItemPD:
	if !is_instance_valid(wieldable):
		return null
	return wieldable.item_reference


func get_ammo() -> AmmoItemPD:
	var item := get_wieldable_item()
	if !item or ammo_index < 0 or ammo_index >= item.ammo_types.size():
		return null
	return item.ammo_types[ammo_index]


## True if this is the ammo type the wieldable currently uses.
func is_current() -> bool:
	var item := get_wieldable_item()
	return item != null and item.current_ammo_type == ammo_index


func get_icon() -> Texture2D:
	var ammo := get_ammo()
	if !ammo or !ammo.icon:
		return null
	return ammo.square_icon


func get_display_name() -> String:
	var ammo := get_ammo()
	return ammo.name if ammo else ""


## Amount of this ammo in the player inventory.
func get_count() -> int:
	var ammo := get_ammo()
	var item := get_wieldable_item()
	if !ammo or !item.player_interaction_component:
		return 0
	return item.get_item_amount_in_inventory(ammo)


## Available if there is ammo of this type in the inventory, or it is the current type.
func is_available() -> bool:
	return is_current() or get_count() > 0


## Switches the wieldable to this ammo type. Activating the current type does nothing and returns false.
func activate(_context: Object) -> bool:
	if !get_ammo() or is_current():
		return false
	return wieldable.change_ammo_to(ammo_index)
