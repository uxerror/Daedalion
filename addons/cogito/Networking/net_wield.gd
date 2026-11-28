extends RefCounted
## Equipment, timers and input for one incarnation. Only the authority holds a gameplay stack.

const PROFILE := preload("net_wield_profile.gd")
const STOCK := preload("net_stock.gd")
const GRID := preload("net_grid.gd")
const VIEW := preload("net_wield_view.gd")
const COMBAT := preload("net_combat_events.gd")
const ACTION := CogitoPlayerCommand.Action

var actor: CogitoPlayerAdvanced
var players: Node
var player_id: String
var owner_peer: int
var life: int
var stack: InventorySlotPD
var generation := 0
var reload_left := 0.0
var public_item := ""
var light_on := false
var aiming := false
var profile: PROFILE
## Most recent command whose cosmetic was accepted by authority.
var accepted_sequence := -1
var _view := VIEW.new()
var _cooldown := 0.0
var _sequence := -1
var _prediction_delay := 0.0
var _predicted_sequence := -1
var _pending_sequence := -1
var _predicted_sound: AudioStreamPlayer3D
var _predicted_beam: Node


## Toggle the validated inventory stack. A switched or removed stack cancels pending reload.
func equip(next: InventorySlotPD) -> String:
	if actor.is_dead:
		return "Player is dead"
	if actor.is_sitting or actor.player_interaction_component.carrying.is_carrying:
		return "Actor busy"
	var item := next.inventory_item as WieldableItemPD
	if not item:
		return "Item cannot be wielded"
	var path := STOCK.definition(item).resource_path
	if path.is_empty() or players.wield_profile(path).kind == &"":
		return "Unsupported wieldable"
	_select(null if stack == next else next)
	return ""


func _select(next: InventorySlotPD) -> void:
	set_owner_item(null)
	stack = next
	generation += 1
	reload_left = 0.0
	var path := STOCK.definition(next.inventory_item).resource_path if next else ""
	apply_public(path, false, false)
	if next:
		if profile.kind == &"drink":
			_cooldown = maxf(_cooldown, profile.equip_seconds)
		set_owner_item(next.inventory_item)
	players.publish_wield(player_id)


## Wire-safe owner fields for the current MP3a inventory revision.
func private_fields(model: STOCK) -> Dictionary:
	if stack and stack not in model.data.inventory_slots:
		_select(null)
	var id := model.ensure_id(stack) if stack else 0
	return {"equipped": id, "generation": generation, "reloading": reload_left > 0}


## Bind HUD/quickslot presentation to the actual owner stack (including on listen).
func set_owner_item(item: WieldableItemPD) -> void:
	var handler := actor.player_interaction_component.wieldables
	if handler.equipped_wieldable_item and handler.equipped_wieldable_item != item:
		handler.equipped_wieldable_item.is_being_wielded = false
		handler.equipped_wieldable_item.player_interaction_component = null
	handler.equipped_wieldable_item = item
	if item:
		item.player_interaction_component = actor.player_interaction_component
		item.is_being_wielded = true
		if actor.is_local_presentation:
			item.update_wieldable_data(actor.player_interaction_component)
	elif actor.is_local_presentation:
		actor.player_interaction_component.updated_wieldable_data.emit(null, 0, null)


## A reliable current-state change, also used by spawn baselines.
func apply_public(path: String, on: bool, ads: bool) -> void:
	if public_item != path:
		_view.clear()
		_pending_sequence = -1
		_prediction_delay = 0
		public_item = path
		profile = players.wield_profile(path) if path else null
		var has_view := actor.is_local_presentation or not players.multiplayer.is_server()
		if profile and (has_view or players.local_actor):
			_view.equip(actor, STOCK.load_definition(path), profile)
	light_on = on
	aiming = ads
	_view.state(on, ads, profile)


func _visible_state(on: bool, ads: bool) -> void:
	if light_on != on or aiming != ads:
		apply_public(public_item, on, ads)
		players.publish_wield(player_id)


## Holster publicly and cancel firing without removing the equipped inventory stack.
func suspend() -> void:
	reload_left = 0
	_cooldown = 0
	accepted_sequence = -1
	generation += 1
	apply_public("", false, false)
	players.publish_wield(player_id)


## Restore the retained public equipment after the incarnation changes.
func resume_equipped() -> void:
	if stack:
		apply_public(STOCK.definition(stack.inventory_item).resource_path, false, false)
		set_owner_item(stack.inventory_item)


## Release transient state before detaching the inventory and actor.
func clear() -> void:
	_view.clear()
	set_owner_item(null)
	stack = null


func _busy() -> bool:
	return (
		actor.is_dead
		or not actor.can_act()
		or actor.network_input_blocked
		or actor.is_sitting
		or actor.is_showing_ui
		or actor.player_interaction_component.carrying.is_carrying
		or players.interactions.has_view(owner_peer)
		or players.containers.has_view(owner_peer)
	)


## Advance even between packets. Only fresh commands supply edges, held input expires upstream.
func tick(delta: float) -> void:
	_cooldown = maxf(0, _cooldown - delta)
	if not stack:
		return
	if stack not in actor.inventory_data.inventory_slots:
		_select(null)
		players.inventory.flush_actor(actor)
		return
	var command := actor.current_command
	var fresh := command.sequence > _sequence
	_sequence = maxi(_sequence, command.sequence)
	var blocked := _busy()
	if reload_left > 0:
		reload_left = maxf(0.0, reload_left - delta)
		if blocked or reload_left == 0:
			reload_left = 0
			if not blocked:
				_reload_ammo()
			players.inventory.flush_actor(actor)
	if light_on:
		var item := stack.inventory_item as WieldableItemPD
		item.charge_current = maxf(0, item.charge_current - delta * profile.drain)
		if item.charge_current == 0:
			_visible_state(false, false)
	if blocked or not command.has_control:
		_visible_state(light_on, false)
		return
	if generation != command.wield_generation:
		return
	var gun := profile.kind in [&"rifle", &"pistol"]
	_visible_state(light_on, gun and command.is_held(ACTION.SECONDARY))
	var automatic := profile.kind == &"rifle" and command.is_held(ACTION.PRIMARY)
	if fresh:
		for edge in command.edges:
			if edge == ACTION.CHANGE_AMMO:
				_change_ammo()
			elif edge == ACTION.RELOAD:
				start_reload()
			elif edge == ACTION.PRIMARY:
				_primary()
	if stack and (automatic or profile.kind == &"drink"):
		_primary()


func _primary() -> void:
	if not stack or _cooldown > 0 or reload_left > 0:
		return
	var item := stack.inventory_item as WieldableItemPD
	var aim := actor.get_aim_transform()
	var dir := -aim.basis.z.normalized()
	var point := aim.origin
	var accepted := true
	match profile.kind:
		&"rifle", &"pistol":
			accepted = item.charge_current >= 1
		&"light":
			accepted = light_on or item.charge_current > 0
		&"melee":
			var stamina := actor.stamina_attribute
			accepted = not profile.stamina or (stamina and stamina.value_current >= profile.stamina)
	if not accepted:
		return
	if profile.kind in [&"pistol", &"throw"]:
		if not players.projectiles.launch(player_id, life, stack, profile, aim):
			return
	_cooldown = profile.interval
	var combat: COMBAT = players.combat
	accepted_sequence = actor.current_command.sequence
	var collision := {}
	var end := Vector3.ZERO
	if profile.kind in [&"rifle", &"melee"]:
		end = point + dir * item.wieldable_range
		collision = COMBAT.trace(actor, point, end)
		if not collision.is_empty():
			end = collision.position
	combat.broadcast(player_id, life, public_item, &"fire", point, Vector3.ZERO, end)
	match profile.kind:
		&"rifle", &"melee":
			if not collision.is_empty():
				combat.hit(
					collision.collider, item.wieldable_damage, actor, dir, collision.position
				)
				combat.broadcast(
					player_id, life, public_item, &"impact", collision.position, collision.normal
				)
			if profile.stamina:
				actor.stamina_attribute.subtract(profile.stamina)
		&"light":
			_visible_state(not light_on, false)
		&"drink":
			for effect in profile.effects:
				effect.use(actor)
			players.flush_attributes(player_id)
	if profile.kind in [&"pistol", &"rifle"]:
		item.charge_current -= 1
	elif profile.kind in [&"drink", &"throw"]:
		GRID.spend(actor.inventory_data, stack, 1)
		if profile.kind == &"drink" or stack.quantity <= 0:
			_select(null)
	players.inventory.flush_actor(actor)


## Number of authored ammo units that can fit, respecting charge per unit.
func ammo_needed(ammo: AmmoItemPD) -> int:
	if not stack or reload_left or _cooldown or _busy():
		return 0
	var item := stack.inventory_item as WieldableItemPD
	if item.no_reload or item.ammo_types.is_empty() or item.get_current_ammo().name != ammo.name:
		return 0
	return ceili((item.charge_max - item.charge_current) / maxi(1, ammo.reload_amount))


## Start a server-timed reload. Debit reserve ammo only at completion.
func start_reload() -> void:
	if not stack:
		return
	var item := stack.inventory_item as WieldableItemPD
	var ammo := item.get_current_ammo()
	if ammo_needed(ammo) <= 0 or actor.inventory_data.find_slots(ammo.name).is_empty():
		return
	reload_left = profile.reload_seconds
	accepted_sequence = actor.current_command.sequence
	players.combat.broadcast(
		player_id, life, public_item, &"reload", actor.get_aim_transform().origin
	)
	players.inventory.flush_actor(actor)


func _reload_ammo() -> void:
	var item := stack.inventory_item as WieldableItemPD
	var ammo := item.get_current_ammo()
	for reserve in actor.inventory_data.find_slots(ammo.name):
		var needed := ceili((item.charge_max - item.charge_current) / maxi(1, ammo.reload_amount))
		var spent := mini(reserve.quantity, needed)
		GRID.spend(actor.inventory_data, reserve, spent)
		item.charge_current = minf(
			item.charge_max, item.charge_current + spent * ammo.reload_amount
		)
		if item.charge_current >= item.charge_max:
			break


func _change_ammo() -> void:
	if not stack:
		return
	var item := stack.inventory_item as WieldableItemPD
	for step in range(1, item.ammo_types.size()):
		var index := (item.current_ammo_type + step) % item.ammo_types.size()
		if select_ammo(stack, index).is_empty():
			return


## Select the exact server-authored ammo index from the item's quickslot submenu.
func select_ammo(slot: InventorySlotPD, index: int) -> String:
	var item := slot.inventory_item as WieldableItemPD
	if not item or index < 0 or index >= item.ammo_types.size():
		return "Invalid payload"
	if _cooldown or reload_left or _busy():
		return "Actor busy"
	var path := STOCK.definition(item).resource_path
	if path.is_empty() or players.wield_profile(path).kind != &"pistol":
		return "Unsupported wieldable"
	var same := item.current_ammo_type == index
	if not same and actor.inventory_data.find_slots(item.ammo_types[index].name).is_empty():
		return "No reserve ammo"
	if not same and not _unload(item):
		return "Inventory full"
	if stack != slot:
		_select(slot)
	if not same:
		item.current_ammo_type = index
		start_reload()
	return ""


func _unload(item: WieldableItemPD) -> bool:
	var reserve := InventorySlotPD.new()
	reserve.inventory_item = item.get_current_ammo()
	var amount := floori(item.charge_current / maxi(1, item.get_current_ammo().reload_amount))
	if amount and not GRID.insert(actor.inventory_data, reserve, amount, false):
		return false
	item.charge_current = 0
	return true


## Predict short-lived animation, flash and sound only. Ammo and impacts wait for authority.
func predict(command: CogitoPlayerCommand, delta: float) -> void:
	_prediction_delay = maxf(0, _prediction_delay - delta)
	var owner_item := actor.player_interaction_component.wieldables.equipped_wieldable_item
	if not profile or not owner_item:
		return
	var can_use := command.has_control and not _busy()
	var has_sights := profile.kind in [&"rifle", &"pistol"]
	var ads := can_use and has_sights and command.is_held(ACTION.SECONDARY)
	_view.state(light_on, ads, profile)
	var fresh := command.sequence > _predicted_sequence
	_predicted_sequence = maxi(command.sequence, _predicted_sequence)
	var loading: bool = players.inventory.local.snapshot.get("reloading", false)
	if not can_use or _prediction_delay > 0 or loading:
		return
	var firing := profile.kind == &"rifle" and command.is_held(ACTION.PRIMARY)
	firing = firing or (fresh and ACTION.PRIMARY in command.edges)
	if has_sights and owner_item.charge_current < 1:
		firing = false
	var reloading := fresh and ACTION.RELOAD in command.edges
	if firing or reloading:
		_pending_sequence = command.sequence
		_prediction_delay = profile.interval if firing else profile.reload_seconds
		_view.play(profile.fire_clip if firing else profile.reload_clip)
		var eye := actor.get_aim_transform().origin
		_predicted_sound = players.combat.present(
			actor, profile, &"fire" if firing else &"reload", eye, Vector3.ZERO
		)
		if firing:
			_predicted_beam = _predict_beam(owner_item)


## The owner's ray runs from the viewmodel muzzle to its own camera hit, like offline.
func _predict_beam(owner_item: WieldableItemPD) -> Node:
	if not profile.tracer:
		return null
	var aim := actor.get_aim_transform()
	var end := aim.origin - aim.basis.z.normalized() * owner_item.wieldable_range
	var collision := COMBAT.trace(actor, aim.origin, end)
	if not collision.is_empty():
		end = collision.position
	var start := _view.muzzle.global_position if _view.muzzle else aim.origin
	return players.combat.beam(actor, profile, start, end)


## Stop a rejected prediction once an owner pose acknowledges its input.
func reconcile(ack: int, accepted: int) -> void:
	if _pending_sequence < 0 or ack < _pending_sequence:
		return
	if accepted < _pending_sequence:
		_view.cancel()
		_prediction_delay = 0
		if is_instance_valid(_predicted_sound):
			_predicted_sound.queue_free()
		if is_instance_valid(_predicted_beam):
			_predicted_beam.queue_free()
	_pending_sequence = -1


func cancel_prediction() -> void:
	if _pending_sequence >= 0:
		reconcile(_pending_sequence, -1)
	_prediction_delay = 0
