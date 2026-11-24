extends RefCounted
## Server-owned action policy. Only opt-in object/component pairs enter the commit path.

const BASIC := preload("../Components/Interactions/BasicInteraction.gd")
const LOCK := preload("../Components/Interactions/LockInteraction.gd")
const HOLD := preload("../Components/Interactions/HoldInteraction.gd")
const DUAL := preload("../Components/Interactions/DualInteraction.gd")
const REACH_MARGIN := 0.25


## Explicit opt in keeps all other solo component entry points inert online.
static func supported(node: Node, component: InteractionComponent) -> bool:
	if component is ReadableComponent:
		return true
	if not node.has_method("net_state") or not node.has_method("apply_net_state"):
		return false
	if component.has_method("net_commit"):
		return true
	return (
		component.get_parent() == node
		and component.get_script() in [BASIC, LOCK, HOLD, DUAL]
		and (
			node is CogitoDoor
			or node is CogitoButton
			or node is CogitoSwitch
			or node is CogitoKeypad
		)
	)


## Check a server-authored schema before interpreting the optional wire value.
static func valid_payload(
	component: InteractionComponent, action: StringName, value: Variant, supplied: bool
) -> bool:
	var schema := component.net_payload_schema(action)
	if schema.is_empty():
		return not supplied
	if schema != &"digits":
		return false
	if not value is String or value.length() < 1 or value.length() > 16:
		return false
	for index in value.length():
		var digit: int = value.unicode_at(index)
		if digit < 48 or digit > 57:
			return false
	return true


## Query actual server collision geometry from the acting avatar's eye.
static func geometry(actor: CogitoPlayer, node: Node3D, component: InteractionComponent) -> String:
	var pic := actor.player_interaction_component
	var eye := actor.get_aim_transform().origin
	var reach := pic.targeting.get_reach() + REACH_MARGIN
	var points: Array[Vector3] = [component.global_position]
	if "prompt_marker" in node and node.prompt_marker:
		points.append(node.prompt_marker.global_position)
	if node is CollisionObject3D:
		for owner_id in node.get_shape_owners():
			points.append(node.to_global(node.shape_owner_get_transform(owner_id).origin))
	var space := actor.get_world_3d().direct_space_state
	var reason := "Out of reach"
	for point in points:
		var target := eye + (point - eye).limit_length(reach)
		var query := PhysicsRayQueryParameters3D.create(eye, target)
		query.exclude = [actor.get_rid()]
		query.collision_mask = pic.interaction_raycast.collision_mask | actor.collision_mask
		query.collide_with_areas = pic.interaction_raycast.collide_with_areas
		query.hit_from_inside = true
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and (hit.collider == node or node.is_ancestor_of(hit.collider)):
			return ""
		if eye.distance_to(point) <= reach:
			if hit.is_empty():
				return ""
			reason = "Line of sight blocked"
	return reason


static func _has_item(pic: PlayerInteractionComponent, item: InventoryItemPD) -> bool:
	if not item or not pic.get_inventory():
		return false
	for slot in pic.get_inventory().inventory_slots:
		if slot and pic.matches_item(slot.inventory_item, item) and slot.quantity > 0:
			return true
	return false


static func _lock_action(component: InteractionComponent, action: StringName) -> bool:
	if component is DualInteraction and action == &"hold" and component.hold_node:
		return component.hold_node.get_script() == LOCK
	return component.get_script() == LOCK


## Pure world and inventory checks before consuming any attribute, key or currency.
static func unavailable(
	node: Node, component: InteractionComponent, action: StringName, pic: PlayerInteractionComponent
) -> String:
	if node is CogitoDoor:
		var lock_action := _lock_action(component, action)
		if node.ignore_interaction_raycast:
			return "Disabled action"
		if lock_action and node.is_open:
			return "Can't lock an open door"
		if (lock_action or node.is_locked) and not _has_item(pic, node.key):
			return node.key_hint if node.key_hint else "Key required"
	if node is CogitoButton or node is CogitoSwitch:
		return _panel_guard(node, pic)
	if node is CogitoKeypad and not node.is_locked:
		return "Already unlocked"
	return ""


static func _panel_guard(node: Node, pic: PlayerInteractionComponent) -> String:
	var unavailable_now: bool
	var item: InventoryItemPD
	if node is CogitoButton:
		unavailable_now = (
			node.cooldown > 0 or (not node.allows_repeated_interaction and node.has_been_used)
		)
		item = node.required_item
		if node.currency_check and node.currency_check.currency_cost != 0:
			return "Currency transactions require MP3"
	else:
		unavailable_now = not node.allows_repeated_interaction and node.is_on
		if node.required_item_slot:
			item = node.required_item_slot.inventory_item
	if unavailable_now:
		return node.has_been_used_hint if node.has_been_used_hint else "Unavailable"
	if node.needs_item_to_operate and not (node is CogitoSwitch and node.is_holding_item):
		if not _has_item(pic, item):
			return node.item_hint if node.item_hint else "Item required"
	return ""


## Perform the resolved local action synchronously. Private view instructions go in the reply.
static func commit(
	node: Node, action: CogitoInteractionAction, pic: PlayerInteractionComponent, payload: Variant
) -> Dictionary:
	var component := action.component
	var reply := {"ok": true}
	if node is CogitoKeypad and action.action_id == &"submit_code" and payload != node.passcode:
		return {"ok": false, "reason": "Wrong code", "view": "wrong_code"}
	# BasicInteraction applies its own attribute effects inside interact().
	var basic_call: bool = component.get_script() == BASIC and not node is CogitoKeypad
	if component.attribute_check and not basic_call:
		component.check_attribute(pic)
	if component.has_method("net_commit"):
		component.net_commit(action.action_id, pic, payload)
	elif component is ReadableComponent:
		reply.view = "read"
	elif node is CogitoKeypad:
		if action.action_id == &"submit_code":
			node.net_unlock(pic)
			reply.view = "code_ok"
		else:
			reply.view = "keypad"
	elif node is CogitoDoor and _lock_action(component, action.action_id):
		if node.is_locked:
			node.unlock_door(pic)
		else:
			node.lock_door()
	else:
		if node is CogitoDoor and node.is_locked:
			node.unlock_door(pic)
		action.perform(pic)
	return reply
