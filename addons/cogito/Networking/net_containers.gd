extends Node
## Per-viewer grants. Contents travel only to peers holding a live server-issued token.

const ENTITIES := preload("net_entities.gd")
const STOCK := preload("net_stock.gd")
const GRID := preload("net_grid.gd")
const ACTIONS := preload("net_actions.gd")

var local: STOCK
var token := 0
var _serial := 0
var _models := {}
var _views := {}


## Capture closed and never-opened containers, including spawned bags.
func capture() -> Dictionary:
	var result := {}
	var entities: Variant = get_parent().world.entities
	for id: String in entities.objects:
		var box := entities.live_object(id) as CogitoContainer
		if box and box.inventory_data:
			var model: STOCK = _models.get(box, STOCK.new())
			model.data = box.inventory_data
			result[id] = model.capture()
	return result


## Restore quantities and aliases into the private server resource before any view opens.
func restore(records: Dictionary) -> void:
	for id: String in records:
		var box := get_parent().world.entities.live_object(id) as CogitoContainer
		if box:
			var model := STOCK.new()
			model.data = box.inventory_data
			model.apply(records[id], 0, true)
			box.is_filled_with_starter_items = true
			_models[box] = model
			model.data.inventory_updated.connect(_changed.bind(box))
			box.tree_exiting.connect(_removed.bind(box), CONNECT_ONE_SHOT)


## Open after MP2 admission, reach, LOS and eligibility checks.
func open(box: CogitoContainer, component: InteractionComponent, actor: CogitoPlayer) -> Dictionary:
	var peer: int = get_parent().peer_for_actor(actor)
	var model: STOCK = _models.get(box)
	if not model:
		model = STOCK.new()
		model.data = box.inventory_data
		_models[box] = model
		model.data.inventory_updated.connect(_changed.bind(box))
		box.tree_exiting.connect(_removed.bind(box), CONNECT_ONE_SHOT)
	model.refresh()
	_serial = get_parent().travel.next_serial()
	_views[peer] = {"box": box, "component": component, "token": _serial}
	resync(peer)
	return {"ok": true, "view": "container"}


func _removed(box: CogitoContainer) -> void:
	for peer: int in _views.keys():
		if _views[peer].box == box:
			var grant: int = _views[peer].token
			forget(peer)
			if get_parent().peer_in_level(peer):
				if peer == 1:
					_closed(grant)
				else:
					_closed.rpc_id(peer, grant)
	_models.erase(box)


## Release on disconnect, level change, dismissal or target removal.
func forget(peer: int) -> void:
	var view: Dictionary = _views.get(peer, {})
	_views.erase(peer)
	if not view.is_empty() and is_instance_valid(view.box) and view.box is LootDropContainer:
		if view.box.marked_for_deletion and not view.box.is_queued_for_deletion():
			for other: Dictionary in _views.values():
				if other.box == view.box:
					return
			view.box._remove_container()


@rpc("authority", "call_remote", "reliable", 2)
func _closed(grant: int) -> void:
	if token != grant:
		return
	token = 0
	local = null
	var actor: CogitoPlayer = get_parent().local_actor
	if actor and actor.player_hud.is_inventory_visible():
		actor.player_hud.set_inventory_visibility(false)
		actor.player_hud.clear_external_inventory()


## Re-send the current container as well as the player baseline after a rejected transaction.
func resync(peer: int) -> void:
	var view: Dictionary = _views.get(peer, {})
	if not view.is_empty():
		var model: STOCK = _models[view.box]
		_changed(model.data, view.box)
		_send(peer, view, model, model.snapshot, true)


func _changed(_inv: CogitoInventory, box: CogitoContainer) -> void:
	var model: STOCK = _models[box]
	var delta := model.refresh()
	if not delta.is_empty():
		get_parent().mark_world_dirty()
		for peer: int in _views:
			if _views[peer].box == box:
				_send(peer, _views[peer], model, delta, false)


func _send(peer: int, view: Dictionary, model: STOCK, fields: Dictionary, full: bool) -> void:
	if peer == 1:
		local = model
		token = view.token
	else:
		var world: Node = get_parent().world
		var id: String = world.entities.id_for(view.box)
		_content.rpc_id(peer, world.entities.epoch, id, view.token, model.revision, fields, full)


@rpc("authority", "call_remote", "reliable", 2)
func _content(epoch: int, id: String, grant: int, rev: int, fields: Dictionary, full: bool) -> void:
	var entities: ENTITIES = get_parent().world.entities
	var box: CogitoContainer = entities.live_object(id)
	if not box or epoch != entities.epoch:
		return
	if full:
		local = STOCK.new()
		local.data = box.inventory_data
		token = grant
	if local and token == grant:
		local.apply(fields, rev, full)


## Apply a transfer against both inventory revisions and the currently granted container.
func transaction(peer: int, player: STOCK, op: String, args: Array) -> String:
	var view: Dictionary = _views.get(peer, {})
	if view.is_empty() or args[-2] != view.token:
		return "Container closed"
	if op == "close":
		view.box.container_closed.emit()
		forget(peer)
		return ""
	var box := view.box as CogitoContainer
	var model: STOCK = _models[box]
	_changed(model.data, box)
	if not box.is_inside_tree() or box.is_queued_for_deletion() or args[-1] != model.revision:
		return "Container changed"
	if not ACTIONS.geometry(player.data.owner, box, view.component).is_empty():
		return "Out of reach"
	var reason := _transfer(op, player, model, args)
	if reason.is_empty():
		model.data.inventory_updated.emit(model.data)
	return reason


func _transfer(op: String, player: STOCK, box: STOCK, args: Array) -> String:
	if op == "take_all":
		var seen := {}
		for stack in box.data.inventory_slots.duplicate():
			if not stack or seen.has(stack):
				continue
			seen[stack] = true
			var amount := GRID.insert(player.data, stack, stack.quantity, true)
			GRID.spend(box.data, stack, amount)
			if stack.quantity:
				player.data.owner.player_interaction_component.send_hint(null, "Inventory full")
		return ""
	var src := player if op == "put" else box
	var dst := player if op == "take" else box
	var endpoint: Node = get_parent().inventory
	if not endpoint.valid_stack(src, args):
		return "Stack changed"
	var stack := src.data.inventory_slots[int(args[0])]
	if endpoint.valid_move(dst.data, stack, args):
		if GRID.move(src.data, stack, dst.data, args[2], args[3], bool(args[4])):
			return ""
	return "Item cannot be moved"


## True while the server holds a private interface grant for this actor.
func has_view(peer: int) -> bool:
	return _views.has(peer)
