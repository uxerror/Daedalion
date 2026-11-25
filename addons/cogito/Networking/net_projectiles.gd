extends Node
## Authority sweeps each ballistic step. Observers integrate only a mesh with no physics body.

## A new or baselined flight. Dedicated authority supplies a null visual.
signal launched(id: int, visual: Node3D)
## A live flight ended on impact, expiry or loss of its shooter.
signal ended(id: int, impact: bool)

const STOCK := preload("net_stock.gd")
const PROFILE := preload("net_wield_profile.gd")
const COMBAT := preload("net_combat_events.gd")

var _serial := 0
var _flights := {}


## Launch only from the equipped server definition and its current ammo selection.
func launch(
	shooter: String, life: int, stack: InventorySlotPD, profile: PROFILE, aim: Transform3D
) -> bool:
	var item := stack.inventory_item as WieldableItemPD
	var index := item.current_ammo_type
	if not multiplayer.is_server() or index < 0 or index >= profile.projectiles.size():
		return false
	var scene := profile.projectiles[index]
	if not scene:
		return false
	var instance := scene.instantiate()
	var template := instance as CogitoProjectile
	if not template:
		instance.free()
		return false
	var lifespan := template.get_node_or_null("Lifespan") as Timer
	var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	gravity *= float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	gravity *= template.gravity_scale
	_serial += 1
	var row := {
		"id": _serial,
		"shooter": shooter,
		"life": life,
		"item": STOCK.definition(item).resource_path,
		"index": index,
		"pos": aim.origin,
		"velocity": -aim.basis.z.normalized() * profile.speed,
		"gravity": gravity,
	}
	var flight := _create(row, template)
	flight.damage = item.wieldable_damage
	flight.remaining = lifespan.wait_time if lifespan and lifespan.autostart else 30.0
	flight.element = template.impact_element
	flight.buildup = template.impact_element_amount
	flight.element_damage = template.impact_damage
	var props := template.get_node_or_null("CogitoProperties") as CogitoProperties
	# Absence of properties and the unflagged material are distinct in CogitoProjectile.
	flight.material = props.material_properties if props else -1
	flight.burning = props != null and props.ignite_on_ready
	var wet_flag := CogitoProperties.ElementalProperties.WET
	flight.wet = props != null and (props.elemental_properties & wet_flag) != 0
	var pickup := STOCK.pickup_template(scene)
	if not template.destroy_on_impact:
		var recoverable := stack if profile.kind == &"throw" else pickup
		if recoverable:
			flight.pickup = STOCK.copy_stack(recoverable, 1)
	template.free()
	for peer: int in get_parent().observers():
		_spawn.rpc_id(peer, get_parent().world.entities.epoch, row)
	return true


func _create(row: Dictionary, template: Node3D) -> Dictionary:
	var visual: Node3D
	if not multiplayer.is_server() or get_parent().local_actor:
		visual = _visual(row, template)
	var flight := {"row": row, "visual": visual}
	_flights[row.id] = flight
	launched.emit(row.id, visual)
	return flight


func _visual(row: Dictionary, template: Node3D) -> Node3D:
	var visual := Node3D.new()
	# Copy only renderable geometry, including its transform relative to the authored root.
	for source: Node3D in template.find_children("*", "GeometryInstance3D", true, false):
		if not (source is MeshInstance3D or source is CSGShape3D):
			continue
		var part := source.duplicate(0) as Node3D
		for child in part.get_children():
			child.free()
		part.set_script(null)
		if part is CSGShape3D:
			part.use_collision = false
		var xf := source.transform
		var ancestor := source.get_parent()
		while ancestor is Node3D and ancestor != template:
			xf = ancestor.transform * xf
			ancestor = ancestor.get_parent()
		part.transform = xf
		visual.add_child(part)
	get_parent().active_level().add_child(visual)
	visual.global_position = row.pos
	var direction: Vector3 = row.velocity.normalized()
	if not direction.is_zero_approx():
		var up := Vector3.RIGHT if absf(direction.y) > 0.99 else Vector3.UP
		visual.global_basis = Basis.looking_at(direction, up) * template.basis
	return visual


## Baseline includes current flight position and velocity. Completed launches have no record.
func baseline(peer: int) -> void:
	for flight: Dictionary in _flights.values():
		_spawn.rpc_id(peer, get_parent().world.entities.epoch, flight.row)


@rpc("authority", "call_remote", "reliable", 2)
func _spawn(epoch: int, row: Dictionary) -> void:
	if get_parent().world.entities.epoch != epoch or _flights.has(row.id):
		return
	var profile: PROFILE = get_parent().wield_profile(row.item)
	var template := profile.projectiles[row.index].instantiate() as Node3D
	_create(row, template)
	template.free()


func _physics_process(delta: float) -> void:
	for id: int in _flights.keys():
		var flight: Dictionary = _flights[id]
		var row: Dictionary = flight.row
		var start: Vector3 = row.pos
		row.pos += row.velocity * delta + 0.5 * row.gravity * delta * delta
		row.velocity += row.gravity * delta
		if flight.visual:
			flight.visual.global_position = row.pos
		if multiplayer.is_server():
			_step(id, flight, start, delta)


func _step(id: int, flight: Dictionary, start: Vector3, delta: float) -> void:
	var row: Dictionary = flight.row
	var avatar: Variant = get_parent().avatar_for(row.shooter)
	if not avatar or avatar.lifetime != row.life:
		_finish(id, false)
		return
	var hit := COMBAT.trace(avatar.actor, start, row.pos)
	flight.remaining -= delta
	if hit.is_empty():
		if flight.remaining <= 0:
			_finish(id, false)
		return
	var actor := avatar.actor as CogitoPlayerAdvanced
	var point: Vector3 = hit.position
	var dir: Vector3 = row.velocity.normalized()
	_finish(id, true)
	var combat: COMBAT = get_parent().combat
	var props := CogitoProperties.get_properties_of(hit.collider)
	var soft := CogitoProperties.MaterialProperties.SOFT
	var soft_contact: bool = props and flight.material == soft and props.material_properties == soft
	if flight.material < 0 or soft_contact:
		combat.hit(hit.collider, flight.damage, actor, dir, point)
	# These are the contact reactions from the shipped burning and wet dart scenes.
	if props:
		var flammable := CogitoProperties.ElementalProperties.FLAMMABLE
		if flight.burning and props.elemental_properties & flammable:
			props.set_on_fire()
		if flight.wet:
			props.make_wet()
	if flight.element != CogitoProperties.Element.PHYSICAL:
		CogitoProperties.apply_element_to(hit.collider, flight.element, flight.buildup, actor)
		CogitoProperties.deal_elemental_damage(
			hit.collider, flight.element_damage, flight.element, actor, dir, point
		)
		if flight.element_damage > 0 and hit.collider is CogitoPlayer:
			get_parent().inventory.send_attributes(hit.collider, ["health"])
	combat.broadcast(row.shooter, row.life, row.item, &"impact", point, hit.normal)
	if flight.has("pickup"):
		get_parent().spawner.spawn_item(flight.pickup, 1, point - dir * 0.12)


func _finish(id: int, impact: bool) -> void:
	var epoch: int = get_parent().world.entities.epoch
	_remove(epoch, id, impact)
	for peer: int in get_parent().observers():
		_remove.rpc_id(peer, epoch, id, impact)


@rpc("authority", "call_remote", "reliable", 2)
func _remove(epoch: int, id: int, impact: bool) -> void:
	if get_parent().world.entities.epoch == epoch and _flights.has(id):
		if _flights[id].visual:
			_flights[id].visual.queue_free()
		_flights.erase(id)
		ended.emit(id, impact)


## Discard all flights before unloading the level. Serial numbers survive rebinding.
func clear() -> void:
	for flight: Dictionary in _flights.values():
		if is_instance_valid(flight.visual):
			flight.visual.queue_free()
	_flights.clear()
