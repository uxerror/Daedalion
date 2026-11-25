extends Node
## Live presentation only. Events are scoped to an incarnation and never added to a baseline.

## A cosmetic was presented for a live avatar at a world-space point.
signal presented(actor: CogitoPlayerAdvanced, event: StringName, point: Vector3)

## Only live events emit this signal.
signal npc_presented(npc: CogitoNPC, event: StringName, point: Vector3)

const PROFILE := preload("net_wield_profile.gd")


## Trace in this actor's physics world, ignoring the shooter's own collision geometry.
static func trace(actor: CollisionObject3D, start: Vector3, end: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(start, end)
	query.exclude = [actor.get_rid()]
	if actor is CogitoNPC and actor.head is CollisionObject3D:
		query.exclude = [actor.get_rid(), actor.head.get_rid()]
	query.hit_from_inside = true
	return actor.get_world_3d().direct_space_state.intersect_ray(query)


## Enter the existing health/hitbox path with the explicit instigator.
func hit(target: Node, amount: float, actor: Node3D, dir: Vector3, pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	if target.owner is CogitoNPC and target == target.owner.head:
		target = target.owner
	if target.has_signal("damage_received"):
		target.emit_signal("damage_received", amount, actor, dir, pos)
	elif target is CogitoPlayer:
		target.receive_elemental_damage(amount, CogitoProperties.Element.PHYSICAL, actor, dir, pos)


## Broadcast the accepted event to live observers. Only impact confirmation returns to the owner.
func broadcast(
	id: String, life: int, item: String, event: StringName, point: Vector3, normal := Vector3.ZERO
) -> void:
	var players := get_parent()
	var actor: CogitoPlayerAdvanced = players.avatar_for(id).actor
	var shooter_peer: int = players.peer_for_actor(actor)
	var epoch: int = players.world.entities.epoch
	for peer: int in players.observers():
		if event == &"impact" or peer != shooter_peer:
			_event.rpc_id(peer, epoch, id, life, item, event, point, normal)
	if players.local_actor and (actor != players.local_actor or event == &"impact"):
		_event(epoch, id, life, item, event, point, normal)


@rpc("authority", "call_remote", "reliable", 2)
func _event(
	epoch: int,
	id: String,
	life: int,
	item: String,
	event: StringName,
	point: Vector3,
	normal: Vector3
) -> void:
	var players := get_parent()
	var avatar: Variant = players.avatar_for(id)
	if not avatar or avatar.lifetime != life or players.world.entities.epoch != epoch:
		return
	var profile: PROFILE = players.wield_profile(item)
	present(avatar.actor, profile, event, point, normal)


## Resolve the selected NPC weapon once. Only the authority traces or launches a flight.
func fire_npc(npc: CogitoNPC, point: Vector3) -> bool:
	if not multiplayer.is_server() or not npc.perception.target():
		return false
	var weapon := npc.weapon
	var start := weapon.bullet_point.global_position
	var dir := start.direction_to(point)
	if weapon.attack_type == NpcWieldable.AttackType.Projectile:
		if not get_parent().projectiles.launch_npc(npc, start, dir):
			return false
	else:
		var collision := trace(npc, start, point + dir * 0.5)
		if not collision.is_empty():
			point = collision.position
			hit(collision.collider, weapon.npc_wieldable_damage, npc, dir, point)
	npc_event(npc, &"fire", start, point)
	return true


## Broadcast one NPC cosmetic to interested observers and the local listen view.
func npc_event(
	npc: CogitoNPC, event: StringName, point: Vector3, end := Vector3.ZERO, sound := NodePath()
) -> void:
	if not multiplayer.is_server():
		return
	var players := get_parent()
	var entities: Variant = players.world.entities
	var id: String = entities.id_for(npc)
	for peer: int in players.observers():
		var record: Dictionary = players.get_parent().for_peer(peer)
		var actor: CogitoPlayer = players.avatar_for(record.player_id).actor
		if npc.network_state.in_interest(actor.global_position):
			_npc_event.rpc_id(
				peer, entities.level_key, entities.epoch, id, event, point, end, sound
			)
	var local: CogitoPlayer = players.local_actor
	if local and npc.network_state.in_interest(local.global_position):
		_npc_event(entities.level_key, entities.epoch, id, event, point, end, sound)


@rpc("authority", "call_remote", "reliable", 2)
func _npc_event(
	key: String,
	epoch: int,
	id: String,
	event: StringName,
	point: Vector3,
	end: Vector3,
	sound: NodePath
) -> void:
	var entities: Variant = get_parent().world.entities
	if not entities.matches(key, epoch):
		return
	var npc := entities.live_object(id) as CogitoNPC
	if not npc:
		return
	npc_presented.emit(npc, event, point)
	if event == &"fire" and npc.weapon:
		var weapon := npc.weapon
		_flash(npc, point)
		weapon.animation_player.play(weapon.anim_action_primary)
		CogitoAudio.play_sound_3d_in(npc, weapon.sound_primary_use, point)
		if weapon.tracer and weapon.attack_type == NpcWieldable.AttackType.Hitscan:
			var tracer := weapon.tracer.instantiate()
			tracer.draw_ray(point, end)
			entities.root.add_child(tracer)
	elif event == &"bark":
		var stream := npc.get_node_and_resource(sound)[1] as AudioStream
		CogitoAudio.play_sound_3d_in(npc, stream, point)
	elif event == &"hit":
		npc.animation_tree.set("parameters/Transition/transition_request", "hit")
		CogitoAudio.play_sound_3d_in(npc, npc.health.sound_on_hit, point)
		CogitoAudio.play_sound_3d_in(npc, npc.health.sound_on_damage_taken, point)
	elif event == &"death":
		CogitoAudio.play_sound_3d_in(npc, npc.health.sound_on_death, point)


## Play either the owner's immediate cosmetic or the server's event at the reported world point.
func present(
	actor: CogitoPlayerAdvanced,
	profile: PROFILE,
	event: StringName,
	point: Vector3,
	normal: Vector3
) -> AudioStreamPlayer3D:
	presented.emit(actor, event, point)
	if event == &"impact":
		_impact(actor, profile, point, normal)
		return null
	var sound := profile.reload_sound if event == &"reload" else profile.fire_sound
	var audio := CogitoAudio.play_sound_3d_in(actor, sound, point) if sound else null
	if profile.kind in [&"rifle", &"pistol"] and event == &"fire":
		_flash(actor, point)
	return audio


func _flash(actor: Node3D, point: Vector3) -> void:
	var flash := OmniLight3D.new()
	actor.add_child(flash)
	flash.global_position = point
	flash.omni_range = 2.0
	flash.create_tween().tween_property(flash, "light_energy", 0.0, 0.06).finished.connect(
		flash.queue_free
	)


func _impact(
	actor: CogitoPlayerAdvanced, profile: PROFILE, point: Vector3, normal: Vector3
) -> void:
	var root := CogitoLevel.root_of(actor) as Node3D
	if profile.decal and normal.length_squared() > 0.5:
		BulletDecalPool.spawn_bullet_decal(
			profile.decal, point, normal, root, Basis.IDENTITY, profile.decal_texture
		)
	if profile.impact_scene:
		var effect := profile.impact_scene.instantiate() as Node3D
		root.add_child(effect)
		effect.global_position = point
