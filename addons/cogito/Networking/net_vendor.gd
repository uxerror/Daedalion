extends RefCounted
## Atomic purchase or sale of the vendor's authored product at its configured unit price.

const STOCK := preload("net_stock.gd")
const GRID := preload("net_grid.gd")


## The MP2 button supplies the resolved purchaser. No catalog, price or path comes from input.
static func trade(vendor: Node, pic: PlayerInteractionComponent, selling: bool) -> Dictionary:
	var product := STOCK.pickup_template(vendor.object_to_spawn)
	var check := vendor.currency_check as CurrencyCheck
	var wallet: CogitoCurrency = pic.player.player_currencies.get(check.currency_name)
	if not product or not wallet or wallet.is_locked or check.currency_cost < 0:
		return {"ok": false, "reason": "Vendor unavailable"}
	var price := check.currency_cost if check.apply_transaction else 0
	var inventory := pic.get_inventory()
	if selling:
		var owned: InventorySlotPD
		for slot in inventory.find_slots(product.inventory_item.name):
			if STOCK.definition(slot.inventory_item) == STOCK.definition(product.inventory_item):
				owned = slot
				break
		if not owned or wallet.value_current + price > wallet.value_max:
			return {"ok": false, "reason": "Cannot sell item"}
		GRID.spend(inventory, owned, 1)
		wallet.value_current += price
		vendor.amount_remaining += 1
	else:
		if vendor.amount_remaining <= 0 or wallet.value_current < check.currency_cost:
			var reason := "Sold out" if vendor.amount_remaining <= 0 else "Insufficient funds"
			return {"ok": false, "reason": reason}
		if GRID.insert(inventory, product, 1, false) == 0:
			return {"ok": false, "reason": "Inventory full"}
		wallet.value_current -= price
		vendor.amount_remaining -= 1
	vendor._update_vendor_state()
	check.transaction_success.emit(pic.player)
	inventory.inventory_updated.emit(inventory)
	return {"ok": true}
