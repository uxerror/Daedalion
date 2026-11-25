extends InventoryItemPD
class_name AmmoItemPD

@export_group("Ammo settings")
## The amount one item adds to the target item charge. For bullets this should be 1.
@export var reload_amount : int = 1

# Using method to enable other scripts to check if this is an ammo item. Used in cogito_inventory.gd.
func is_ammo_item():
	pass

func use(target) -> bool:
	# Target should always be player? Null check to override using the CogitoSceneManager, which stores a reference to current player node
	if CogitoNet.is_online() and (not target is CogitoPlayer or not target.multiplayer.is_server()):
		return false
	if target == null or target.is_in_group("external_inventory"):
		CogitoGlobals.debug_log(true, "AmmoItemPD", "Bad target pass. Setting target to" + str(CogitoSceneManager.get_player()) )
		target = CogitoSceneManager.get_player()
		
	if hint_text_on_use != "":
		target.player_interaction_component.send_hint(hint_icon_on_use,hint_text_on_use)
	return true
