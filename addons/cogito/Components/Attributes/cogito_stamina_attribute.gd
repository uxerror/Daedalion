extends CogitoAttribute
class_name CogitoStaminaAttribute

@export var stamina_regen_speed : float = 1
@export var run_exhaustion_speed : float = 1
@export var jump_exhaustion : float = 1
@export var regenerate_after : float = 2
@export var auto_regenerate : bool = true
@export_group("Floor Slope Exhaustion Settings")
## If unused, running only drains stamina at the base run exhaustion speed
@export var use_floor_slope_for_run_exhaustion: bool = true
## The max exhaustion speed whil running uphill
@export var uphill_run_exhaustion_max_speed: float = 6.0
## The max exhaustion speed whil running downhill
@export var downhill_run_exhaustion_max_speed: float = 2.0
## Adjusts the exhaustion speed when detecting vertical motion on steps
@export var step_slope_multiplier: float = 4.0

var regen_timer : Timer
var stamina_regen_wait : float
var is_regenerating : bool
var player : Node3D
# Use for run exhaustion on slopes, to get vertical travel difference per frame
var last_y : float

func _ready() -> void:
	value_current = value_start
	player = get_parent()
	
	regen_timer = Timer.new()
	regen_timer.wait_time = regenerate_after
	add_child(regen_timer)
	regen_timer.timeout.connect(_on_regen_timer_timeout)


func advance_movement_tick(delta: float) -> void:
	if not regen_timer.is_stopped():
		var remaining := regen_timer.time_left - delta
		if remaining <= 0.000001:
			regen_timer.stop()
			_on_regen_timer_timeout()
		else:
			regen_timer.start(remaining)
			regen_timer.wait_time = regenerate_after
	_process(delta)


func _process(delta):
	if is_regenerating:
		add(CogitoMovementStep.Stamina.amount(stamina_regen_speed, delta))
		if value_current >= value_max:
			is_regenerating = false
	
	# Decreases stamina during sprinting
	if player.is_in_sprinting_state() and CogitoMovementStep.Stamina.spends_on_run(
		player.current_speed, player.WALKING_SPEED, player.velocity
	):
		regen_timer.stop()
		is_regenerating = false
		var exhaustion: float = _run_exhaustion()
		subtract(CogitoMovementStep.Stamina.amount(exhaustion, delta))
	last_y = player.global_position.y
	
	if !is_regenerating and regen_timer.is_stopped() and value_current < value_max and !player.is_in_sprinting_state():
		regen_timer.start()


func _on_regen_timer_timeout():
	#if !is_regenerating: # This led to the regen timer to be called every 'regenerate_after'
		#is_regenerating = true
	is_regenerating = value_current < value_max


## Adjusts run exhaustion speed based on floor slope and vertical motion
func  _run_exhaustion() -> float:
	if !use_floor_slope_for_run_exhaustion:
		return run_exhaustion_speed
	
	return CogitoMovementStep.Stamina.run_rate(
		player.movement_floor_normal(), player.main_velocity, player.global_position.y, last_y,
		step_slope_multiplier, run_exhaustion_speed,
		uphill_run_exhaustion_max_speed, downhill_run_exhaustion_max_speed
	)
