extends CogitoFlag
class_name PlayerFlag

## Player expressions with required arguments
enum PlayerEx {
	## Does the player have this inventory item? [String]
	HAS_INV_ITEM,
	## Does the player have this attribute of at least X value? [String, Int]
	ATTRIBUTE_VALUE_AT_LEAST
}

## What expression does the player need to have
@export var expression: PlayerEx = PlayerEx.HAS_INV_ITEM
## Arguments for the expression.
@export var arguments: Array[Variant] = []

var player: CogitoPlayer

## Quest flags are not used for this method, instead this flag checks against a player expression.
func check(_flags: Dictionary) -> bool:
	## Find the global ref to the player if not present
	if not player:
		player = CogitoSceneManager._current_player_node
	
	assert(len(arguments) >= 1, "Arguments should be present when checking player expression")
	match expression:
		PlayerEx.HAS_INV_ITEM:
			return player.inventory_data.find_slots(arguments[0]) != []
		PlayerEx.ATTRIBUTE_VALUE_AT_LEAST:
			return player.player_attributes.get(arguments[0], -1) > arguments[1]
		_:
			return true
