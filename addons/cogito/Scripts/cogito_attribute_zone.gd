extends Area3D

signal net_changed(event: StringName)
signal apply_attribute_effect()

## Enter the player attribute that is effected within the zone.
@export var player_attribute: String
@export var increase_attribute: bool
## The amount an attribute is changed while in the zone, either immediately or over time based on the effect delay.
@export_range(0.0, 10.0, 0.01, "or_greater") var effect_amount: float = 5.0
## The delay time between effect calls. A value of 0 will change the amount over time.
@export_range(0.0, 10.0, 0.01, "or_greater") var effect_delay: float = 2.0
## On zone enter sets the effect delay to zero to cause an immediate effect on the attribute.
@export var skip_delay_on_zone_enter: bool = true
## Hint icon that appears when player enters the zone.
@export var hint_icon: Texture2D
## Hint text that appears when player enteres the zone. Leave blank if you don't want a hint to appear.
@export var hint_message: String
## Adds a hint message at this rate of effect. Only works when using a delay.
## For example, a rate of 5 will show the hint after every 5 times the attribute is changed by the zone.
## A rate of 0 won't show the hint again after entering the zone.
@export_range(0, 10, 1, "or_greater") var hint_rate: int = 5
## Used to activate / deactivate this zone on runtime.
@export var is_active: bool = true

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
	_occupants[body] = {
		"delay": 0.0 if skip_delay_on_zone_enter else effect_delay,
		"hints": 0.0,
	}
	if effect_amount > 0 and hint_message != "":
		body.player_interaction_component.send_hint(hint_icon, hint_message)


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
		var clock: Dictionary = _occupants[player]
		clock.delay -= delta
		if clock.delay > 0 or effect_amount == 0:
			continue
		clock.delay = effect_delay
		var amount := effect_amount if effect_delay > 0 else effect_amount * delta
		if increase_attribute:
			player.increase_attribute(player_attribute, amount, ConsumableItemPD.ValueType.CURRENT)
		else:
			player.decrease_attribute(player_attribute, amount)
		if hint_rate > 0 and hint_message != "":
			clock.hints += 1.0 if effect_delay > 0 else delta
			if clock.hints >= hint_rate:
				clock.hints = 0.0
				player.player_interaction_component.send_hint(hint_icon, hint_message)
