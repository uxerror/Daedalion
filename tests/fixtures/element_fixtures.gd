extends RefCounted

const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const NPC := preload("res://addons/cogito/CogitoNPC/cogito_npc.tscn")


class Holder:
	extends StaticBody3D
	signal damage_received(
		amount: float, source: Node, hit_direction: Vector3, hit_position: Vector3
	)
	var cogito_properties: CogitoProperties
	var taken := 0.0

	func _init() -> void:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE * 0.5
		shape.shape = box
		add_child(shape)
		damage_received.connect(func(amount, _source, _direction, _position): taken += amount)


class RigidHolder:
	extends RigidBody3D
	signal damage_received(
		amount: float, source: Node, hit_direction: Vector3, hit_position: Vector3
	)
	var cogito_properties: CogitoProperties
	var taken := 0.0

	func _init() -> void:
		gravity_scale = 0.0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE * 0.5
		shape.shape = box
		add_child(shape)
		damage_received.connect(func(amount, _source, _direction, _position): taken += amount)


class PlayerWorld:
	extends Node3D

	var _player: CogitoPlayerAdvanced
	var _previous_player: Node
	var _previous_scene: Node
	var _previous_mouse_mode: Input.MouseMode

	func _enter_tree() -> void:
		_previous_player = CogitoSceneManager.get_player()
		_previous_scene = get_tree().current_scene
		_previous_mouse_mode = Input.mouse_mode
		get_tree().current_scene = self

	func restore() -> void:
		if is_instance_valid(_player):
			InputRouter.remove(_player.on_input)
		CogitoSceneManager._current_player_node = _previous_player
		get_tree().current_scene = _previous_scene
		Input.mouse_mode = _previous_mouse_mode

	func spawn_player(pos: Vector3) -> CogitoPlayerAdvanced:
		_player = PLAYER.instantiate()
		_player.inventory_data = _player.inventory_data.duplicate(true)
		_player.position = pos
		add_child(_player)
		for _frame in 10:
			await get_tree().physics_frame
		return _player


class RestoreSignals:
	var reactions: Array = []
	var state_signals := 0
	var damage := 0.0
	var restored := 0

	func _init(original: CogitoProperties) -> void:
		original.reaction_triggered.connect(func(r): reactions.append(r))
		original.elemental_damage_taken.connect(func(a, _e, _s): damage += a)
		original.element_state_restored.connect(func(): restored += 1)
		for sig in [
			original.has_ignited,
			original.has_been_extinguished,
			original.has_become_wet,
			original.has_become_dry,
			original.has_become_electric,
			original.has_lost_electricity,
			original.has_become_chilled,
			original.has_warmed_up,
			original.has_frozen,
			original.has_thawed,
			original.has_been_poisoned,
			original.has_been_cured,
			original.burned_out,
		]:
			sig.connect(func(): state_signals += 1)

	func quiet() -> bool:
		return reactions.is_empty() and state_signals == 0 and damage == 0.0


static func make_npc() -> CogitoNPC:
	return NPC.instantiate()
