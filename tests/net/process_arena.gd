extends Node3D
## The process harness observes actual Advanced bodies. Each drive file requests another lap.

const Avatar := preload("res://addons/cogito/Networking/net_avatar.gd")
const GRID := preload("res://addons/cogito/Networking/net_grid.gd")
const CHANNEL := preload("res://addons/cogito/Networking/net_command_channel.gd")
const RIFLE := preload("res://addons/cogito/InventoryPD/Items/Cogito_LaserRifle.tres")
const DRIVE_TICKS := 140

var _driver := Driver.new()
var _loss: LossChannel
var _control: String
var _generation := 0
var _clock := 0
var _order := 0
var _presentations := 0
var _cutscene_starts := 0
var _wheel_start := {}
var _pickup_request := {}
var _fires := 0
var _launches := 0
var _impacts := 0
var _respawn_error := ""
var _npc_shots := 0
var _npc_deaths := 0
var _burn_removals := 0
var _quest_events := 0
var _corpse_stream: CorpseMeter


class CorpseMeter:
	extends "res://addons/cogito/Networking/net_body_timeline.gd"

	var first_tick := -1
	var moving_bytes := 0
	var total_bytes := 0
	var rest_tick := -1

	func push(stamp: int, row: Array) -> bool:
		var count := var_to_bytes(row).size()
		total_bytes += count
		if not row[6] and rest_tick < 0:
			if first_tick < 0:
				first_tick = stamp
			moving_bytes += count
		elif rest_tick < 0:
			rest_tick = stamp
		return super.push(stamp, row)


## Sample and send are two ordinary entry points in the same client physics tick.
class PredictionProbe:
	var avatar: Avatar
	var action := ""
	var start := Vector3.ZERO
	var height := 0.0
	var tick := 0
	var latest := -1
	var errors: Array[float] = []
	var depth := 0

	func begin(label: String) -> void:
		avatar = CogitoNet.player_world.avatar_for(CogitoNet.local_player_id())
		action = label
		start = avatar.actor.position
		height = avatar.actor.head.position.y
		tick = avatar.timeline.latest().tick

	func sent() -> void:
		if not avatar:
			return
		var prediction := avatar.prediction
		if prediction and prediction.active and prediction.baseline.tick != latest:
			latest = prediction.baseline.tick
			errors.append(prediction.last_position_error)
			if prediction.last_restore_tick == latest:
				depth = maxi(depth, prediction.last_replay.size())
		if action:
			var distance := start.z - avatar.actor.position.z
			if action == "crouch":
				distance = height - avatar.actor.head.position.y
			var sample := {
				"action": action,
				"delta": distance,
				"same_pose": tick == avatar.timeline.latest().tick
			}
			if action == "crouch" and not errors.is_empty():
				errors.sort()
				sample.p50 = errors[errors.size() >> 1]
				sample.p95 = errors[ceili(errors.size() * 0.95) - 1]
				sample.max = errors.back()
				sample.depth = depth
			print("NET PREDICTION ", JSON.stringify(sample))
			action = ""


## Count delivered Variant row payload, excluding the shared batch and transport headers.
class PoseMeter:
	extends "res://addons/cogito/Networking/net_snapshot.gd"
	var id: String
	var life: int
	var received := 0
	var private_rows := 0

	func _init(previous: RefCounted, player_id: String, lifetime: int) -> void:
		id = player_id
		life = lifetime
		_frames = previous._frames
		_arrival_usec = previous._arrival_usec
		_render_tick = previous._render_tick

	func push(frame: Dictionary) -> Acceptance:
		var row := [id, life, frame]
		if frame.has("owner_state"):
			# The wield acceptance is an int32-sized Variant throughout this scenario.
			row.append(-1)
			private_rows += 1
		received += var_to_bytes(row).size()
		return super.push(frame)


class LossChannel:
	extends CHANNEL

	var muted := true
	var probe: PredictionProbe

	func packet(command: CogitoPlayerCommand) -> PackedByteArray:
		if muted:
			return PackedByteArray()
		var data := super.packet(command)
		if probe:
			probe.sent()
		if command.sequence % 10 == 9:
			if CogitoPlayerCommand.Action.JUMP in command.edges:
				print("NET DROPPED JUMP ", command.sequence)
			return PackedByteArray()
		return data


class Driver:
	extends CogitoPlayerInputSource

	var progress := DRIVE_TICKS
	var jumped := false
	var doorway_ticks := 0
	var combat_lane := false
	var trigger_ticks := 0
	var aim_pitch := 0.0
	var throwing := false
	var crouch_tap := false
	var probe: PredictionProbe

	func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
		var command := super.sample(actor, sequence)
		if probe and progress == 0:
			probe.begin("walk")
		if crouch_tap:
			crouch_tap = false
			command.held = 1 << CogitoPlayerCommand.Action.CROUCH
			command.toggle_crouch = false
			probe.begin("crouch")
			return command
		if throwing:
			throwing = false
			command.add_edge(CogitoPlayerCommand.Action.PRIMARY)
			command.held = 1 << CogitoPlayerCommand.Action.PRIMARY
			return command
		if combat_lane and doorway_ticks == 0:
			command.yaw = 0
			command.neck_yaw = 0
			command.pitch = aim_pitch
			if trigger_ticks:
				command.add_edge(CogitoPlayerCommand.Action.PRIMARY)
				command.held = 1 << CogitoPlayerCommand.Action.PRIMARY
				trigger_ticks -= 1
			return command
		if doorway_ticks > 0:
			doorway_ticks -= 1
			command.yaw = 0.0
			command.move = Vector2.UP
			return command
		if progress >= DRIVE_TICKS:
			return command
		command.move = Vector2.UP if progress < 105 else Vector2.ZERO
		command.yaw = 0.0 if progress < 60 else PI / 2.0
		if progress >= 30 and sequence % 10 == 9 and not jumped:
			command.add_edge(CogitoPlayerCommand.Action.JUMP)
			command.add_edge(CogitoPlayerCommand.Action.JUMP, false)
			jumped = true
		progress += 1
		return command


func _ready() -> void:
	if not CogitoNet.player_world:
		# The memory-peer suites bind their own branch facade.
		set_physics_process(false)
		return
	$Cutscene/AnimationPlayer.animation_started.connect(
		func(_clip: StringName): _cutscene_starts += 1
	)
	if CogitoNet.is_server():
		$Guard.health.death.connect(func(): _npc_deaths += 1)
	CogitoNet.player_world.combat.npc_presented.connect(
		func(_npc: CogitoNPC, event: StringName, _point: Vector3):
			_npc_shots += int(event == &"fire")
			if not CogitoNet.is_server():
				_npc_deaths += int(event == &"death")
	)
	$FireStand/Grass1.tree_exiting.connect(func(): _burn_removals += 1, CONNECT_ONE_SHOT)
	CogitoNet.player_world.quests.notified.connect(
		func(_event: StringName, _quest: CogitoQuest): _quest_events += 1
	)
	_control = OS.get_environment("COGITO_TEST_CONTROL")
	CogitoNet.player_world.bind_level(self, Transform3D(Basis.IDENTITY, Vector3.UP), "arena")
	CogitoNet.player_world.death.respawn_rejected.connect(func(why: String): _respawn_error = why)
	CogitoNet.player_world.interactions.result_received.connect(_result)
	CogitoNet.player_world.inventory.result_received.connect(
		func(result: Dictionary): print("NET INVENTORY ", JSON.stringify(result))
	)
	CogitoNet.player_world.world.presented.connect(_presented)
	CogitoNet.player_world.combat.presented.connect(_combat_event)
	CogitoNet.player_world.projectiles.launched.connect(
		func(_id: int, _node: Node3D): _launches += 1
	)
	CogitoNet.player_world.projectiles.ended.connect(
		func(_id: int, impact: bool): _impacts += int(impact)
	)
	if not CogitoNet.is_server():
		CogitoNet.player_world.world.entities.registered.connect(_meter_corpse)
		_loss = LossChannel.new()
		if "--prediction-probe" in OS.get_cmdline_user_args():
			_driver.probe = PredictionProbe.new()
			_loss.probe = _driver.probe
			_loss.muted = false
		CogitoNet.player_world.command_channel = _loss


func _physics_process(_delta: float) -> void:
	_clock += 1
	if not CogitoNet.is_online():
		return
	var local_actor := CogitoNet.local_player() as CogitoPlayerAdvanced
	if local_actor and local_actor.input_source != _driver:
		local_actor.input_source = _driver
	if local_actor and FileAccess.file_exists(_control.path_join("drive-%d" % (_generation + 1))):
		if _loss:
			_loss.muted = false
		_generation += 1
		_driver.progress = 0
		_driver.jumped = false
	if _clock % 4 != 0:
		return
	var file := _control.path_join("order-%d" % (_order + 1))
	if FileAccess.file_exists(file):
		_order += 1
		_execute(JSON.parse_string(FileAccess.get_file_as_string(file)))
	if not CogitoNet.is_online():
		return
	var actors := {}
	var pose_bytes := {}
	var private_rows := {}
	var owner_mode := ""
	for record in CogitoNet.players():
		var avatar := CogitoNet.player_world.avatar_for(record.player_id)
		if avatar:
			var pos := avatar.actor.position
			actors[record.display_name] = [pos.x, pos.y, pos.z]
			if avatar.timeline:
				if not avatar.timeline is PoseMeter:
					avatar.timeline = PoseMeter.new(
						avatar.timeline, record.player_id, avatar.lifetime
					)
				var meter := avatar.timeline as PoseMeter
				pose_bytes[record.display_name] = meter.received
				private_rows[record.display_name] = meter.private_rows
				var baseline := avatar.latest_owner_baseline()
				if baseline:
					owner_mode = "eligible" if baseline.state else "fallback"
	var count := 0
	for child in get_children():
		if child is CogitoPlayer:
			count += 1
	var data := {
		"tick": _clock,
		"actors": actors,
		"pose_bytes": pose_bytes,
		"private_rows": private_rows,
		"owner_mode": owner_mode,
		"predicted":
		(
			local_actor != null
			and local_actor.owner_prediction != null
			and local_actor.owner_prediction.active
		),
		"count": count,
		"drive": _generation,
		"progress": _driver.progress,
		"order": _order,
		"walk": _driver.doorway_ticks,
		"epoch": CogitoNet.player_world.world.entities.epoch,
		"open": $Door.is_open,
		"door_revision": CogitoNet.player_world.world.revisions.get("level:door", 0),
		"linked": $LinkedDoor.is_open,
		"locked": $Keypad.is_locked,
		"keydoor_locked": $KeyDoor.is_locked,
		"keydoor_open": $KeyDoor.is_open,
		"events": _presentations,
		"wheel_open": $WheelDoor.is_open,
		"turned": $Wheel.has_been_turned,
		"picked": not $PickDoor.is_locked,
		"picking": $PickDoor/Pick.lockpick_ui.visible,
		"cutscene_starts": _cutscene_starts,
		"cutscene": $Cutscene.player_reference != null,
		"shared_quest": CogitoNet.player_world.quests.journal().flags.get("TargetsShot", 0),
		"personal_quest":
		CogitoNet.player_world.quests.journal(true).flags.get("ArchiveAccessed", false),
		"quest_events": _quest_events,
		"cut_used": $Cutscene.has_been_triggered,
	}
	if CogitoNet.is_server():
		data.generation = CogitoNet.player_world.persistence.files.manifest.get("generation", 0)
	if "received_bytes" in multiplayer.multiplayer_peer:
		data.rx = multiplayer.multiplayer_peer.received_bytes
	data.merge(_inventory_sample())
	data.merge(_combat_sample())
	data.merge(_npc_sample())
	var grass: Node = get_node_or_null("FireStand/Grass1")
	data.grass_burning = grass != null and grass.cogito_properties.is_on_fire
	data.grass_removed = grass == null
	data.burn_removals = _burn_removals
	data.flames = $FireStand/Campfire.enabled and $FireStand/Campfire/Flames.visible
	data.merge(_survival_sample())
	var box: RigidBody3D = $CarryBox
	var crate_pos := box.global_position
	var vehicle_pos: Vector3 = $Vehicle.global_position
	var local := CogitoNet.local_player()
	data["crate"] = [crate_pos.x, crate_pos.y, crate_pos.z]
	data["rest"] = box.sleeping
	data["slot_id"] = $Slot.snapped_id
	data["carrying"] = local != null and local.player_interaction_component.carrying.is_carrying
	data["seat"] = $Seat.occupant_id
	data["driver"] = $Vehicle.occupant_id
	data["vehicle"] = [vehicle_pos.x, vehicle_pos.y, vehicle_pos.z]
	print("NET POS ", JSON.stringify(data))


func _survival_sample() -> Dictionary:
	var rows := {}
	var local := CogitoNet.local_player()
	for record in CogitoNet.players():
		var avatar := CogitoNet.player_world.avatar_for(record.player_id)
		if not avatar:
			continue
		var row := {
			"dead": avatar.actor.is_dead,
			"fraction": avatar.health_fraction,
			"locked": avatar.actor.is_movement_locked_by_elements()
		}
		if CogitoNet.is_server() or avatar.actor == local:
			row.health = avatar.actor.player_attributes.health.value_current
		rows[record.display_name] = row
	var screen: CogitoDeathScreen = local.player_hud.get_node("DeathScreen") if local else null
	return {
		"vitals": rows,
		"death_screen": screen != null and screen.visible,
		"can_respawn": screen != null and screen.visible and not screen.load_button.disabled,
		"respawn_error": _respawn_error,
		"paused": get_tree().paused,
		"menu": local != null and local.find_child("PauseMenu", false, false) != null,
	}


func _element_stage(order: Dictionary) -> void:
	var cold: bool = order.place == "cold"
	var stand: Node3D = $ColdStand if cold else $FireStand
	for record in CogitoNet.players():
		var actor := CogitoNet.player_world.avatar_for(record.player_id).actor
		var offset := Vector3(-0.6, 0.91, 2.5)
		if record.display_name != order.first:
			offset = Vector3(-0.9, 0.91, -1.55) if cold else Vector3(-1.6, 0.91, 0.3)
			actor.player_attributes.health.value_current = 100.0
			if cold:
				actor.cogito_properties.make_wet()
				actor.cogito_properties.freeze_time = 2.4
		actor.position = stand.position + offset
		actor.velocity = Vector3.ZERO
		CogitoNet.player_world.mark_teleport(record.player_id)
	if not cold:
		$FireStand/Campfire.damage_per_second = 4.0
		$FireStand/Grass1/CogitoProperties.fuel_remaining = 1.5


func _survival_stage(order: Dictionary) -> void:
	var players := CogitoNet.player_world
	for record in CogitoNet.players():
		var avatar := players.avatar_for(record.player_id)
		var actor := avatar.actor
		var first: bool = record.display_name == order.first
		if order.place == "hazard":
			actor.position = $Hazard.position + Vector3.RIGHT * (0.0 if first else 1.2)
		else:
			actor.position = Vector3(-19, 0.91, 18 if first else 14)
		if order.place == "duel":
			if first:
				avatar.wield._visible_state(false, false)
				var guns := actor.inventory_data.find_slots("Laser Rifle")
				if guns.is_empty():
					var stack := InventorySlotPD.new()
					stack.inventory_item = RIFLE
					GRID.insert(actor.inventory_data, stack, 1, false)
					guns = actor.inventory_data.find_slots("Laser Rifle")
				guns[0].inventory_item.charge_current = 100
				players.inventory.flush_actor(actor)
			else:
				actor.player_attributes.health.value_current = 2
		actor.velocity = Vector3.ZERO
		players.mark_teleport(record.player_id)


func _contents(inv: CogitoInventory) -> Dictionary:
	var totals := {}
	for i in inv.inventory_slots.size():
		var slot := inv.inventory_slots[i]
		if slot and slot.origin_index == i:
			var key := slot.inventory_item.name
			totals[key] = totals.get(key, 0) + slot.quantity
	return totals


func _inventory_sample() -> Dictionary:
	var players := CogitoNet.player_world
	var owners := {}
	for record in CogitoNet.players():
		var avatar := players.avatar_for(record.player_id)
		if avatar and (CogitoNet.is_server() or avatar.actor == CogitoNet.local_player()):
			owners[record.display_name] = {
				"items": _contents(avatar.actor.inventory_data),
				"wallet": avatar.actor.player_currencies.credits.value_current,
			}
	var box: Variant = null
	if CogitoNet.is_server():
		box = _contents($SharedBox.inventory_data)
	elif players.containers.local:
		box = _contents(players.containers.local.data)
	var dropped := players.world.entities.live_object("runtime:1") as RigidBody3D
	return {
		"settled": dropped != null and dropped.sleeping,
		"inventories": owners,
		"box": box,
		"stock": $Vendor.amount_remaining,
		"loose": players.world.entities.live_object("level:loose") != null,
		"drop": players.world.entities.live_object("runtime:1") != null,
		"inventory_ready": players.inventory.local != null and players.inventory.local.revision > 0,
	}


func _inventory_stage(order: Dictionary) -> void:
	var players := CogitoNet.player_world
	for record in CogitoNet.players():
		var actor := players.avatar_for(record.player_id).actor
		var first: bool = record.display_name == order.first
		var point := Vector3(30.3 if first else 31.7, 0.1, 0.7)
		match order.place:
			"start":
				actor.inventory_data.inventory_slots.fill(null)
				if first:
					for resource in ["Battery", "Key"]:
						var stack := InventorySlotPD.new()
						stack.inventory_item = load(
							"res://addons/cogito/InventoryPD/Items/Cogito_%s.tres" % resource
						)
						GRID.insert(actor.inventory_data, stack, 1, false)
				actor.player_currencies.credits.value_current = 20
				actor.inventory_data.inventory_updated.emit(actor.inventory_data)
			"box":
				point.z = -0.5
			"vendor":
				point = Vector3(35.4 if first else 32.2, 0.1, 1.5)
			"drop":
				var object := players.world.entities.live_object("runtime:1") as Node3D
				point = Vector3(24, 0.1, 3) if first else object.position + Vector3(0.5, 0, 0.8)
				point.y = 0.1
		actor.position = point
		actor.velocity = Vector3.ZERO
		players.mark_teleport(record.player_id)


func _inventory_order(order: Dictionary) -> void:
	var players := CogitoNet.player_world
	var api := players.inventory
	var box := players.containers
	var model := box.local if order.action == "take" else api.local
	var slots := model.data.find_slots(order.item)
	if slots.is_empty():
		push_error("Missing fixture stack %s" % order.item)
		return
	var slot := slots[0]
	var args := [slot.origin_index, model.id_of(slot)]
	if order.action == "use":
		api.submit("use", args)
		return
	if order.action == "drop":
		args.append(1)
	else:
		var target := box.local if order.action == "put" else api.local
		args.append_array(
			[target.data.inventory_slots.find(null), 1, 0, box.token, box.local.revision]
		)
	api.submit(order.action, args)


func _combat_event(_actor: CogitoPlayerAdvanced, event: StringName, _point: Vector3) -> void:
	_fires += int(event == &"fire")


func _combat_sample() -> Dictionary:
	var wielded := {}
	var ammo := {}
	var players := CogitoNet.player_world
	for record in CogitoNet.players():
		var avatar := players.avatar_for(record.player_id)
		if not avatar:
			continue
		wielded[record.display_name] = [avatar.wield.public_item.get_file(), avatar.wield.light_on]
		var guns := avatar.actor.inventory_data.find_slots("Laser Rifle")
		if not guns.is_empty():
			ammo[record.display_name] = guns[0].inventory_item.charge_current
	return {
		"wield": wielded,
		"ammo": ammo,
		"shots": _fires,
		"flights": _launches,
		"impacts": _impacts,
		"west": $West/Health.value_current,
		"east": $East/Health.value_current,
		"dart": players.world.entities.live_object("runtime:2") != null,
	}


func _combat_stage(first: String) -> void:
	var players := CogitoNet.player_world
	for record in CogitoNet.players():
		var actor := players.avatar_for(record.player_id).actor
		actor.position = Vector3(-24 if record.display_name == first else -19, 0.1, 0)
		actor.velocity = Vector3.ZERO
		players.mark_teleport(record.player_id)
		for asset: String in ["LaserRifle", "Flashlight", "Dart"]:
			var stack := InventorySlotPD.new()
			stack.inventory_item = load(
				"res://addons/cogito/InventoryPD/Items/Cogito_%s.tres" % asset
			)
			if asset == "Dart" and record.display_name != first:
				continue
			GRID.insert(actor.inventory_data, stack, 1, false)
		actor.inventory_data.find_slots("Laser Rifle")[0].inventory_item.charge_current = 2
		players.inventory.flush_actor(actor)


func _meter_corpse(id: String, node: Node) -> void:
	if node is NetNpcCorpse:
		_corpse_stream = CorpseMeter.new()
		CogitoNet.player_world.bodies._timelines[id] = _corpse_stream


func _npc_sample() -> Dictionary:
	var guard := $Guard as CogitoNPC
	var world := CogitoNet.player_world.world
	var target: String = guard.network_state.target_id
	var corpse: Array = []
	var joints := []
	var loot := 0
	var rest := false
	for id: String in world.entities.objects:
		if not id.begins_with("runtime:"):
			continue
		var body := world.entities.live_object(id) as Node3D
		if body is NetNpcCorpse:
			var p: Vector3 = body.anchor.global_position
			corpse = [p.x, p.y, p.z]
			rest = _corpse_stream.resting if _corpse_stream else body.resting
			for bone: PhysicalBone3D in body.bones:
				var t := bone.global_transform
				var q := t.basis.get_rotation_quaternion()
				joints.append([t.origin.x, t.origin.y, t.origin.z, q.x, q.y, q.z, q.w])
		elif body and body.scene_file_path.ends_with("/pickup_coins.tscn"):
			loot += 1
	return {
		"npc_target": CogitoNet.player_for_id(target).get("display_name", ""),
		"npc_behaviour": guard.current_behaviour,
		"npc_dead": guard.network_state.dead,
		"npc_shots": _npc_shots,
		"npc_deaths": _npc_deaths,
		"corpse": corpse,
		"corpse_bones": joints,
		"corpse_bytes": _corpse_stream.total_bytes if _corpse_stream else 0,
		"corpse_moving_rate": _corpse_rate(),
		"corpse_rest": rest,
		"npc_loot": loot,
		"indicator": guard.sight_detection.sight_suspicion_indicator.visible,
	}


func _corpse_rate() -> float:
	if _corpse_stream and _corpse_stream.first_tick >= 0:
		var ticks := _corpse_stream.rest_tick - _corpse_stream.first_tick
		if ticks > 0:
			return float(_corpse_stream.moving_bytes) * Engine.physics_ticks_per_second / ticks
	return 0.0


func _stage_npc(order: Dictionary) -> void:
	var players := CogitoNet.player_world
	var guard := $Guard as CogitoNPC
	if order.place == "split":
		guard.rotation.y = 0
		guard.sight_detection.buildup_to_investigation_rate = 30
		guard.sight_detection.buildup_to_aggro_rate = 30
	for record in CogitoNet.players():
		var avatar := players.avatar_for(record.player_id)
		var actor := avatar.actor
		var first: bool = order.first == record.display_name
		match order.place:
			"split":
				actor.position = Vector3(25 if first else 31, 0.91, 21)
				actor.player_attributes.health.value_current = 100 if first else 2
				if first:
					var stack := InventorySlotPD.new()
					stack.inventory_item = RIFLE
					GRID.insert(actor.inventory_data, stack, 1, false)
					var rifle: InventorySlotPD = actor.inventory_data.find_slots("Laser Rifle")[0]
					rifle.inventory_item.charge_current = 50
					avatar.wield.equip(rifle)
					players.inventory.flush_actor(actor)
			"reveal":
				if not first:
					continue
				actor.position = guard.position - guard.global_basis.z * 4
				actor.position.y = 0.91
			"aim":
				if not first:
					continue
				guard.health.value_current = 1
				actor.position = guard.position + Vector3(0, 0.91, 3)
			"drag":
				if not first:
					continue
				var corpse := players.world.entities.live_object("runtime:1") as NetNpcCorpse
				var grip := _corpse_grip(corpse, order.grip)
				actor.position = grip.global_position + Vector3(0, 0, 0.9)
				actor.position.y = 0.91
		actor.velocity = Vector3.ZERO
		players.mark_teleport(record.player_id)


func _corpse_grip(corpse: NetNpcCorpse, grip_name: String) -> CogitoCarryableComponent:
	for grip in corpse.find_children("*", "CogitoCarryableComponent", true, false):
		if grip.get_parent().bone_name == grip_name:
			return grip
	return null


func _result(result: Dictionary) -> void:
	print("NET RESULT ", JSON.stringify(result))


func _presented(_id: String, _revision: int, _event: StringName) -> void:
	_presentations += 1


func _execute(order: Dictionary) -> void:
	match order.op:
		"element_stage":
			_element_stage(order)
		"fail_final_write":
			CogitoNet.player_world.persistence.files.storage.fail_before = func(op: String) -> bool:
				return op == "after publish"
		"wallet", "interrupt_save":
			for member in CogitoNet.players():
				if member.display_name == order.who:
					var actor := CogitoNet.player_world.avatar_for(member.player_id).actor
					actor.player_currencies.credits.value_current = order.value
					CogitoNet.player_world.inventory.flush_actor(actor)
			if order.op == "interrupt_save":
				var writer := CogitoNet.player_world.persistence
				writer.files.storage.fail_before = _pause_staging
				writer.request_save()
		"save_world", "quit_host", "quit_client":
			var actor := CogitoNet.local_player() as CogitoPlayerAdvanced
			var menu := actor.pause_menu.instantiate() as CogitoPauseMenu
			actor.add_child(menu)
			if order.op == "quit_client":
				_click_quit.call_deferred(menu)
			elif order.op == "quit_host":
				actor.player_currencies.credits.value_current = order.value
				_click_quit.call_deferred(menu)
			elif (
				menu.save_button.is_visible_in_tree() and not menu.load_button.is_visible_in_tree()
			):
				menu.save_button.pressed.emit()
				CogitoNet.player_world.persistence.save_finished.connect(
					_manual_finished.bind(menu), CONNECT_ONE_SHOT
				)
		"npc_stage":
			_stage_npc(order)
		"aim_at_grip":
			_driver.aim_pitch = -0.75
		"lift_grip":
			_driver.aim_pitch = -0.36
		"drag_corpse":
			var players := CogitoNet.player_world
			var corpse := players.world.entities.live_object("runtime:1")
			var grip := _corpse_grip(corpse, order.grip)
			players.interactions.submit(grip, &"interact2")
		"survival":
			_survival_stage(order)
		"respawn":
			CogitoNet.player_world.death.request_respawn()
		"respawn_button":
			CogitoNet.local_player().player_hud.get_node("DeathScreen").load_button.pressed.emit()
		"escape":
			var event := InputEventAction.new()
			event.action = "menu"
			event.pressed = true
			InputRouter.on_input.emit(event)
		"physics_stage":
			stage_physics(CogitoNet.player_world, order.place, order.first)
		"prepare_grab":
			var api := CogitoNet.player_world.interactions
			_pickup_request = api.make_request($CarryBox/CarryableComponent, &"interact2")
		"throw":
			_driver.throwing = true
		"combat_stage":
			_combat_stage(order.first)
		"fire":
			_driver.combat_lane = true
			_driver.trigger_ticks = order.ticks
			if _loss:
				_loss.muted = false
		"near_dart":
			var players := CogitoNet.player_world
			var dart := players.world.entities.live_object("runtime:2") as Node3D
			for record in CogitoNet.players():
				if record.display_name == order.who:
					var actor := players.avatar_for(record.player_id).actor
					actor.position = dart.position + Vector3(0.4, 0.0, 0.8)
					actor.position.y = 0.1
					players.mark_teleport(record.player_id)
		"take_dart":
			var players := CogitoNet.player_world
			var dart := players.world.entities.live_object("runtime:2")
			players.interactions.submit(dart.get_node("PickupComponent"), &"interact")
		"inventory_stage":
			_inventory_stage(order)
		"inventory":
			_inventory_order(order)
		"close_box":
			CogitoNet.local_player().player_hud.set_inventory_visibility(false)
		"prepare_pickup":
			var api := CogitoNet.player_world.interactions
			_pickup_request = api.make_request($LooseItem/PickupComponent, &"interact")
		"race":
			CogitoNet.player_world.interactions.dispatch(_pickup_request)
		"collect_drop":
			var object := CogitoNet.player_world.world.entities.live_object("runtime:1")
			CogitoNet.player_world.interactions.submit(
				object.get_node("PickupComponent"), &"interact"
			)
		"stage":
			for record in CogitoNet.players():
				var actor := CogitoNet.player_world.avatar_for(record.player_id).actor
				var first: bool = record.display_name == order.first
				actor.position = Vector3(5.3 if first else 6.8, 0.1, -12.6)
				actor.velocity = Vector3.ZERO
				CogitoNet.player_world.mark_teleport(record.player_id)
		"devices":
			for record in CogitoNet.players():
				var actor := CogitoNet.player_world.avatar_for(record.player_id).actor
				var first: bool = record.display_name == order.first
				actor.position = Vector3(19.9 if first else 23.0, 0.1, -10.8)
				actor.velocity = Vector3.ZERO
				if first:
					var stack := InventorySlotPD.new()
					stack.inventory_item = $PickDoor/Pick.required_lockpick_item
					stack.quantity = 2
					stack.origin_index = 0
					actor.inventory_data.inventory_slots[0] = stack
				CogitoNet.player_world.mark_teleport(record.player_id)
		"wheel":
			var api := CogitoNet.player_world.interactions
			var request := api.make_request($Wheel/Hold, &"interact", order.phase)
			if order.phase == "start":
				_wheel_start = request
			else:
				request.expected_revision = _wheel_start.expected_revision
			api.dispatch(request)
		"fix_lock":
			# The fixture sets a reproducible server challenge after exclusive acquisition.
			var devices := CogitoNet.player_world.interactions.devices
			for session: Dictionary in devices._sessions.values():
				if session.has("lock"):
					session.lock.spot = 7.3
		"tension":
			CogitoNet.player_world.interactions.devices.tension(true, 414)
		"enter_zone":
			for record in CogitoNet.players():
				if record.display_name == order.first:
					var actor := CogitoNet.player_world.avatar_for(record.player_id).actor
					actor.position = $Cutscene.position
					actor.velocity = Vector3.ZERO
					CogitoNet.player_world.mark_teleport(record.player_id)
		"probe_crouch":
			_driver.crouch_tap = true
		"walk":
			if _loss:
				_loss.muted = false
			_driver.doorway_ticks = 40
		"use":
			var api := CogitoNet.player_world.interactions
			var component := get_node(String(order.component)) as InteractionComponent
			var request := api.make_request(component, order.get("action", "interact"))
			if order.has("code"):
				request.payload = order.code
			api.dispatch(request)
			if order.get("retry", false):
				api.dispatch(request)


## Put the actors at the entrance to each fixture lane. Subsequent movement uses commands.
func stage_physics(players: Node, place: String, first: String) -> void:
	var crate: RigidBody3D = $CarryBox
	var center := Vector3(6, 0.05, -12.3)
	if place == "seat":
		center = $Seat.position + Vector3(0, 0, 1.25)
	elif place == "vehicle":
		center = $Vehicle.position + Vector3(0, 0, 1.25)
	elif place == "slot":
		center = $Slot.position + Vector3(0, 0, 3.4)
	center.y = 0.05
	for record: Dictionary in players.get_parent().records():
		var actor: CogitoPlayerAdvanced = players.avatar_for(record.player_id).actor
		actor.player_attributes.strength.value_current = 6
		var leading: bool = first in [record.display_name, record.player_id]
		var offset := -0.45 if leading else 0.65
		actor.position = center + Vector3.RIGHT * offset
		actor.body.rotation = Vector3.ZERO
		actor.neck.rotation = Vector3.ZERO
		actor.head.rotation = Vector3.ZERO
		actor.velocity = Vector3.ZERO
		players.mark_teleport(record.player_id)
	if place in ["carry", "slot"]:
		crate.freeze = true
		crate.global_transform = Transform3D(Basis.IDENTITY, center + Vector3(0, 1.25, -1.4))
		crate.linear_velocity = Vector3.ZERO
		crate.angular_velocity = Vector3.ZERO


func _pause_staging(operation: String) -> bool:
	if operation == "write world_scene":
		print("NET STAGING")
		OS.delay_msec(2000)
	return false


func _manual_finished(_err: Error, _generation_id: int, menu: CogitoPauseMenu) -> void:
	print("NET MANUAL ", menu.save_button.text)
	menu.close_pause_menu()


# Press Quit through the window like a player does, so leaving runs from a real button
# event that the level host's SubViewportContainer forwards into the room viewport.
func _click_quit(menu: CogitoPauseMenu) -> void:
	# The headless window is 64x64; give the menu its authored layout.
	get_tree().root.size = Vector2i(1920, 1080)
	await get_tree().process_frame
	await get_tree().process_frame
	var button := menu.find_child("QuitButton", true, false) as Button
	var centre := button.get_global_rect().get_center()
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		click.position = centre
		click.global_position = centre
		get_tree().root.push_input(click)
