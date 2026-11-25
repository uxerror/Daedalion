extends InventoryItemPD
class_name CurrencyItemPD

@export_group("Currency Item settings")
## Name of attribute that the item is going to replenish. (For example "health")
@export var currency_name : String
## The change amount that gets applied to the attribute. (For example 25 to heal 25 HP. Allows negative values too.)
@export var currency_change_amount : float

## If checked, the item will be added to the player's currency on pickup. If false, it will be added to inventry instead and can be "used" to be added to the currency pool.
@export var add_on_pickup : bool = true

func use(target) -> bool:
	# Target should always be player? Null check to override using the CogitoSceneManager, which stores a reference to current player node
	if CogitoNet.is_online() and (not target is CogitoPlayer or not target.multiplayer.is_server()):
		return false
	if target == null or target.is_in_group("external_inventory"):
		CogitoGlobals.debug_log(true, "CurrencyItemPD", "Bad target pass. Setting target to" + str(CogitoSceneManager.get_player()) )
		target = CogitoSceneManager.get_player()
		
	if target is CogitoPlayer and target.network_movement_only:
		var wallet: CogitoCurrency = target.player_currencies.get(currency_name)
		if not wallet or wallet.is_locked:
			return false
		var total := wallet.value_current + currency_change_amount
		if total < 0 or total > wallet.value_max:
			return false
	if target.increase_currency(currency_name, currency_change_amount):
		if hint_text_on_use != "":
			target.player_interaction_component.send_hint(hint_icon_on_use,hint_text_on_use)
		return true
	else:
		return false


# Using method to enable other scripts to check if this is an ammo item. Used in cogito_inventory.gd.
func is_currency_item():
	pass

# Function to check for consumables and reducing quantity.
func is_consumable():
	pass
