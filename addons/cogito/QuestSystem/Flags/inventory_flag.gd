## Checks to see that the player has this item in their inventory
extends CogitoFlag
class_name InventoryFlag

## Expected item to be in the players inventory
@export var expected_item: InventoryItemPD

## Quest flags are not used for this method, instead this flag checks against the current player's inventory.
func check(_flags: Dictionary) -> bool:
	# Look the player up every time: a cached one is freed when the scene changes.
	if CogitoNet.is_online():
		return false
	var player := CogitoSceneManager.get_player()
	if not player or not player.inventory_data or not expected_item:
		return false
	return not player.inventory_data.find_slots(expected_item.name).is_empty()


func check_in_context(flags: Dictionary, context: CogitoQuestContext) -> bool:
	return context.holds(expected_item) if context else check(flags)
