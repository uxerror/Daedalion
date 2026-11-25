extends Area3D

signal net_changed(event: StringName)
signal apply_hazard_effect()

## Enter the player attribute that should get drained within the zone.
@export var player_attribute : String
## The amount that gets drained each second. Higher -> faster.
@export var drain_amount : float = 2
## This flag sets the zone to be recovering instead of draining an attribute.
@export var is_recovery_zone : bool = false
## Hint icon that appears when player enters the zone.
@export var hint_icon : Texture2D
## Hint text that appears when player enteres the zone. Leave blank if you don't want a hint to appear.
@export var hint_message : String
## Used to activate / deactivate this zone on runtime.
@export var is_active : bool = true

var _occupants := {}


func _ready() -> void:
	set_process(false)


func _on_body_entered(body: Node3D) -> void:
	if not body is CogitoPlayer or (body.network_movement_only and not body.multiplayer.is_server()):
		return
	if _occupants.has(body):
		return
	body.tree_exiting.connect(_on_body_exited.bind(body), CONNECT_ONE_SHOT)
	set_process(true)
	_occupants[body] = true
	if hint_message != "":
		body.player_interaction_component.send_hint(hint_icon, tr(hint_message))


func _on_body_exited(body: Node3D) -> void:
	if _occupants.erase(body):
		var cleanup := _on_body_exited.bind(body)
		if body.tree_exiting.is_connected(cleanup):
			body.tree_exiting.disconnect(cleanup)
		set_process(not _occupants.is_empty())


func interact(_player_interaction_component: PlayerInteractionComponent) -> void:
	is_active = not is_active
	monitoring = is_active
	net_changed.emit(&"toggle")


## MP2 baseline for an authored switchable zone.
func net_state() -> Dictionary:
	return {"active": is_active}


## Install presentation state without evaluating replica occupants.
func apply_net_state(state: Dictionary, _silent: bool) -> void:
	is_active = state.active


func _process(delta: float) -> void:
	if not is_active:
		return
	for player: CogitoPlayer in _occupants:
		if is_recovery_zone:
			player.increase_attribute(
				player_attribute, drain_amount * delta, ConsumableItemPD.ValueType.CURRENT
			)
		else:
			player.decrease_attribute(player_attribute, drain_amount * delta)
