class_name UiHoldComponent
extends Control

## Buffer time until the hold is first registered, prevents showing Hold UI for presses
@export var buffer_time : float = 0.1  
@export var prompt_area: VBoxContainer

@onready var progress_wheel: CogitoProgressWheel = $ProgressWheel
@onready var hold_timer: Timer = $HoldTimer

var hold_interaction: HoldInteraction
var is_holding : bool = false
var player_interaction_component: PlayerInteractionComponent


func _ready() -> void:
	hide()
	progress_wheel.current_value = 0.0
	hold_timer.timeout.connect(_on_hold_complete)


func _process(_delta: float) -> void:
	if is_holding and hold_interaction:
		if hold_timer.time_left  < hold_timer.wait_time-buffer_time:
			show()
		if player_interaction_component.network_interactions:
			progress_wheel.current_value = 1 - hold_timer.time_left / maxf(hold_timer.wait_time, 0.001)
			return
		hold_interaction.is_being_held.emit(hold_timer.time_left, _delta)
		progress_wheel.current_value = 1 - (hold_timer.time_left / hold_interaction.hold_time)
		
		var interaction_distance = (hold_interaction.parent_node.global_position - player_interaction_component.global_position).length()
		if interaction_distance >= player_interaction_component.targeting.get_reach() :
			stop_holding()
	elif hold_interaction:
		stop_holding()


func _unhandled_input(event: InputEvent) -> void:
	if player_interaction_component and player_interaction_component.player is CogitoPlayerAdvanced:
		return # Advanced delivers releases in command order, including very short taps.
	if is_holding and event.is_action_released(hold_interaction.input_map_action):
		release_action(hold_interaction.input_map_action)


## Accept a routed release as well, including a tap completed between physics ticks.
func release_action(action: StringName) -> void:
	if is_holding and hold_interaction.input_map_action == action:
		if not player_interaction_component.network_interactions:
			hold_interaction.perform_quick_action(player_interaction_component)
		stop_holding()


func _on_hold_complete():
	if player_interaction_component and player_interaction_component.network_interactions:
		return # The server evaluates the release. This timer only draws progress.
	hold_interaction.perform_hold_action(player_interaction_component)
	stop_holding()


func start_holding(_hold_interaction: HoldInteraction) -> void:
	if !is_holding:
		
		# Aligns the progress wheel with the prompt, for feedback on which prompt is being interacted with
		var pixel_y_offset: float = 0
		for node in prompt_area.get_children(false):
			if node is UiPromptComponent and (node as UiPromptComponent).interaction_text.text == _hold_interaction.interaction_text:
				var x_offset: float = progress_wheel.radius * -2.0
				var y_offset: float = (node.size.y * 0.5) + pixel_y_offset
				position = Vector2(x_offset, y_offset)
				break
			else:
				pixel_y_offset += node.size.y
		
		is_holding = true
		hold_interaction = _hold_interaction
		hold_timer.wait_time = hold_interaction.hold_time
		progress_wheel.current_value = 1 - (hold_timer.time_left / hold_interaction.hold_time)
		hold_timer.start()
		hold_interaction = _hold_interaction


func stop_holding() -> void:
	hold_timer.stop()
	hide()
	is_holding = false
	hold_interaction = null
	progress_wheel.current_value = 0.0
