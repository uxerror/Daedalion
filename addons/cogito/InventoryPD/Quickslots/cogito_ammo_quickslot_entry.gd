extends CogitoQuickslotEntry
class_name CogitoAmmoQuickslotEntry

## Quickslot entry for one ammo type of a wieldable item (see WieldableItemPD.get_quickslot_set()).
## Shows the ammo icon, name and how much of it is in the inventory.
## Activating it while the item is equipped switches the wieldable to exactly this ammo type with
## CogitoWieldable.change_ammo_to() (same rules as changing ammo with the ammo key).
## Activating it while the item is not equipped switches the item to this ammo type (the loaded ammo goes back
## into the inventory) and equips the item like its quickslot does, it reloads once the equip animation is done.
## If the item can't be equipped right now (wieldables are changing, carrying something), nothing changes.

## The wieldable item whose ammo type this entry switches to. Held weakly: the item caches the set holding this entry,
## a strong reference back would keep the item alive forever (reference cycle).
var item : WieldableItemPD:
	get:
		return _item_ref.get_ref() as WieldableItemPD if _item_ref else null
	set(value):
		_item_ref = weakref(value) if value else null
var _item_ref : WeakRef
## Index into item.ammo_types.
var ammo_index : int = -1


func _init(passed_item: WieldableItemPD = null, passed_ammo_index: int = -1) -> void:
	item = passed_item
	ammo_index = passed_ammo_index


## Builds a set with one entry per ammo type of the item, with the current ammo type selected.
static func create_set(passed_item: WieldableItemPD) -> CogitoQuickslotSet:
	var ammo_set := CogitoQuickslotSet.new()
	ammo_set.display_name = passed_item.name
	ammo_set.icon = passed_item.icon
	ammo_set.resize(passed_item.ammo_types.size())
	for i in passed_item.ammo_types.size():
		ammo_set.bind(i, CogitoAmmoQuickslotEntry.new(passed_item, i))
	ammo_set.select(passed_item.current_ammo_type)
	return ammo_set


func get_ammo() -> AmmoItemPD:
	if !item or ammo_index < 0 or ammo_index >= item.ammo_types.size():
		return null
	return item.ammo_types[ammo_index]


## True if this is the ammo type the item currently uses.
func is_current() -> bool:
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
	if !ammo or !is_instance_valid(item.player_interaction_component):
		return 0
	return item.get_item_amount_in_inventory(ammo)


## Available if there is ammo of this type in the inventory, or it is the current type.
func is_available() -> bool:
	return is_current() or get_count() > 0


## Equipped: switches the wieldable to this ammo type (the current type does nothing and returns false).
## Not equipped: switches the item to this ammo type and equips it (the current type just equips it).
## Context is the player node (its player_interaction_component is used, otherwise the item's).
func activate(context: Object) -> bool:
	if !get_ammo():
		return false
	var pic := _get_player_interaction_component(context)
	if !pic:
		return false
	var wieldable := get_equipped_wieldable(pic)
	if wieldable:
		if is_current():
			return false
		return wieldable.change_ammo_to(ammo_index)
	return _equip_with_this_ammo(pic)


## The wieldable node of item if the player has it equipped, otherwise null.
func get_equipped_wieldable(pic: PlayerInteractionComponent) -> CogitoWieldable:
	var wieldable : CogitoWieldable = pic.equipped_wieldable_node
	if pic.equipped_wieldable_item != item or !is_instance_valid(wieldable) or wieldable.item_reference != item:
		return null
	return wieldable


func _equip_with_this_ammo(pic: PlayerInteractionComponent) -> bool:
	var inventory : CogitoInventory = pic.get_inventory()
	var slot := _find_item_slot(inventory)
	# Checked before switching anything, so a refused equip doesn't leave the ammo switched (same rules as WieldableItemPD.use()).
	if !slot:
		CogitoGlobals.debug_log(true, "cogito_ammo_quickslot_entry.gd", item.name + " is not in the player inventory, can't equip it.")
		return false
	if pic.is_changing_wieldables or item.is_being_wielded:
		CogitoGlobals.debug_log(true, "cogito_ammo_quickslot_entry.gd", "Wieldables are changing, not equipping " + item.name + ".")
		return false
	if pic.carried_object != null and !pic.carried_object.is_carryable_while_wielding and pic.is_wielding:
		pic.send_hint(null, "Can't equip item while carrying.")
		return false
	item.player_interaction_component = pic
	var switched := false
	if !is_current():
		if !item.switch_to_ammo_type(ammo_index):
			return false
		switched = true
	CogitoGlobals.debug_log(true, "cogito_ammo_quickslot_entry.gd", "Equipping " + item.name + " with ammo type " + str(ammo_index) + ".")
	# The same path as the item's quickslot (CogitoItemQuickslotEntry), the item builds its node with current_ammo_type.
	inventory.use_slot_data(slot.origin_index)
	if switched:
		# Like CogitoWieldable.change_ammo_to(): after switching, the wieldable reloads with the new ammo.
		_reload_when_equipped(item, pic)
	return true


func _find_item_slot(inventory: CogitoInventory) -> InventorySlotPD:
	if !inventory:
		return null
	for index in inventory.inventory_slots.size():
		var slot := inventory.inventory_slots[index]
		if slot and slot.origin_index == index and slot.inventory_item == item:
			return slot
	return null


func _get_player_interaction_component(context: Object) -> PlayerInteractionComponent:
	var pic : PlayerInteractionComponent = null
	if is_instance_valid(context):
		pic = context.get("player_interaction_component") as PlayerInteractionComponent
	if !pic and is_instance_valid(item.player_interaction_component):
		pic = item.player_interaction_component
	return pic


# Waits until the equip is done (the equip animation blocks reloading), then reloads.
# Gives up if the item gets put away or replaced in the meantime.
static func _reload_when_equipped(equipped_item: WieldableItemPD, pic: PlayerInteractionComponent) -> void:
	if !pic.is_inside_tree():
		return
	var tree := pic.get_tree()
	while is_instance_valid(pic) and equipped_item.is_being_wielded:
		var wieldable : CogitoWieldable = pic.equipped_wieldable_node
		if !pic.is_changing_wieldables and is_instance_valid(wieldable) and pic.equipped_wieldable_item == equipped_item:
			if !wieldable.animation_player or !wieldable.animation_player.is_playing():
				wieldable.reload()
				return
		await tree.process_frame
