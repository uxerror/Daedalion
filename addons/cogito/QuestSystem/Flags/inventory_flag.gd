## Checks to see that the player has this item in their inventory
extends CogitoFlag
class_name InventoryFlag

## Expected item to be in the players inventory
@export var expected_item: InventoryItemPD

var player: CogitoPlayerAdvanced

## Quest flags are not used for this method, instead this flag checks against a player expression.
func check(_flags: Dictionary) -> bool:
	## Find the global ref to the player if not present
	if not player:
		player = CogitoSceneManager._current_player_node
	return not player.inventory_data.find_slots(expected_item.name).is_empty()
