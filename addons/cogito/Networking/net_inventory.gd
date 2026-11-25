extends Node
## Reliable, owner-addressed inventory transactions. The transport sender selects the player.

signal result_received(result: Dictionary)

const STOCK := preload("net_stock.gd")
const GRID := preload("net_grid.gd")
const ACTIONS := preload("net_actions.gd")
const SCHEMAS := {
	"use": 2,
	"ammo": 3,
	"move": 5,
	"drop": 3,
	"combine": 3,
	"bind": 3,
	"unbind": 1,
	"put": 7,
	"take": 7,
	"external_move": 7,
	"take_all": 2,
	"close": 2,
}
const CACHE_LIMIT := 64

var local: STOCK
var _profiles: Dictionary[String, STOCK] = {}
var _live := {}
var _last_request := {}
var _results := {}
var _next_request := 0
var _displayed := 0
var _scan_time := 0.0
var _servicing := false
var _queue: Array[Array] = []


func _ready() -> void:
	set_physics_process(multiplayer.is_server())


func _physics_process(delta: float) -> void:
	# Legacy scripts may assign a charge, slot or wallet directly without emitting a signal.
	_scan_time += delta
	if _scan_time >= 0.2:
		_scan_time = 0.0
		for peer: int in _live:
			_refresh(peer)


## Attach before HUD setup. Retained profiles have no live node references between incarnations.
func attach(actor: CogitoPlayer, id: String, peer: int, life: int) -> void:
	actor.set_meta(&"inventory_life", life)
	var model := STOCK.new()
	model.data = actor.inventory_data
	if multiplayer.is_server():
		if _profiles.has(id):
			model = _profiles[id]
			actor.inventory_data = model.data
			_apply_currency(actor, model.snapshot.money)
		else:
			_profiles[id] = model
			model.data.assigned_quickslots.resize(actor.get_meta(&"quickslot_count"))
			for stack in CogitoGlobals.cogito_settings.new_game_starter_items:
				if stack and stack.inventory_item:
					GRID.insert(model.data, stack, stack.quantity, true)
			for stack in model.data.inventory_slots:
				if stack:
					_auto_bind(stack, model.data)
		_live[peer] = model
		model.data.inventory_updated.connect(_dirty.bind(peer))
		for currency: CogitoCurrency in actor.player_currencies.values():
			currency.currency_changed.connect(_money_changed.bind(peer))
		model.data.picked_up_new_inventory_item.connect(_auto_bind.bind(model.data))
	else:
		model.data.inventory_slots.fill(null)
	model.data.owner = actor
	if multiplayer.is_server():
		_refresh(peer)
	if actor.is_local_presentation:
		local = model
		actor.set_meta(&"inventory_endpoint", self)


func _auto_bind(stack: InventorySlotPD, inv: CogitoInventory) -> void:
	if not stack.inventory_item.can_auto_slot:
		return
	for entry in inv.assigned_quickslots:
		if entry and entry.inventory_item.name == stack.inventory_item.name:
			return
	for i in inv.assigned_quickslots.size():
		if not inv.assigned_quickslots[i] and stack.inventory_item.slot_number in [-1, i + 1]:
			inv.assigned_quickslots[i] = stack
			return


## Drop per-connection state, keeping the server model, quickslot aliases and wallet.
func detach(peer: int, actor: CogitoPlayer) -> void:
	var model: STOCK = _live.get(peer)
	if model:
		_refresh(peer, false)
		model.data.inventory_updated.disconnect(_dirty.bind(peer))
		model.data.picked_up_new_inventory_item.disconnect(_auto_bind.bind(model.data))
		model.data.owner = null
	if actor.is_local_presentation:
		local = null
	_live.erase(peer)
	_results.erase(peer)
	_last_request.erase(peer)


## Query durable holdings when rolling unique loot, including disconnected players.
func owns(item: InventoryItemPD) -> bool:
	for model in _profiles.values():
		if not model.data.find_slots(item.name).is_empty():
			return true
	return false


func _dirty(_inv: CogitoInventory, peer: int) -> void:
	_refresh.call_deferred(peer)


func _money_changed(_key: String, _value: float, _max: float, _up: bool, peer: int) -> void:
	_refresh.call_deferred(peer)


static func _values(attributes: Dictionary) -> Dictionary:
	var values := {}
	for key: String in attributes:
		var node: Node = attributes[key]
		values[key] = PackedFloat64Array([node.value_current, node.value_max])
	return values


static func _apply_currency(actor: CogitoPlayer, values: Dictionary) -> void:
	for key: String in values:
		var currency: CogitoCurrency = actor.player_currencies.get(key)
		if currency:
			currency.value_max = values[key][1]
			currency.value_current = values[key][0]


func _refresh(peer: int, publish := true) -> void:
	var model: STOCK = _live.get(peer)
	if not model:
		return
	var actor := model.data.owner as CogitoPlayer
	var extra: Dictionary = actor.get_meta(&"net_wield").private_fields(model)
	extra.money = _values(actor.player_currencies)
	var delta := model.refresh(extra)
	if delta.is_empty() or not publish:
		return
	if peer == 1 and actor.player_hud is CogitoPlayerHudManager:
		actor.player_interaction_component.wieldables.update_equipped()
		_refresh_hud(actor, model)
	if peer != 1 and get_parent().world.ready_for_events(peer) and get_parent().peer_in_level(peer):
		_state.rpc_id(peer, actor.get_meta(&"inventory_life"), model.revision, delta, false)


func _refresh_hud(actor: CogitoPlayer, model: STOCK) -> void:
	var ui := (actor.player_hud as CogitoPlayerHudManager).inventory_interface
	if ui.quick_slots.inventory_reference == model.data:
		ui.quick_slots.on_inventory_updated(model.data)
	if ui.is_inventory_open and ui.inventory_ui.loaded_inventory_data == model.data:
		ui.inventory_ui.populate_item_grid(model.data)


## Publish a synchronous MP2 transaction before the interaction result.
func flush_actor(actor: CogitoPlayer) -> void:
	_refresh(get_parent().peer_for_actor(actor))


## Join baseline sent after the MP2 level AND local avatar acknowledgement.
func baseline(peer: int) -> void:
	var model: STOCK = _live.get(peer)
	if model and peer == 1 and model.data.owner.player_hud is CogitoPlayerHudManager:
		_refresh_hud(model.data.owner, model)
	elif model and get_parent().peer_in_level(peer):
		_refresh(peer, false)
		var fields := model.snapshot.duplicate()
		fields.attributes = _values(model.data.owner.player_attributes)
		_state.rpc_id(
			peer, model.data.owner.get_meta(&"inventory_life"), model.revision, fields, true
		)


@rpc("authority", "call_remote", "reliable", 2)
func _state(life: int, revision: int, fields: Dictionary, full: bool) -> void:
	if not local or local.data.owner.get_meta(&"inventory_life") != life:
		return
	if fields.has("money"):
		_apply_currency(local.data.owner, fields.money)
	for key: String in fields.get("attributes", {}):
		var attr: CogitoAttribute = local.data.owner.player_attributes.get(key)
		if attr:
			var pair: PackedFloat64Array = fields.attributes[key]
			var blocked := attr.is_blocking_signals()
			attr.set_block_signals(true)
			attr.set_attribute(pair[0], pair[1])
			attr.set_block_signals(blocked)
			attr.attribute_restored.emit(attr.attribute_name, pair[0], pair[1])
	if fields.has("attributes") and fields.size() == 1:
		return
	local.apply(fields, revision, full)
	var slot := local.equipped_stack()
	local.data.owner.get_meta(&"net_wield").set_owner_item(slot.inventory_item if slot else null)
	var hud := local.data.owner.player_hud as CogitoPlayerHudManager
	if hud and hud.inventory_interface.quick_slots.inventory_reference == local.data:
		hud.inventory_interface.quick_slots.on_inventory_updated(local.data)


## Execute an authored use with the server-resolved actor and send private affected HUD values.
func use_item(actor: CogitoPlayer, item: InventoryItemPD) -> String:
	var peer := 0
	if is_instance_valid(actor) and multiplayer.is_server():
		peer = get_parent().peer_for_actor(actor)
	if not peer:
		return "No avatar in level"
	if item is WieldableItemPD:
		return "Select an inventory stack"
	if not item.has_method("use"):
		return "Item cannot be used"
	var before := _values(actor.player_attributes)
	if not item.use(actor):
		return "Item could not be used"
	var after := _values(actor.player_attributes)
	for key: String in before:
		if before[key] == after.get(key):
			after.erase(key)
	send_attributes(actor, after.keys())
	return ""


## Send immediate combat attribute updates through the same silent owner-only HUD path.
func send_attributes(actor: CogitoPlayer, keys: Array) -> void:
	var peer: int = get_parent().peer_for_actor(actor)
	if peer <= 1 or not get_parent().world.ready_for_events(peer):
		return
	var pairs := {}
	for key: String in keys:
		var attr: CogitoAttribute = actor.player_attributes.get(key)
		if attr:
			pairs[key] = PackedFloat64Array([attr.value_current, attr.value_max])
	if not pairs.is_empty():
		var model: STOCK = _live[peer]
		var life: int = actor.get_meta(&"inventory_life")
		_state.rpc_id(peer, life, model.revision, {"attributes": pairs}, false)


## Run an authored auto-consume on the authority after the triggering inventory commit.
func auto_consume(actor: CogitoPlayer, stack: InventorySlotPD) -> void:
	if not is_instance_valid(actor) or not multiplayer.is_server() or not actor.can_act():
		return
	var inv := actor.inventory_data
	if not stack.inventory_item is ConsumableItemPD:
		return
	if stack in inv.inventory_slots and stack.quantity > 0:
		if use_item(actor, stack.inventory_item).is_empty():
			GRID.spend(inv, stack, 1)
			inv.inventory_updated.emit(inv)


## Build a retryable request from the local observed revision.
func make_request(op: String, args: Array) -> Dictionary:
	if not local:
		return {}
	_next_request += 1
	return {
		"request_id": _next_request,
		"life": local.data.owner.get_meta(&"inventory_life"),
		"revision": local.revision,
		"op": op,
		"args": args.duplicate(),
	}


## Submit local UI input. Host and remote owners share validation and idempotency.
func submit(op: String, args: Array) -> void:
	dispatch(make_request(op, args))


## Dispatch a new envelope or retry an existing id.
func dispatch(request: Dictionary) -> void:
	if multiplayer.is_server():
		_receive(1, request)
	else:
		_command.rpc_id(1, request)


@rpc("any_peer", "call_remote", "reliable", 2)
func _command(request: Dictionary) -> void:
	if multiplayer.is_server():
		_receive(multiplayer.get_remote_sender_id(), request)


func _receive(peer: int, request: Dictionary) -> void:
	_queue.append([peer, request])
	if _servicing:
		return
	_servicing = true
	while not _queue.is_empty():
		var next: Array = _queue.pop_front()
		_process_request(next[0], next[1])
	_servicing = false


func _process_request(peer: int, req: Dictionary) -> void:
	var model: STOCK = _live.get(peer)
	if not model or not get_parent().peer_in_level(peer):
		return
	_refresh(peer)
	var id: int = req.request_id if req.get("request_id") is int else 0
	var life: int = model.data.owner.get_meta(&"inventory_life")
	var cache: Dictionary = _results.get_or_add(peer, {})
	var reason := "Invalid payload"
	if req.get("life") is int and req.life == life and id > 0:
		if cache.has(id):
			reason = cache[id]
		elif id <= int(_last_request.get(peer, 0)):
			reason = "Old request"
		else:
			_last_request[peer] = id
			reason = _evaluate(peer, model, req)
			cache[id] = reason
			if cache.size() > CACHE_LIMIT:
				cache.erase(cache.keys()[0])
	if reason != "":
		baseline(peer)
		get_parent().containers.resync(peer)
	var result := {"request_id": id, "life": life, "ok": reason == "", "reason": reason}
	if peer == 1:
		_result(result)
	else:
		_result.rpc_id(peer, result)


func _evaluate(peer: int, model: STOCK, req: Dictionary) -> String:
	if req.size() != 5 or not req.get("revision") is int or not req.get("op") is String:
		return "Invalid payload"
	if (
		not req.get("args") is Array
		or req.op.length() > 16
		or req.args.size() != SCHEMAS.get(req.op, -1)
	):
		return "Invalid payload"
	for value: Variant in req.args:
		if not value is int or value < 0 or value > 2147483647:
			return "Invalid payload"
	if req.op != "close" and req.revision != model.revision:
		return "Stale revision"
	var actor := model.data.owner as CogitoPlayerAdvanced
	if (actor.is_dead or not actor.can_act() or actor.network_input_blocked) and req.op != "close":
		return "Actor busy"
	var reason := _operate(peer, model, req.op, req.args)
	if reason.is_empty():
		_refresh(peer)
		model.data.inventory_updated.emit(model.data)
	return reason


func _operate(peer: int, model: STOCK, op: String, args: Array) -> String:
	var inv := model.data
	if op in ["put", "take", "external_move", "take_all", "close"]:
		return get_parent().containers.transaction(peer, model, op, args)
	if op == "unbind":
		if args[0] >= inv.assigned_quickslots.size():
			return "Invalid payload"
		inv.assigned_quickslots[args[0]] = null
		return ""
	if not valid_stack(model, args):
		return "Stack changed"
	if op == "ammo":
		return inv.owner.get_meta(&"net_wield").select_ammo(inv.inventory_slots[args[0]], args[2])
	return _stack_op(model, op, args)


## Validate source cell and id against the same live model before touching quantities.
static func valid_stack(model: STOCK, args: Array) -> bool:
	var i: int = args[0]
	if i >= model.data.inventory_slots.size() or args[1] <= 0:
		return false
	return model.id_of(model.data.inventory_slots[i]) == args[1]


func _stack_op(model: STOCK, op: String, args: Array) -> String:
	var inv := model.data
	var stack := inv.inventory_slots[int(args[0])]
	var ok := false
	match op:
		"use":
			var reason: String
			if stack.inventory_item is WieldableItemPD:
				reason = inv.owner.get_meta(&"net_wield").equip(stack)
			else:
				reason = use_item(inv.owner, stack.inventory_item)
			if reason.is_empty() and stack.inventory_item.has_method("is_consumable"):
				GRID.spend(inv, stack, 1)
			return reason
		"bind":
			ok = args[2] < inv.assigned_quickslots.size()
			if ok:
				if not inv.owner.get_meta(&"multiple_quickslot_binds"):
					var old := inv.assigned_quickslots.find(stack)
					if old >= 0:
						inv.assigned_quickslots[old] = null
				inv.assigned_quickslots[args[2]] = stack
		"combine":
			if args[2] < inv.inventory_slots.size():
				ok = GRID.combine(inv, stack, inv.inventory_slots[args[2]])
		"move":
			if valid_move(inv, stack, args):
				ok = GRID.move(inv, stack, inv, args[2], args[3], bool(args[4]))
		"drop":
			if stack.inventory_item.is_droppable and args[2] > 0 and args[2] <= stack.quantity:
				ok = get_parent().spawner.drop(inv.owner, stack, args[2])
				if ok:
					GRID.spend(inv, stack, args[2])
	return "" if ok else "Item cannot be moved"


## Bound destination, quantity and rotation bit for a grid operation.
static func valid_move(dst: CogitoInventory, stack: InventorySlotPD, args: Array) -> bool:
	return (
		args[2] < dst.inventory_slots.size()
		and args[3] > 0
		and args[3] <= stack.quantity
		and args[4] <= 1
	)


@rpc("authority", "call_remote", "reliable", 2)
func _result(result: Dictionary) -> void:
	if not local or local.data.owner.get_meta(&"inventory_life") != result.life:
		return
	result_received.emit(result)
	if result.request_id > _displayed:
		_displayed = result.request_id
		var hint := ACTIONS.hud_reason(result.reason)
		if not hint.is_empty():
			local.data.owner.player_interaction_component.hint_prompt.emit(null, hint)
