extends RefCounted
## Local cursor state. The grabbed preview is a copy, so dragging never removes a real stack.

const STOCK := preload("net_stock.gd")

var endpoint: Node
var source: STOCK
var origin := -1
var stack_id := 0


## Clear a drag without touching either inventory.
func cancel(ui: CogitoInventoryInterface) -> void:
	source = null
	ui.grabbed_slot_data = null
	ui.input_event = null
	ui.update_grabbed_slot()


## Convert both mouse and controller inventory bindings to bounded inventory requests.
func press(ui: CogitoInventoryInterface, data: CogitoInventory, i: int, action: String) -> void:
	var boxes: Node = endpoint.get_parent().containers
	var model: STOCK = endpoint.local if data == endpoint.local.data else boxes.local
	if not model or model.data != data:
		return
	var stack := data.inventory_slots[i]
	if not source:
		if not stack:
			return
		match action:
			"inventory_move_item", "inventory_assign_item":
				source = model
				origin = i
				stack_id = model.id_of(stack)
				ui.grabbed_slot_data = STOCK.copy_stack(stack, stack.quantity)
				if action == "inventory_assign_item":
					ui.quick_slots.quickslot_containers[0].grab_focus.call_deferred()
			"inventory_drop_item", "inventory_use_item":
				if model == endpoint.local:
					if action == "inventory_use_item":
						endpoint.submit("use", [i, model.id_of(stack)])
					else:
						endpoint.submit("drop", [i, model.id_of(stack), 1])
	elif action == "inventory_rotate_item":
		ui.rotate_item()
	elif action == "inventory_assign_item":
		cancel(ui)
	elif action in ["inventory_move_item", "inventory_use_item"]:
		var preview := ui.grabbed_slot_data
		var single := action == "inventory_use_item"
		var recipe := preview.inventory_item as CombinableItemPD
		var matches := recipe and stack and recipe.target_item_combine == stack.inventory_item.name
		if single and matches and source == endpoint.local and model == source:
			endpoint.submit("combine", [origin, stack_id, i])
		else:
			var amount := 1 if single else preview.quantity
			var args := [origin, stack_id, i, amount, int(preview.inventory_item.rotated)]
			var op := "move"
			if source != endpoint.local or model != endpoint.local:
				args.append_array([boxes.token, boxes.local.revision])
				op = "take" if model == endpoint.local else "put"
				if source == model:
					op = "external_move"
			endpoint.submit(op, args)
		cancel(ui)
	ui.update_grabbed_slot()


## Assign the preview's actual source stack.
func bind_slot(ui: CogitoInventoryInterface, index: int) -> void:
	if source == endpoint.local:
		endpoint.submit("bind", [origin, stack_id, index])
	cancel(ui)


## Drop from the player's original cell after an outside click.
func drop(ui: CogitoInventoryInterface) -> void:
	if source == endpoint.local:
		endpoint.submit("drop", [origin, stack_id, 1])
	cancel(ui)


## Send viewer token and external revision for take-all and close.
func external(op: String) -> void:
	var boxes: Node = endpoint.get_parent().containers
	if boxes.local and boxes.token:
		endpoint.submit(op, [boxes.token, boxes.local.revision])
		if op == "close":
			boxes.local = null
			boxes.token = 0
