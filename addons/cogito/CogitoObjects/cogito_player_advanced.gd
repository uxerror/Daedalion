@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoPlayer.svg")
## The player class controls movement from input from the mouse, keyboard, and gamepad, as well as behavior parameters like stair and ladder handling.
class_name CogitoPlayerAdvanced
extends CogitoPlayer

const ACTION := CogitoPlayerCommand.Action

signal mouse_movement(relative_mouse_movement:Vector2)


#region Variables
## Reference to Pause menu node
@export var pause_menu : PackedScene

## Ledge Climbing Shapecast
@export var ledge_climbing_shapecast : ShapeCast3D

## Damage the player takes if falling from great height. Leave at 0 if you don't want to use this.
@export var fall_damage : int
## Fall velocity at which fall damage is triggered. This is negative y-Axis. -5 is a good starting point but might be a bit too sensitive.
@export var fall_damage_threshold : float = -6


## Player can't open the pause menu in these states.
@export_node_path("StateChartState") var no_pause_menu_states: Array[NodePath]
## Player can't interact in these states.
@export_node_path("StateChartState") var no_interaction_states: Array[NodePath]

@export_group("Audio")
## AudioStream that gets played when the player jumps.
@export var jump_sound : AudioStream
## AudioStream that gets played when the player slides (sprint + crouch).
@export var slide_sound : AudioStream
@export var swim_movement_sound : AudioStream
@export var swim_under_water_sound : AudioStream
@export_subgroup ("Footstep Audio")
@export var walk_volume_db : float = -38.0
@export var sprint_volume_db : float = -30.0
@export var crouch_volume_db : float = -60.0
## the time between footstep sounds when walking
@export var walk_footstep_interval : float = 0.6
## the time between footstep sounds when sprinting
@export var sprint_footstep_interval : float = 0.3
## the speed at which the player must be moving before the footsteps change from walk to sprint.
@export var footstep_interval_change_velocity : float = 5.2

@export_subgroup ("Landing Audio")
## Threshold for triggering landing sound
@export var landing_threshold = -2.0  
## Defines Maximum velocity (in negative) for the hardest landing sound
@export var max_landing_velocity = -8
## Defines Minimum velocity (in negative) for the softest landing sound
@export var min_landing_velocity = -2
## Max volume in dB for the landing sound
@export var max_volume_db = 0
## Min volume in dB for the landing sound
@export var min_volume_db = -40
## Highest pitch for lightest landing sound
@export var max_pitch = 0.8
## Lowest pitch for hardest landing sound
@export var min_pitch = 0.7
#Setup Dynamic Pitch & Volume for Landing Audio, used to store velocity based results
## An actor-addressed takeover consumes sequences with neutral movement and look.
var network_input_blocked := false
var landing_pitch: float = 1.0
var landing_volume: float = 0.8

@export_group("Movement Properties")
@export var MIN_SPEED : float= 0.5
@export var MAX_SPEED : float= 12.0
@export var JUMP_VELOCITY : float= 4.5
@export var CROUCH_JUMP_VELOCITY : float = 3.0
@export var WALKING_SPEED : float = 5.0
@export var SPRINTING_SPEED : float = 8.0
@export var CROUCHING_SPEED : float = 3.0
@export var CROUCHING_DEPTH : float = -0.9
@export var CAN_CROUCH_JUMP = true
@export var MOUSE_SENS : float = 0.25
@export var LERP_SPEED : float = 10.0
@export var AIR_LERP_SPEED : float = 6.0
@export var FREE_LOOK_TILT_AMOUNT : float = 5.0
@export var SLIDING_SPEED : float = 5.0
@export var SLIDE_JUMP_MOD : float = 1.5
@export var disable_roll_anim : bool = false
@export var CAN_BUNNYHOP : bool = true
@export var BUNNY_HOP_ACCELERATION : float = 0.1
@export var BUNNY_HOP_WALL_SLIDE_ANGLE : int = 120
@export var INVERT_Y_AXIS : bool = true
## Controled by the game config. If false, player has to hold the crouch key to stay crouched.
@export var TOGGLE_CROUCH : bool = false
## How much strength the player has to push RigidBody3D objects.
@export var PLAYER_PUSH_FORCE : float = 1.3
@export var LANDING_MIN_VELOCITY : float = -6.0
@export var LANDING_MIN_ROLL_VELOCITY : float = -8.5
@export var FREE_FALL_MIN_VELOCITY : float = -15
@export var FREE_FALL_MIN_DIE_VELOCITY : float = -40

@export_group("Headbob Properties")
## Head bob strength. Currently controlled/overridden by the in-game options.
@export_enum("Minimal:0.1", "Average:0.7", "Full:1") var HEADBOBBLE : int
@export var WIGGLE_ON_WALKING_INTENSITY : float = 0.03
@export var WIGGLE_ON_WALKING_SPEED : float = 12.0
@export var WIGGLE_ON_SPRINTING_INTENSITY : float = 0.05
@export var WIGGLE_ON_SPRINTING_SPEED : float = 16.0
@export var WIGGLE_ON_CROUCHING_INTENSITY : float = 0.08
@export var WIGGLE_ON_CROUCHING_SPEED : float = 8.0
@export var WIGGLE_ON_SWIMMING_INTENSITY : float = 0.08
@export var WIGGLE_ON_SWIMMING_SPEED : float = 6.0

@export_group("Stair Handling")
## This sets the camera smoothing when going up/down stairs as the player snaps to each stair step.
@export var step_height_camera_lerp : float = 2.5
## This sets the height of what is still considered a step (instead of a wall/edge)
@export var STEP_HEIGHT_DEFAULT : Vector3 = Vector3(0, 0.5, 0)
## This sets the step slope degree check. When set to 0, tiny edges etc might stop the player in it's tracks. 1 seems to work fine.
@export var STEP_MAX_SLOPE_DEGREE : float = 0.0

@export_group("Ladder Handling")
var on_ladder : bool = false
@export var CAN_SPRINT_ON_LADDER : bool = false
@export var LADDER_SPEED : float = 2.0
@export var LADDER_SPRINT_SPEED : float = 3.3
@export var LADDER_COOLDOWN : float = 0.5
const LADDER_JUMP_SCALE : float = 0.5
var ladder_on_cooldown : bool = false

@export_group("Ledge Handling")
@export var CAN_CLIMB_LEDGE : bool = true
@export var AUTO_STAND_AFTER_CLIMB : bool = false
@export var CLIMBING_SPEED : float = 2.5
@export var ARM_LENGTH : float = 0.7
@export var MIN_FREE_SPACE_ABOVE_HEAD : float = 0.1
@export var MIN_CLIMB_HEIGHT : float = 1.3

@export_group("Swim Handling")
@export var SWIMMING_SPEED : float = 3.0
@export var WATER_GRAVITY_COEFFICIENT = 0.25
@export var AUTO_STAND_AFTER_SWIM : bool = false

@export_group("Gamepad Properties")
@export var JOY_DEADZONE : float = 0.25
@export var JOY_V_SENS : float = 2
@export var JOY_H_SENS : float = 2

### WIGGLE MODIFIERS
var WIGGLE_INTENSITY_MODIFIER = 1


## STAIR HANDLING STUFF
const WALL_MARGIN : float = 0.001
const STEP_DOWN_MARGIN : float = 0.01
const STEP_CHECK_COUNT : int = 2
const SPEED_CLAMP_AFTER_JUMP_COEFFICIENT : float = 0.3
var STEP_HEIGHT_IN_AIR_DEFAULT : Vector3 = STEP_HEIGHT_DEFAULT
var is_enabled_stair_stepping_in_air : bool = true
var step_check_height : Vector3 = STEP_HEIGHT_DEFAULT / STEP_CHECK_COUNT
var gravity_vec : Vector3 = Vector3.ZERO
var head_offset : Vector3 = Vector3.ZERO
var is_jumping_started : bool = false
var is_in_air : bool = false

var input_direction : Vector2 = Vector2.ZERO

## Assign an independent source before adding this actor to the tree.
var input_source: CogitoPlayerInputSource
## Intent sampled before this tick's state chart callbacks.
var current_command := CogitoPlayerCommand.new()
## Acknowledgement hook for the last accepted sequence.
var last_consumed_sequence: int = -1
var _input_suspended := false
 
var initial_carryable_height #DEPRECATED Used to change carryable position based if player is standing or crouching

var config = ConfigFile.new()

var initial_collision_mask: int = 0
var current_speed : float = 5.0
var current_lerp_speed : float = LERP_SPEED
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var gravity_vector = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
var last_velocity : Vector3= Vector3.ZERO
var direction : Vector3 = Vector3.ZERO
var is_free_looking : bool  = false
var is_roll_animation_finished : bool = false
var is_in_unpausable_state : bool = false
var is_in_interaction_state : bool = true
var slide_audio_player : AudioStreamPlayer3D
var swim_under_water_audio_player : AudioStreamPlayer3D
var standing_height : float
var crouching_height : float
var ledge_climbing_shapecast_height : float
var ledge_climbing_shapecast_initial_position : Vector3

#var external_gravity_force : Vector3 = Vector3.ZERO

# Node caching
@onready var neck: Node3D = $Body/Neck
@onready var eyes: Node3D = $Body/Neck/Head/Eyes
@onready var _aim: Node3D = $Body/Neck/Head/Eyes/Camera
@onready var camera: Camera3D = _aim as Camera3D
@onready var animationPlayer: AnimationPlayer = $Body/Neck/Head/Eyes/AnimationPlayer
@onready var swimming_head_shapecast: ShapeCast3D = $Body/Neck/Head/Eyes/Camera/SwimmingHeadShapeCast
@onready var under_water_effect: ColorRect = get_node_or_null("GUI/Panel/AspectRatioContainer/UnderWaterEffect")
@onready var crouch_shapecast: ShapeCast3D = $CrouchShapeCast

@onready var standing_collision_shape: CollisionShape3D = $StandingCollisionShape
@onready var crouching_collision_shape: CollisionShape3D = $CrouchingCollisionShape

@onready var sliding_timer: Timer = $SlidingTimer
@onready var jump_timer: Timer = $JumpCooldownTimer

# Adding carryable position for item control.
@onready var footstep_surface_detector : FootstepSurfaceDetector = $FootstepPlayer

#Navigation agent for Player auto seat exit handling
@onready var navigation_agent = $NavigationAgent3D

## performance saving variable
@onready var footstep_interval_change_velocity_square : float = footstep_interval_change_velocity * footstep_interval_change_velocity

# Cache allocation of test motion parameters.
@onready var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()

@onready var self_rid: RID = self.get_rid()
@onready var test_motion_result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()

@onready var wieldables = %Wieldables

@onready var state_chart: StateChart = $StateChart
#endregion


func _enter_tree() -> void:
	if is_local_presentation:
		return
	# Remove local-only subtrees before their input, HUD and device callbacks register.
	if has_node("GUI"):
		player_hud = null
		$GUI.free()
	var view := get_node("Body/Neck/Head/Eyes/Camera") as Camera3D
	if view:
		# A viewport automatically selects its first Camera3D even with current = false.
		# Retain the animated aim transform, its casts and the legacy save path.
		var aim := Node3D.new()
		aim.transform = view.transform
		view.replace_by(aim)
		aim.name = "Camera"
		view.free()
	# Dedicated roll completion follows physics time even without rendering.
	$Body/Neck/Head/Eyes/AnimationPlayer.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS


func _ready():
	#Some Setup steps
	if uid == -1:
		uid = get_instance_id()
	
	initial_collision_mask = collision_mask
	if inventory_data:
		if not is_local_presentation:
			inventory_data = inventory_data.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
		inventory_data.owner = self
	
	if is_local_presentation:
		CogitoSceneManager.register_player(self)
		$GUI/Panel/AspectRatioContainer/StateChartDebugger.enabled = CogitoGlobals.cogito_settings.is_state_chart_debugger_enabled
		if not input_source:
			input_source = CogitoLocalInputSource.new()
	elif not input_source or input_source is CogitoLocalInputSource:
		input_source = CogitoPlayerInputSource.new()
	player_interaction_component.interaction_raycast = $Body/Neck/Head/Eyes/Camera/InteractionRaycast
	player_interaction_component.exclude_player(get_rid())
	
	
	randomize() 
	
	radius = _calculate_player_radius()
	
	if standing_collision_shape.shape is BoxShape3D:
		standing_height = standing_collision_shape.shape.size.y
	elif standing_collision_shape.shape is CylinderShape3D or standing_collision_shape.shape is CapsuleShape3D:
		standing_height = standing_collision_shape.shape.height
		
	if crouching_collision_shape.shape is BoxShape3D:
		crouching_height = crouching_collision_shape.shape.size.y
	elif crouching_collision_shape.shape is CylinderShape3D or crouching_collision_shape.shape is CapsuleShape3D:
		crouching_height = crouching_collision_shape.shape.height
	
	ledge_climbing_shapecast.add_exception(self)
	
	ledge_climbing_shapecast_initial_position = ledge_climbing_shapecast.position
	
	if ledge_climbing_shapecast.shape is BoxShape3D:
		ledge_climbing_shapecast_height = ledge_climbing_shapecast.shape.size.y
	elif ledge_climbing_shapecast.shape is CylinderShape3D or ledge_climbing_shapecast.shape is CapsuleShape3D:
		ledge_climbing_shapecast_height = ledge_climbing_shapecast.shape.height
	
	crouch_shapecast.add_exception(self)

	setup_attributes_and_currencies()
	setup_elements()
	if actor_elements:
		actor_elements.stunned.connect(_on_element_stunned)
	
	_initialize_state_chart()
	if is_local_presentation:
		_reload_options()
		CogitoSceneManager.sit_requested.connect(_on_sit_requested)
		CogitoSceneManager.stand_requested.connect(_on_stand_requested)
		CogitoSceneManager.seat_move_requested.connect(_on_seat_move_requested)

	CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Player has no reference to pause menu.")

	call_deferred("slide_audio_init")
	call_deferred("swim_audio_init")
	
	if is_local_presentation:
		Input.mouse_mode = gameplay_mouse_mode
		InputRouter.active_changed.connect(_on_input_owner_changed)
		InputRouter.push(on_input)


func _exit_tree() -> void:
	if is_local_presentation:
		InputRouter.active_changed.disconnect(_on_input_owner_changed)
		InputRouter.remove(on_input)


func neutral_command(sequence: int) -> CogitoPlayerCommand:
	var command := super.neutral_command(sequence)
	command.neck_yaw = neck.rotation.y
	command.toggle_crouch = TOGGLE_CROUCH
	return command


## The animated eye transform is also available on an avatar without a viewport camera.
func get_aim_transform() -> Transform3D:
	return _aim.global_transform


func _on_input_owner_changed() -> void:
	_input_suspended = not InputRouter.is_input_active(self)
	if not _input_suspended or not is_node_ready():
		return
	if input_source is CogitoLocalInputSource:
		input_source.clear()
	current_command = neutral_command(last_consumed_sequence)
	current_command.has_control = false
	player_interaction_component.release_held_actions()
	var hud := player_hud as CogitoPlayerHudManager
	if hud and hud.hold_ui and hud.hold_ui.is_holding:
		hud.hold_ui.stop_holding()


func create_new_state() -> CogitoPlayerState:
	return CogitoPlayerAdvancedState.new()


func slide_audio_init():
	#setup sound effect for sliding
	slide_audio_player = AudioStreamPlayer3D.new()
	slide_audio_player.stream = slide_sound
	slide_audio_player.bus = OptionsConstants.sfx_bus_name
	add_child(slide_audio_player)


func swim_audio_init():
	#setup sound effect for swimming
	swim_under_water_audio_player = AudioStreamPlayer3D.new()
	swim_under_water_audio_player.stream = swim_under_water_sound
	swim_under_water_audio_player.bus = OptionsConstants.sfx_bus_name
	add_child(swim_under_water_audio_player)


# reload options user may have changed while paused.
func _reload_options():
	var err = config.load(OptionsConstants.config_file_name)
	if err == 0:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Options reloaded.")
		
		HEADBOBBLE = config.get_value(OptionsConstants.section_name, OptionsConstants.head_bobble_key, 1)
		MOUSE_SENS = config.get_value(OptionsConstants.section_name, OptionsConstants.mouse_sens_key, 0.25)
		INVERT_Y_AXIS = config.get_value(OptionsConstants.section_name, OptionsConstants.invert_vertical_axis_key, true)
		TOGGLE_CROUCH = config.get_value(OptionsConstants.section_name, OptionsConstants.toggle_crouching_key, true)
		JOY_H_SENS = config.get_value(OptionsConstants.section_name, OptionsConstants.gp_looksens_key, 2)
		JOY_V_SENS = config.get_value(OptionsConstants.section_name, OptionsConstants.gp_looksens_key, 2)


# Signal from Pause Menu
func _on_pause_menu_resume() -> void:
	_reload_options()
	if not CogitoNet.is_online():
		resume()


func _on_pause_menu_pause() -> void:
	if not CogitoNet.is_online():
		pause()


func pause() -> void:
	state_chart.send_event("pause")


func resume() -> void:
	is_in_unpausable_state = false
	is_in_interaction_state = true
	state_chart.send_event("resume")


## Compatibility entry point for InputRouter and custom local input callers.
func on_input(event: InputEvent) -> void:
	if is_local_presentation and input_source is CogitoLocalInputSource:
		input_source.on_input(self, event)


func _handle_menu() -> void:
	if CogitoSceneManager.is_currently_loading: return
	
	if is_showing_ui: #Behaviour when pressing ESC/menu while external UI is open (Readables, Keypad, etc)
		menu_pressed.emit(player_interaction_component)
	elif !is_in_unpausable_state and !is_dead:
		if !currently_tweening:
			if pause_menu:
				var current_pause_menu = pause_menu.instantiate()
				current_pause_menu.pause_menu_closed.connect(_on_pause_menu_resume)
				current_pause_menu.pause_menu_opened.connect(_on_pause_menu_pause)
				add_child(current_pause_menu)
			else:
				CogitoGlobals.debug_log(true, "cogito_player_advanced", "Unable to open Pause Menu! Player has no reference to a Pause Menu PackedScene!")
		else:
			player_interaction_component.send_hint(null, "Wait until I’m seated or standing")


## Notifies first-person wieldables of immediate look motion.
func report_mouse_movement(movement: Vector2) -> void:
	mouse_movement.emit(movement)


## Passes a local presentation event to the configured quickslot views.
func handle_quickslot_input(event: InputEvent) -> void:
	if network_movement_only:
		return
	var fp_hud : CogitoPlayerHudManager = player_hud as CogitoPlayerHudManager
	if fp_hud and fp_hud.inventory_interface and fp_hud.inventory_interface.quick_slots and can_act():
		fp_hud.inventory_interface.quick_slots.on_input(event)


## A stun ends held wieldable actions (e.g. automatic fire).
func _on_element_stunned() -> void:
	var wieldables_handler := player_interaction_component.wieldables
	if wieldables_handler.primary_action_held:
		wieldables_handler.primary_action_held = false
		if wieldables_handler.is_wielding and !player_interaction_component.carrying.is_carrying:
			wieldables_handler.attempt_action_primary(true)


## True while an element state (frozen, stunned) keeps the player from moving, crouching or climbing.
func is_movement_locked_by_elements() -> bool:
	return actor_elements != null and actor_elements.is_movement_locked()


func get_params(transform3d, motion):
	var params : PhysicsTestMotionParameters3D = _params
	params.from = transform3d
	params.motion = motion
	params.recovery_as_collision = true
	return params


func test_motion(transform3d: Transform3D, motion: Vector3) -> bool:
	return PhysicsServer3D.body_test_motion(self_rid, get_params(transform3d, motion), test_motion_result)	


## The local sampler uses the same free-look rule as the animation.
func free_look_requested(command: CogitoPlayerCommand) -> bool:
	return command.is_held(ACTION.FREE_LOOK) or !sliding_timer.is_stopped() or current_moving_state == MovingState.Rolling


func _free_look(delta):
	if free_look_requested(current_command):
		is_free_looking = true
		if sliding_timer.is_stopped():
			eyes.rotation.z = -deg_to_rad(
				neck.rotation.y * FREE_LOOK_TILT_AMOUNT
			)
		else:
			eyes.rotation.z = lerp(
				eyes.rotation.z,
				deg_to_rad(4.0), 
				delta * LERP_SPEED
			)
	else:
		is_free_looking = false
		eyes.rotation.z = lerp(
			eyes.rotation.z,
			0.0,
			delta*LERP_SPEED
		)


func _stair_handling(delta):
	if not is_jumping_started and is_on_floor():
		is_jumping_started = false
		is_in_air = false
	else:
		is_in_air = true
		
	var step_result : StepResult = StepResult.new()
	
	var is_step : bool = step_check(delta, is_jumping_started, step_result)
	
	if is_step:
		var is_enabled_stair_stepping: bool = true
		if step_result.is_step_up and is_in_air and not is_enabled_stair_stepping_in_air:
			is_enabled_stair_stepping = false

		if is_enabled_stair_stepping:
			global_transform.origin += step_result.diff_position
			head_offset = step_result.diff_position
			head.position -= head_offset
			head.position.y = lerp(head.position.y, 0.0, delta * step_height_camera_lerp)#TODO * 10
	else:
		head_offset = head_offset.lerp(Vector3.ZERO, delta * LERP_SPEED)
		#head.position.y = lerp(head.position.y, 0.0, delta * step_height_camera_lerp)
	
	if is_step and step_result.is_step_up and is_enabled_stair_stepping_in_air:
		if is_in_air or direction.dot(step_result.normal) > 0:
			main_velocity *= SPEED_CLAMP_AFTER_JUMP_COEFFICIENT
			gravity_vec *= SPEED_CLAMP_AFTER_JUMP_COEFFICIENT

	if is_jumping_started:
		is_jumping_started = false
		is_in_air = true


func step_check(delta: float, is_jumping_started_: bool, step_result: StepResult):
	var is_step: bool = false
	
	var step_height_main: Vector3 = STEP_HEIGHT_DEFAULT
	var step_incremental_check_height: Vector3 = STEP_HEIGHT_DEFAULT / STEP_CHECK_COUNT
	
	if is_in_air and is_enabled_stair_stepping_in_air:
		step_height_main = STEP_HEIGHT_IN_AIR_DEFAULT
		step_incremental_check_height = STEP_HEIGHT_IN_AIR_DEFAULT / STEP_CHECK_COUNT
		
	if main_velocity.y >= 0:
		for i in range(STEP_CHECK_COUNT):
			var test_motion_result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
			
			var step_height: Vector3 = step_height_main - i * step_incremental_check_height
			var transform3d: Transform3D = global_transform
			var motion: Vector3 = step_height
			var test_motion_params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
			test_motion_params.from = transform3d
			test_motion_params.motion = motion
			
			var is_player_collided: bool = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)

			if is_player_collided and test_motion_result.get_collision_normal().y < 0:
				continue

			transform3d.origin += step_height
			motion = main_velocity * delta
			test_motion_params.from = transform3d
			test_motion_params.motion = motion
			
			is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
			
			if not is_player_collided:
				transform3d.origin += motion
				motion = -step_height
				test_motion_params.from = transform3d
				test_motion_params.motion = motion
				
				is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
				
				if is_player_collided:
					if test_motion_result.get_collision_normal().angle_to(Vector3.UP) <= deg_to_rad(STEP_MAX_SLOPE_DEGREE):
						is_step = true
						step_result.is_step_up = true
						step_result.diff_position.y = -test_motion_result.get_remainder().y
						step_result.normal = test_motion_result.get_collision_normal()
						break
			else:
				var wall_collision_normal: Vector3 = test_motion_result.get_collision_normal()
				transform3d.origin += wall_collision_normal * WALL_MARGIN
				motion = (main_velocity * delta).slide(wall_collision_normal)
				test_motion_params.from = transform3d
				test_motion_params.motion = motion
				
				is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
				
				if not is_player_collided:
					transform3d.origin += motion
					motion = -step_height
					test_motion_params.from = transform3d
					test_motion_params.motion = motion
					
					is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
					
					if is_player_collided:
						if test_motion_result.get_collision_normal().angle_to(Vector3.UP) <= deg_to_rad(STEP_MAX_SLOPE_DEGREE):
							is_step = true
							step_result.is_step_up = true
							step_result.diff_position.y = -test_motion_result.get_remainder().y
							step_result.normal = test_motion_result.get_collision_normal()
							break

	if not is_jumping_started_ and not is_step and is_on_floor():
		step_result.is_step_up = false
		var test_motion_result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
		var transform3d: Transform3D = global_transform
		var motion: Vector3 = main_velocity * delta
		var test_motion_params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
		test_motion_params.from = transform3d
		test_motion_params.motion = motion
		test_motion_params.recovery_as_collision = true

		var is_player_collided: bool = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
			
		if not is_player_collided:
			transform3d.origin += motion
			motion = -step_height_main
			test_motion_params.from = transform3d
			test_motion_params.motion = motion
			
			is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
			
			if is_player_collided and test_motion_result.get_travel().y < -STEP_DOWN_MARGIN:
				if test_motion_result.get_collision_normal().angle_to(Vector3.UP) <= deg_to_rad(STEP_MAX_SLOPE_DEGREE):
					is_step = true
					step_result.diff_position.y = test_motion_result.get_travel().y
					step_result.normal = test_motion_result.get_collision_normal()
		elif is_zero_approx(test_motion_result.get_collision_normal().y):
			var wall_collision_normal: Vector3 = test_motion_result.get_collision_normal()
			transform3d.origin += wall_collision_normal * WALL_MARGIN
			motion = (main_velocity * delta).slide(wall_collision_normal)
			test_motion_params.from = transform3d
			test_motion_params.motion = motion
			
			is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
			
			if not is_player_collided:
				transform3d.origin += motion
				motion = -step_height_main
				test_motion_params.from = transform3d
				test_motion_params.motion = motion
				
				is_player_collided = PhysicsServer3D.body_test_motion(self.get_rid(), test_motion_params, test_motion_result)
				
				if is_player_collided and test_motion_result.get_travel().y < -STEP_DOWN_MARGIN:
					if test_motion_result.get_collision_normal().angle_to(Vector3.UP) <= deg_to_rad(STEP_MAX_SLOPE_DEGREE):
						is_step = true
						step_result.diff_position.y = test_motion_result.get_travel().y
						step_result.normal = test_motion_result.get_collision_normal()

	return is_step
	
	
func _on_sliding_timer_timeout():
	is_free_looking = false


func _on_animation_player_animation_finished(anim_name):
	is_roll_animation_finished = anim_name == 'roll'


func override_gravity(_external_gravity_force : float, _external_gravity_vector: Vector3):
	CogitoGlobals.debug_log(true, "cogito_player.gd", "override gravity with " + str(_external_gravity_force) + ", " + str(_external_gravity_vector))
	gravity = _external_gravity_force
	gravity_vector = _external_gravity_vector
	
#	Forcing a move and slide with new gravity
	gravity_vec = gravity_vector * gravity
	velocity += gravity_vec
	move_and_slide()


func _on_player_state_loaded():
	#TODO - reset look on load if needed
	#self.global_transform.basis = Basis()
	#neck.global_transform.basis = Basis()
	pass


func _physics_process(delta):
	var next_sequence := last_consumed_sequence + 1
	var command: CogitoPlayerCommand
	if _input_suspended:
		command = neutral_command(next_sequence)
		command.has_control = false
	else:
		command = input_source.sample(self, next_sequence)
	if network_input_blocked and command:
		command = neutral_command(command.sequence)
		command.has_control = false
	if not command and network_movement_only:
		current_command = neutral_command(last_consumed_sequence)
		current_command.has_control = false
	if command and command.sequence > last_consumed_sequence:
		current_command = command
		last_consumed_sequence = command.sequence
		body.rotation.y = command.yaw
		head.rotation.x = clampf(command.pitch, -PI / 2.0, PI / 2.0)
		neck.rotation.y = command.neck_yaw
		for index in command.edges.size():
			_handle_command_edge(command.edges[index], index)
			if current_command != command:
				break # Opening a menu transferred input while consuming this frame.
	_free_look(delta)


func _handle_command_edge(edge: int, index: int) -> void:
	var action := edge & ~CogitoPlayerCommand.RELEASE
	var pressed := (edge & CogitoPlayerCommand.RELEASE) == 0
	if action <= ACTION.BACK and pressed and actor_elements and actor_elements.is_frozen():
		actor_elements.struggle()
	if action == ACTION.CROUCH and pressed and current_command.toggle_crouch and not is_movement_locked_by_elements():
		if current_moving_state not in [MovingState.Swimming, MovingState.LedgeClimbing]:
			try_crouch = not try_crouch
	if network_movement_only:
		if is_local_presentation and action in [ACTION.INTERACT, ACTION.INTERACT2]:
			var intent := InputEventAction.new()
			intent.action = CogitoPlayerCommand.ACTIONS[action]
			intent.pressed = pressed
			player_interaction_component.on_action_input(intent)
		if action == ACTION.JUMP and pressed:
			current_command.held |= 1 << ACTION.JUMP
		return
	var event := InputEventAction.new()
	event.action = CogitoPlayerCommand.ACTIONS[action]
	event.pressed = pressed
	if can_act() or not pressed:
		player_interaction_component.on_action_input(event)
	if not is_local_presentation:
		return
	if pressed and action == ACTION.MENU:
		_handle_menu()
	elif pressed and action == ACTION.INVENTORY and not is_dead:
		player_hud.set_inventory_visibility(true)
	var view_event := event as InputEvent
	if input_source is CogitoLocalInputSource:
		view_event = input_source.view_event(index)
	if view_event:
		handle_quickslot_input(view_event)
	if not pressed and player_hud is CogitoPlayerHudManager:
		var hud := player_hud as CogitoPlayerHudManager
		if hud.hold_ui:
			hud.hold_ui.release_action(event.action)


#region State Chart
enum MovingState {
	Undefined,
	Grounded,
	Idle,
	Walking,
	Sprinting,
	Sliding,
	Sneaking,
	Sitting,
	LadderClimbing,
	Rolling,
	LedgeClimbing,
	Airborne,
	AirControl,
	Jumping,
	FreeFall,
	Swimming
}

enum BodyPostureState {
	Undefined,
	Crouching,
	Standing,
	Sitting
}

var current_moving_state : MovingState
var current_body_posture_state : BodyPostureState

var jump_target_speed : float = 0.0
var was_sprinting : bool = false
var is_sprinting_in_airborne : bool = false
var was_sliding : bool = false
var was_standing : bool = false
var was_jumping : bool = false
var jumped_from_slide : bool = false
var jumped_from_crouch : bool = false
var was_in_air : bool = false
var try_crouch : bool
var wiggle_index : float = 0.0
var wiggle_current_intensity : float = 0.0
var bunny_hop_speed : float = SPRINTING_SPEED
var ledge_position : Vector3
var ledge_collider : CollisionObject3D
var is_in_ledge_climbing_middle_stage : bool = false
var is_in_ledge_climbing_final_stage : bool = false
var was_in_crouching_state_before_swim : bool = false
var was_in_swimming_state : bool = false


func _initialize_state_chart():
	state_chart.set_expression_property("on_ladder", on_ladder)
	state_chart.set_expression_property("is_sitting", is_sitting)
	state_chart.set_expression_property("is_crouch_shapecast_colliding", false)

	for node_path in no_pause_menu_states:
		var state = get_node(node_path)
		state.state_entered.connect(func(): is_in_unpausable_state = true)
		state.state_exited.connect(func(): is_in_unpausable_state = false)
	
	for node_path in no_interaction_states:
		var state = get_node(node_path)
		state.state_entered.connect(func(): is_in_interaction_state = false)
		state.state_exited.connect(func(): is_in_interaction_state = true)


func is_in_crouching_state():
	return current_body_posture_state == BodyPostureState.Crouching


func is_in_sprinting_state():
	return current_moving_state == MovingState.Sprinting


func _is_ledge_climbable() -> bool:
	if not input_direction:
		return false
	if is_movement_locked_by_elements():
		return false
	
	direction = (body.global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()

	if direction.dot(-body.global_basis.z) < 0.5:
		return false
	
	if current_moving_state != MovingState.Swimming and not CAN_CLIMB_LEDGE:
		return false
	
	ledge_climbing_shapecast.position = ledge_climbing_shapecast_initial_position
	
	# Check ladder first because its priority is higher
	ledge_climbing_shapecast.global_position -= Vector3(0, ledge_climbing_shapecast_height, 0)
	ledge_climbing_shapecast.target_position = ledge_climbing_shapecast.global_basis.inverse() * (-body.global_basis.z * radius)
	
	ledge_climbing_shapecast.collide_with_areas = true
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	if ledge_climbing_shapecast.is_colliding():
		if ledge_climbing_shapecast.get_collider(0) is Ladder:
			return false
	
	ledge_climbing_shapecast.collide_with_areas = false
	
	ledge_climbing_shapecast.position = ledge_climbing_shapecast_initial_position
	
	ledge_climbing_shapecast.target_position = Vector3.ZERO
	
	if current_moving_state == MovingState.Swimming:
		ledge_climbing_shapecast.global_position -= Vector3(0, standing_height - crouching_height, 0)
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	if ledge_climbing_shapecast.is_colliding():
		return false
	
	ledge_climbing_shapecast.target_position = Vector3(0, ARM_LENGTH + MIN_FREE_SPACE_ABOVE_HEAD, 0)
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	var collision_safe_fraction : float = 1.0
	
	if ledge_climbing_shapecast.is_colliding():
		collision_safe_fraction = ledge_climbing_shapecast.get_closest_collision_safe_fraction()
	
	ledge_climbing_shapecast.global_position += Vector3(0, ARM_LENGTH + MIN_FREE_SPACE_ABOVE_HEAD, 0) * collision_safe_fraction
	ledge_climbing_shapecast.target_position = ledge_climbing_shapecast.global_basis.inverse() * (-body.global_basis.z * radius)
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	if ledge_climbing_shapecast.is_colliding():
		ledge_climbing_shapecast.position = ledge_climbing_shapecast_initial_position
		
		if current_moving_state == MovingState.Swimming:
			ledge_climbing_shapecast.global_position -= Vector3(0, standing_height - crouching_height, 0)
		
		ledge_climbing_shapecast.force_shapecast_update()
		
		if ledge_climbing_shapecast.is_colliding():
			return false
	
	ledge_climbing_shapecast.global_position += -body.global_basis.z * radius
	ledge_climbing_shapecast.target_position = Vector3(0, -(ARM_LENGTH + MIN_FREE_SPACE_ABOVE_HEAD) - (standing_height - MIN_CLIMB_HEIGHT), 0)
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	if not ledge_climbing_shapecast.is_colliding():
		return false
	
	var collider = ledge_climbing_shapecast.get_collider(0)
	ledge_collider = null
	if collider is not CSGPrimitive3D: # Warning: Don't use CSGs as moving platforms. It seems there is a bug in getting CSGs as collider
		ledge_collider = collider
	
	var collision_normal : Vector3 = ledge_climbing_shapecast.get_collision_normal(0)
	
	if not collision_normal.is_equal_approx(Vector3.UP):
		return false
	
	var collision_point = ledge_climbing_shapecast.get_collision_point(0)
	
	ledge_climbing_shapecast.global_position.y = collision_point.y + (crouching_height + MIN_FREE_SPACE_ABOVE_HEAD) / 2
	ledge_climbing_shapecast.target_position = Vector3.ZERO
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	if ledge_climbing_shapecast.is_colliding():
		return false
	
	ledge_climbing_shapecast.global_position.y = collision_point.y + (crouching_height + MIN_FREE_SPACE_ABOVE_HEAD) / 2
	ledge_climbing_shapecast.target_position = ledge_climbing_shapecast.global_basis.inverse() * (-body.global_basis.z * radius)
	
	ledge_climbing_shapecast.force_shapecast_update()
	
	if ledge_climbing_shapecast.is_colliding():
		return false
	
	ledge_position = ledge_climbing_shapecast.global_position
	ledge_position.y = collision_point.y
	ledge_position += -body.global_basis.z * radius / 2
	
	return true


func _can_jump() -> bool:
	if is_sitting:
		return false
	if actor_elements and !actor_elements.can_jump():
		return false
		
	var doesnt_need_stamina = not stamina_attribute or stamina_attribute.value_current >= stamina_attribute.jump_exhaustion
	var crouch_jump = current_body_posture_state != BodyPostureState.Crouching or CAN_CROUCH_JUMP

	if not doesnt_need_stamina:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd","Not enough stamina to jump.")
		
	if doesnt_need_stamina and crouch_jump:
		return true
		
	return false


func _handle_jump_on_platform():
	if platform_on_leave != PLATFORM_ON_LEAVE_DO_NOTHING:
		var platform_velocity = get_platform_velocity()
		# TODO: Make PLATFORM_ON_LEAVE_ADD_VELOCITY work... somehow. 
		# Velocity X and Z gets overridden later, so you immediately lose the velocity
		if PLATFORM_ON_LEAVE_ADD_UPWARD_VELOCITY:
			platform_velocity.x = 0
			platform_velocity.z = 0
		main_velocity += platform_velocity


func _jump(_jump_target_speed) -> void:
	jump_target_speed = _jump_target_speed
	
	if current_command.is_held(ACTION.SPRINT):
		was_sprinting = true
	else:
		was_sprinting = false
		
	jump_timer.start() # prevent spam
	is_jumping_started = true
	is_in_air = false
	jumped_from_crouch = current_body_posture_state == BodyPostureState.Crouching
	
	var jump_vel = CROUCH_JUMP_VELOCITY if jumped_from_crouch else JUMP_VELOCITY
	
	# If Stamina Component is used, this checks if there's enough stamina to jump and denies it if not.
	if stamina_attribute:
		decrease_attribute("stamina",stamina_attribute.jump_exhaustion)
	
	animationPlayer.play("jump")
	if is_local_presentation:
		CogitoAudio.play_sound(jump_sound)
	
	if current_moving_state != MovingState.LadderClimbing:
		main_velocity.y = jump_vel
	else:
		main_velocity.y = jump_vel * LADDER_JUMP_SCALE
	
	was_jumping = true
	jumped_from_slide = false
	
	_handle_jump_on_platform()
	
	state_chart.send_event("jump")


func _sliding_jump(_jump_target_speed) -> void:
	jump_target_speed = _jump_target_speed
	
	jump_timer.start() # prevent spam
	is_jumping_started = true
	is_in_air = false
	jumped_from_crouch = current_body_posture_state == BodyPostureState.Crouching
	
	# If Stamina Component is used, this checks if there's enough stamina to jump and denies it if not.
	if stamina_attribute:
		decrease_attribute("stamina",stamina_attribute.jump_exhaustion)
	
	animationPlayer.play("jump")
	if is_local_presentation:
		CogitoAudio.play_sound(jump_sound)

	main_velocity.y = JUMP_VELOCITY * SLIDE_JUMP_MOD
	
	was_jumping = true
	jumped_from_slide = true
	
	sliding_timer.stop()
	
	_handle_jump_on_platform()
	
	try_crouch = false
	state_chart.send_event("stand_up")
	state_chart.send_event("jump")


func _input_handling_and_movement(delta):
	input_direction = current_command.move
	current_speed = clamp(current_speed, MIN_SPEED, MAX_SPEED)
	# Element states (chilled, frozen, stunned) slow the player down.
	var target_speed : float = current_speed * get_element_speed_multiplier()
	
	if direction and current_command.has_control:
		main_velocity.x = lerp(main_velocity.x, direction.x * target_speed, delta * current_lerp_speed)
		main_velocity.z = lerp(main_velocity.z, direction.z * target_speed, delta * current_lerp_speed)
	else:
		main_velocity.x = lerp(main_velocity.x, 0.0, delta * current_lerp_speed)
		main_velocity.z = lerp(main_velocity.z, 0.0, delta * current_lerp_speed)
	
	# Store current velocity for the next frame
	last_velocity = main_velocity
	
	# Velocity for current frame
	var main_velocity_before_stair_stepping : Vector3 = main_velocity + gravity_vec
	
	_stair_handling(delta)
	
	# Velocity for next frame. Stair steppting can modify main_velocity and gravity_vec.
	main_velocity += gravity_vec
	
	velocity = main_velocity_before_stair_stepping
	
	move_and_slide()


func _show_underwater_effect(show_effect: bool) -> void:
	if under_water_effect:
		under_water_effect.visible = show_effect


func _handle_swim_under_water_sounds():
	if is_head_in_water():
		if not swim_under_water_audio_player:
			swim_audio_init()
		
		if !swim_under_water_audio_player.playing:
			var audio_length : float = swim_under_water_audio_player.stream.get_length()
			swim_under_water_audio_player.play(randf_range(0, audio_length))
	else:
		if swim_under_water_audio_player:
			swim_under_water_audio_player.stop()


# To reduce artifacts when the camera moves in and out of the water
func _handle_eyes_position_in_water(delta):
	if is_head_in_water():
		eyes.position.y = lerp(eyes.position.y, -0.01, delta * LERP_SPEED * 1.5)
	else:
		eyes.position.y = lerp(eyes.position.y, 0.01, delta * LERP_SPEED * 1.5)


#region Grounded State
var wiggle_vector : Vector2 = Vector2.ZERO
var can_play_footstep : bool = true


func _on_grounded_on_pause_taken() -> void:
	if not is_dead:
		if current_moving_state == MovingState.Sliding:
			was_sliding = true
	else:
		was_sliding = false


func _on_grounded_state_entered() -> void:
	current_lerp_speed = LERP_SPEED
	# Only trigger landing sound if the player was airborne and the velocity exceeds the threshold
	if was_in_air and last_velocity.y < landing_threshold:
		# Calculate the volume and pitch based on the landing velocity
		var velocity_ratio = clamp((last_velocity.y - min_landing_velocity) / (max_landing_velocity - min_landing_velocity), 0.0, 1.0)
		# Set the volume and pitch of the landing sound
		landing_volume = lerp(min_volume_db, max_volume_db, velocity_ratio)
		landing_pitch = lerp(max_pitch, min_pitch, velocity_ratio)
		# Play the landing sound
		footstep_surface_detector._play_interaction("landing", current_lerp_speed)
	was_in_air = false  # Reset airborne state


func _on_grounded_state_physics_processing(delta: float) -> void:
	if is_sitting:
		return
		
	_input_handling_and_movement(delta)
	
	if not is_head_in_water():
		_show_underwater_effect(false)
	else:
		_show_underwater_effect(true)
	
	_handle_swim_under_water_sounds()
	
	if is_head_in_water():
		state_chart.send_event("swim")
		return
		
	if not is_on_floor():
		if current_moving_state == MovingState.Sliding:
			was_sliding = true
		state_chart.send_event("airborne")
		return
		
	if current_moving_state == MovingState.Rolling:
		return
		
	if not is_jumping_started:
		main_velocity.y = 0
		gravity_vec = Vector3.ZERO
	
	## Taking fall damage
	if fall_damage > 0 and last_velocity.y <= fall_damage_threshold:
		var damage_ratio : float = last_velocity.y / fall_damage_threshold
		decrease_attribute("health", int(fall_damage * damage_ratio))
		
	if last_velocity.y <= LANDING_MIN_ROLL_VELOCITY:
		if !disable_roll_anim:
			was_standing = current_body_posture_state == BodyPostureState.Standing
			is_sprinting_in_airborne = false
			state_chart.send_event("roll")
			return
	elif last_velocity.y <= LANDING_MIN_VELOCITY:
		animationPlayer.play("landing")
		
	if was_sliding and is_on_floor():
		state_chart.send_event("slide")
		return
	
	
	if current_moving_state != MovingState.Sliding and input_direction != Vector2.ZERO:
		wiggle_vector.y = sin(wiggle_index)
		wiggle_vector.x = sin(wiggle_index / 2) + 0.5
		eyes.position.y = lerp(
			eyes.position.y,
			wiggle_vector.y * (wiggle_current_intensity / 2.0), 
			delta * LERP_SPEED
		)
		eyes.position.x = lerp(
			eyes.position.x,
			wiggle_vector.x * wiggle_current_intensity, 
			delta * LERP_SPEED
		)
	else:
		eyes.position.y = lerp(eyes.position.y, 0.0, delta * LERP_SPEED)
		eyes.position.x = lerp(eyes.position.x, 0.0, delta * LERP_SPEED)
	
	direction = (body.global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()
	
	_footstep_sounds_system()
	
	if was_jumping and not jumped_from_slide and current_command.is_held(ACTION.SPRINT) and is_sprinting_in_airborne:
		if current_body_posture_state == BodyPostureState.Crouching and not jumped_from_crouch:
			was_sprinting = false
			state_chart.send_event("slide")
			
	is_sprinting_in_airborne = false


func _footstep_sounds_system():
	# FOOTSTEP SOUNDS SYSTEM = CHECK IF ON GROUND AND MOVING
	if main_velocity.length() >= 0.2:
		if current_moving_state == MovingState.Sliding:
			if !slide_audio_player.playing:
				slide_audio_player.play()
		else:
			if slide_audio_player:
				slide_audio_player.stop()
			
			if can_play_footstep && wiggle_vector.y > 0.9:
				#dynamic volume for footsteps
				if current_moving_state == MovingState.Walking:
					footstep_surface_detector.volume_db = walk_volume_db
				elif current_moving_state == MovingState.Sneaking:
					footstep_surface_detector.volume_db = crouch_volume_db
				elif current_moving_state == MovingState.Sprinting:
					footstep_surface_detector.volume_db = sprint_volume_db
				footstep_surface_detector._play_interaction("footstep", main_velocity.length())
					
				can_play_footstep = false
				
			if !can_play_footstep && wiggle_vector.y < 0.9:
				can_play_footstep = true
#endregion


#region Idle State
func _on_idle_state_entered() -> void:
	current_moving_state = MovingState.Idle


func _on_idle_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_idle_state_physics_processing(delta: float) -> void:
	if not main_velocity.is_equal_approx(Vector3.ZERO):
		if current_body_posture_state == BodyPostureState.Crouching:
			state_chart.send_event("sneak")
			return
		else:
			state_chart.send_event("walk")
			return
	
	if current_command.is_held(ACTION.JUMP) and jump_timer.is_stopped():
		if not _can_jump():
			return
		
		_jump(WALKING_SPEED)
#endregion


#region Walking State
func _on_walking_state_entered() -> void:
	current_moving_state = MovingState.Walking


func _on_walking_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_walking_state_physics_processing(delta: float) -> void:
	
	if current_body_posture_state == BodyPostureState.Crouching:
		state_chart.send_event("sneak")
		return

	if not on_ladder and current_command.is_held(ACTION.SPRINT) and stamina_attribute and stamina_attribute.value_current > 5:
		state_chart.send_event("sprint")
		return
		
	current_speed = lerp(current_speed, WALKING_SPEED, delta * LERP_SPEED)
	wiggle_current_intensity = WIGGLE_ON_WALKING_INTENSITY * HEADBOBBLE
	wiggle_index += WIGGLE_ON_WALKING_SPEED * delta
	
	if main_velocity.is_equal_approx(Vector3.ZERO):
		state_chart.send_event("idle")
	
	if current_command.is_held(ACTION.JUMP) and jump_timer.is_stopped():
		if not _can_jump():
			return

		#current_speed = WALKING_SPEED
		_jump(WALKING_SPEED)
#endregion


#region Sprinting State
func _on_sprinting_state_entered() -> void:
	current_moving_state = MovingState.Sprinting


func _on_sprinting_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_sprinting_state_physics_processing(delta: float) -> void:
	
	if current_command.is_held(ACTION.SPRINT):
		if !stamina_attribute or (stamina_attribute and stamina_attribute.value_current > 0):
			if stamina_attribute and stamina_attribute.value_current <= 0.2:
				bunny_hop_speed = SPRINTING_SPEED
				state_chart.send_event("walk")
				return
			
			if !current_command.is_held(ACTION.JUMP):
				if CAN_BUNNYHOP:
					bunny_hop_speed = SPRINTING_SPEED
					current_speed = lerp(current_speed, bunny_hop_speed, delta * LERP_SPEED)
				else:
					current_speed = lerp(current_speed, SPRINTING_SPEED, delta * LERP_SPEED)
				
			wiggle_current_intensity = WIGGLE_ON_SPRINTING_INTENSITY * HEADBOBBLE
			wiggle_index += WIGGLE_ON_SPRINTING_SPEED * delta
		
		if current_command.is_held(ACTION.JUMP) and jump_timer.is_stopped():
			if current_speed < bunny_hop_speed - 0.2:
				current_speed = lerp(current_speed, bunny_hop_speed, delta * LERP_SPEED)
			else:
				if CAN_BUNNYHOP:
					bunny_hop_speed += BUNNY_HOP_ACCELERATION
					bunny_hop_speed = clamp(bunny_hop_speed, SPRINTING_SPEED, MAX_SPEED)
					current_speed = bunny_hop_speed
				else:
					current_speed = SPRINTING_SPEED
			
			if not _can_jump():
				bunny_hop_speed = SPRINTING_SPEED
				return
			
			_jump(bunny_hop_speed)
	else:
		bunny_hop_speed = SPRINTING_SPEED
		state_chart.send_event("walk")
#endregion


#region Sliding State
var slide_vector : Vector2 = Vector2.ZERO


func _on_sliding_state_entered() -> void:
	current_moving_state = MovingState.Sliding
	
	if not was_sliding:
		sliding_timer.start()
		slide_vector = input_direction
		
	was_sliding = false


func _on_sliding_state_exited() -> void:
	current_moving_state = MovingState.Undefined
	
	if slide_audio_player:
		slide_audio_player.stop()


func _on_sliding_state_physics_processing(delta: float) -> void:
	
	if input_direction == Vector2.ZERO:
		sliding_timer.stop()
		state_chart.send_event("idle")
		return
		
	if !current_command.is_held(ACTION.SPRINT):
		sliding_timer.stop()
		if current_body_posture_state == BodyPostureState.Standing:
			state_chart.send_event("walk")
		else:
			state_chart.send_event("sneak")
		return
		
	if sliding_timer.is_stopped():
		if current_body_posture_state == BodyPostureState.Standing:
			state_chart.send_event("walk")
		else:
			state_chart.send_event("sneak")
	else:
		direction = (body.global_transform.basis * Vector3(slide_vector.x, 0.0, slide_vector.y)).normalized()
		current_speed = (sliding_timer.time_left / sliding_timer.wait_time + 0.5) * SLIDING_SPEED
		
		if current_command.is_held(ACTION.JUMP) and jump_timer.is_stopped():
			if not _can_jump():
				return
				
			_sliding_jump(current_speed)
#endregion


#region Sneaking State
func _on_sneaking_state_entered() -> void:
	current_moving_state = MovingState.Sneaking


func _on_sneaking_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_sneaking_state_physics_processing(delta: float) -> void:
	
	wiggle_index += WIGGLE_ON_CROUCHING_SPEED * delta
	eyes.position.y = lerp(eyes.position.y, 0.0, delta * LERP_SPEED)
	eyes.position.x = lerp(eyes.position.x, 0.0, delta * LERP_SPEED)
	
	current_speed = lerp(current_speed, CROUCHING_SPEED, delta * LERP_SPEED)

	if main_velocity.is_equal_approx(Vector3.ZERO):
		state_chart.send_event("idle")
	
	if current_command.is_held(ACTION.JUMP) and jump_timer.is_stopped():
		if not _can_jump():
			return

		jumped_from_crouch = true
		_jump(CROUCHING_SPEED)
#endregion


#region Sitting State
#Sittable Vars
var original_position: Transform3D
var displacement_position: Vector3
var is_sitting: bool  = false
var sittable_look_marker: Vector3
var sittable_look_angle: float
var moving_seat: bool = false
var original_neck_basis: Basis = Basis()
var is_ejected: bool = false
var currently_tweening: bool = false


func _on_sitting_state_entered() -> void:
	state_chart.set_expression_property("is_sitting", is_sitting)
	current_moving_state = MovingState.Sitting


func _on_sitting_state_exited() -> void:
	state_chart.set_expression_property("is_sitting", is_sitting)
	current_moving_state = MovingState.Undefined


func _on_sitting_state_physics_processing(delta: float) -> void:
	if is_sitting:
		_process_on_sittable(delta)


func _process_on_sittable(delta):
	var sittable = current_seat
	#avoids instantly moving to seat before tween is finished
	if not currently_tweening:
		self.global_transform = sittable.sit_position_node.global_transform
	#Check if the player should be ejected, is_ejected is flag to prevent multiple calls
	if sittable.eject_on_fall == true and not is_ejected:
		var chair_up_vector = sittable.global_transform.basis.y
		var global_up_vector = Vector3(0, 1, 0)
		# Calculate angle between chair's up vector and the global up vector
		var angle_to_up = rad_to_deg(chair_up_vector.angle_to(global_up_vector))
		# If the angle is greater than a threshold of 45 degrees, the chair has fallen over
		if angle_to_up > sittable.eject_angle:
			is_ejected = true  # Set the flag to avoid repeated ejections
			current_seat.interact(player_interaction_component) #Interact with sittable to reset state and eject


func toggle_sitting():
	if is_sitting:
		_stand_up()
	else:
		_sit_down()


func _on_sit_requested(sittable: Node):
	if not is_sitting:
		_sit_down()


func _on_stand_requested():
	if is_sitting:
		_stand_up()	


func _on_seat_move_requested(sittable: Node):
	moving_seat = true
	_sit_down()


func handle_sitting_look(event: InputEventMouseMotion) -> void:
	if is_local_presentation and input_source is CogitoLocalInputSource:
		input_source.apply_seated_look(self, event.relative)


func _sit_down():
	is_ejected = false 
	
	var sittable = current_seat
	if sittable:
		is_sitting = true
		collision_mask = CogitoPhysics.CollisionMask.NONE
		state_chart.send_event("sit")
		if sittable.look_marker_node:
			sittable_look_marker = sittable.look_marker_node.global_transform.origin
		sittable_look_angle = sittable.horizontal_look_angle
		if moving_seat == false:
			original_position = self.global_transform
			original_neck_basis = neck.global_transform.basis
			displacement_position = sittable.global_transform.origin - self.global_transform.origin
		
		#TODO: Implement crouch handling
		
		# Check if the sittable is physics-based
		if sittable.physics_sittable:
			currently_tweening = true
			collision_mask = initial_collision_mask
			#just using same tween for now with less tween time on chair_desk, TODO create a more dynamic 'tween' in physics process
			var tween = create_tween()
			tween.tween_property(self, "global_transform", sittable.sit_position_node.global_transform, sittable.tween_duration)
			tween.tween_callback(Callable(self, "_sit_down_finished"))

		else:
			# Static tween for non-physics sittable
			currently_tweening = true
			var tween = create_tween()
			tween.tween_property(self, "global_transform", sittable.sit_position_node.global_transform, sittable.tween_duration)
			tween.tween_callback(Callable(self, "_sit_down_finished"))


func _sit_down_finished():
	is_sitting = true
	crouch_shapecast.enabled = false
	collision_mask = initial_collision_mask
	var sittable = current_seat
	currently_tweening = false
	if sittable_look_marker:
		var tween = create_tween()
		var target_transform = neck.global_transform.looking_at(sittable_look_marker, Vector3.UP)
		tween.tween_property(neck, "global_transform:basis", target_transform.basis, sittable.rotation_tween_duration)


func _stand_up():
	var sittable = current_seat
	if sittable:
		collision_mask = CogitoPhysics.CollisionMask.NONE
		state_chart.send_event("grounded")
		#TODO: Implement crouch handling
		# Handle player exit placement on stand-up based on the placement_leave_behaviour of the sittable
		match sittable.placement_on_leave:
			sittable.PlacementOnLeave.ORIGINAL:
				_move_to_original_position(sittable)
			sittable.PlacementOnLeave.AUTO:
				_move_to_nearby_location(sittable)
			sittable.PlacementOnLeave.TRANSFORM:
				_move_to_leave_node(sittable)
			sittable.PlacementOnLeave.DISPLACEMENT:
				_move_to_displacement_position(sittable) 
					
		moving_seat = false

#Functions to handle Exit types


#Return player to Original position
func _move_to_original_position(sittable):
	currently_tweening = true
	var tween = create_tween()
	tween.tween_property(self, "global_transform", original_position, sittable.tween_duration)
	tween.tween_property(neck, "global_transform:basis", original_neck_basis, sittable.rotation_tween_duration)
	tween.tween_callback(Callable(self, "_stand_up_finished"))


#Return player to Leave node position
func _move_to_leave_node(sittable):
	currently_tweening = true
	if sittable.leave_node_path:
		var leave_node = sittable.get_node(sittable.leave_node_path)
		if leave_node:
			var tween = create_tween()
			tween.tween_property(self, "global_transform", leave_node.global_transform, sittable.tween_duration)
			tween.tween_property(neck, "global_transform:basis", original_neck_basis, sittable.rotation_tween_duration)
			tween.tween_callback(Callable(self, "_stand_up_finished"))
		else:
			CogitoGlobals.debug_log(true, "CogitoProjectile", "No leave node found. Returning to Original position")
			_move_to_original_position(sittable)


#Find location using navmesh to place player
func _move_to_nearby_location(sittable):
	CogitoGlobals.debug_log(true, "CogitoPlayer", "Attempting to find available locations to move player to")
	var seat_position = sittable.global_transform.origin
	var exit_distance: float = 1.0
	var max_distance: float = 10.0 # Max distance from Sittable to try, multiplies the random direction
	var step_increase: float = 0.5
	var max_attempts: int = 10
	var navmesh_offset_y: float = 0.25
	var attempts: int = 0


	var player_position = self.global_transform.origin

	while attempts < max_attempts:
		# Generate random direction
		var random_direction = Vector3(
			randf_range(-0.1, 0.1),
			randf_range(-0.1, 0.1),  # Degree of Y random actually makes this work better at finding candidates
			randf_range(-0.1, 0.1)
		).normalized()
		
		var candidate_pos = seat_position + (random_direction * exit_distance)
		candidate_pos.y = navmesh_offset_y  # to check navmesh at navmesh height

		navigation_agent.target_position = candidate_pos

		# Check if position is reachable
		if navigation_agent.is_navigation_finished():
			currently_tweening = true
			var tween = create_tween()
			navigation_agent.target_position.y += 1 # To avoid player going through floor
			tween.tween_property(self, "global_transform:origin", navigation_agent.target_position, sittable.tween_duration)
			tween.tween_property(neck, "global_transform:basis", original_neck_basis, sittable.rotation_tween_duration)
			tween.tween_callback(Callable(self, "_stand_up_finished"))
			return
		else:
			exit_distance += step_increase
			attempts += 1

		if exit_distance > max_distance:
			exit_distance = 1

	# If no valid location found, try leave node
	CogitoGlobals.debug_log(true, "CogitoPlayer", "No available location found after " + str(attempts) + " tries. Testing for leave node.")
	_move_to_leave_node(sittable)


func _move_to_displacement_position(sittable):
	var tween = create_tween()
	var new_position = sittable.global_transform.origin - displacement_position
	var new_transform = self.global_transform
	new_transform.origin = new_position
	tween.tween_property(self, "global_transform", new_transform, sittable.tween_duration)
	tween.tween_property(neck, "global_transform:basis", original_neck_basis, sittable.rotation_tween_duration)
	tween.tween_callback(Callable(self, "_stand_up_finished"))


func _stand_up_finished():
	is_sitting = false
	crouch_shapecast.enabled = true
	collision_mask = initial_collision_mask
	state_chart.send_event("grounded")
	try_crouch = false
	state_chart.send_event("stand_up")
	self.global_transform.basis = Basis()
	neck.global_transform.basis = original_neck_basis  
	currently_tweening = false
#endregion


#region Rolling state
func _on_rolling_state_entered() -> void:
	current_moving_state = MovingState.Rolling
	animationPlayer.play("roll")
	try_crouch = true
	state_chart.send_event("crouch")


func _on_rolling_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_rolling_state_physics_processing(delta: float) -> void:
	if is_roll_animation_finished:
		is_roll_animation_finished = false
		if was_standing:
			try_crouch = false
			state_chart.send_event("stand_up")
		else:
			state_chart.send_event("grounded")
#endregion


#region Airborne State
func _on_airborne_state_entered() -> void:
	was_in_air = true  # Set airborne state
	current_moving_state = MovingState.Airborne
	current_lerp_speed = AIR_LERP_SPEED


func _on_airborne_state_physics_processing(delta: float) -> void:
	_input_handling_and_movement(delta)
	
	if is_head_in_water():
		state_chart.send_event("swim")
		return
	
	if is_on_ceiling():
		main_velocity.y = 0
	
	gravity_vec = gravity_vector * gravity * delta

	if was_sprinting and current_command.is_held(ACTION.SPRINT):
		is_sprinting_in_airborne = true
	else:
		bunny_hop_speed = SPRINTING_SPEED
		was_sprinting = false
		is_sprinting_in_airborne = false

	if slide_audio_player:
		slide_audio_player.stop()

	if is_on_floor():
		state_chart.send_event("grounded")
#endregion


#region AirControl State
func _on_air_control_state_entered() -> void:
	current_moving_state = MovingState.AirControl


func _on_air_control_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_air_control_state_physics_processing(delta: float) -> void:
	if input_direction != Vector2.ZERO:
		direction = (body.global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()
	
	if main_velocity.y <= FREE_FALL_MIN_VELOCITY:
		state_chart.send_event("fall")
#endregion


#region Jumping State
func _on_jumping_state_entered() -> void:
	current_moving_state = MovingState.Jumping


func _on_jumping_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_jumping_state_physics_processing(delta: float) -> void:
	if input_direction != Vector2.ZERO:
		direction = (body.global_transform.basis * Vector3(input_direction.x, 0, input_direction.y)).normalized()
	
	current_speed = lerp(current_speed, jump_target_speed, delta * LERP_SPEED)
	
	if is_on_wall():
		var normal = get_wall_normal()
		var angle = rad_to_deg(direction.angle_to(normal))
		if angle > BUNNY_HOP_WALL_SLIDE_ANGLE:
			bunny_hop_speed = SPRINTING_SPEED
	
	if current_body_posture_state != BodyPostureState.Crouching:
		if _is_ledge_climbable():
			bunny_hop_speed = SPRINTING_SPEED
			state_chart.send_event("ledge_climb")
			return
	
	if main_velocity.y <= FREE_FALL_MIN_VELOCITY:
		state_chart.send_event("fall")
#endregion


#region FreeFall State
func _on_free_fall_state_entered() -> void:
	current_moving_state = MovingState.FreeFall


func _on_free_fall_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_free_fall_state_physics_processing(delta: float) -> void:
	if main_velocity.y <= FREE_FALL_MIN_DIE_VELOCITY:
		decrease_attribute("health", $HealthAttribute.value_max)
		state_chart.send_event("pause")
#endregion


#region LadderClimbing State
var ladder_direction : Vector3

func _on_ladder_climbing_state_entered() -> void:
	current_moving_state = MovingState.LadderClimbing
	
	last_velocity = Vector3.ZERO
	
	was_jumping = false


func _on_ladder_climbing_state_exited() -> void:
	on_ladder = false
	state_chart.set_expression_property("on_ladder", on_ladder)
	current_moving_state = MovingState.Undefined


func _on_ladder_climbing_state_physics_processing(delta: float) -> void:
	if not is_head_in_water():
		_show_underwater_effect(false)
	
		if was_in_swimming_state:
			was_in_swimming_state = false
			if (AUTO_STAND_AFTER_SWIM or not was_in_crouching_state_before_swim) and is_in_crouching_state():
				try_crouch = false
				state_chart.send_event("stand_up")
	else:
		_show_underwater_effect(true)
		
	_process_on_ladder(delta)


func _process_on_ladder(_delta):
	var input_dir = current_command.move
	
	_handle_swim_under_water_sounds()
	
	var ladder_speed = LADDER_SPEED
	
	if CAN_SPRINT_ON_LADDER and current_command.is_held(ACTION.SPRINT) and input_dir.length_squared() > 0.1:
		#is_sprinting = true
		if stamina_attribute.value_current > 0:
			ladder_speed = LADDER_SPRINT_SPEED
	#else:
		#is_sprinting = false
		
	var jump = current_command.is_held(ACTION.JUMP)

	var look_vector = get_aim_transform().basis
	var looking_down = look_vector.z.dot(Vector3.UP) > 0.5

	# Applying ladder input_dir to direction
	var y_dir = 1 if looking_down else -1
	direction = (body.global_transform.basis * Vector3(input_dir.x,input_dir.y * y_dir,0)).normalized()
	main_velocity = direction * ladder_speed * get_element_speed_multiplier()
	
	if jump:
		var jump_direction = (body.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

		if jump_direction and not jump_direction.dot(ladder_direction) < 0:
			if not _can_jump():
				return
			
			_jump(WALKING_SPEED)
			
			return
	
	velocity = main_velocity
	move_and_slide()
	
	#Step off ladder when on ground
	if is_on_floor() and not ladder_on_cooldown:
		on_ladder = false
		state_chart.send_event("grounded")


func ladder_buffer_finished():
	ladder_on_cooldown = false


func enter_ladder(ladder: CollisionShape3D, ladderDir: Vector3):
	# called by ladder_area.gd
	ladder_direction = ladderDir
	# try and capture player's intent based on where they're looking
	var look_vector = get_aim_transform().basis
	var looking_away = look_vector.z.dot(ladderDir) < 0.33
	var looking_down = look_vector.z.dot(Vector3.UP) > 0.5
	if looking_down or not looking_away:
		var ladder_timer = get_tree().create_timer(LADDER_COOLDOWN)
		ladder_timer.timeout.connect(ladder_buffer_finished)
		ladder_on_cooldown = true
		if not on_ladder:
			on_ladder = true
			state_chart.send_event("climb_ladder")
			state_chart.set_expression_property("on_ladder", on_ladder)


func exit_ladder():
	# Prevent falling of player when collision shape toggled between crouching and standing
	var is_still_on_ladder = false
	
	var ladder_check_shapecast : ShapeCast3D = ShapeCast3D.new()
	add_child(ladder_check_shapecast)
	ladder_check_shapecast.add_exception(self)
	ladder_check_shapecast.collision_mask = CogitoPhysics.CollisionMask.WATER
	ladder_check_shapecast.collide_with_areas = true
	ladder_check_shapecast.position = crouching_collision_shape.position
	ladder_check_shapecast.target_position = Vector3.ZERO
	ladder_check_shapecast.shape = crouching_collision_shape.shape
	ladder_check_shapecast.force_shapecast_update()
	if ladder_check_shapecast.is_colliding():
		for i in ladder_check_shapecast.get_collision_count():
			var collider = ladder_check_shapecast.get_collider(i)
			if collider is Ladder:
				is_still_on_ladder = true
				break
	
	ladder_check_shapecast.free()
	
	if is_still_on_ladder:
		on_ladder = true
		return
		
	on_ladder = false
	state_chart.set_expression_property("on_ladder", on_ladder)
	
	state_chart.send_event("airborne")
#endregion


#region Swimming State
var can_play_swim_movement : bool = true


func is_body_in_water() -> bool:
	var water_areas := CogitoLevel.nodes_in_group(self, &"water_area")
	if water_areas.all(func(area): return !area.overlaps_body(self)):
		return false
	else:
		return true


func is_head_in_water() -> bool:
	swimming_head_shapecast.force_shapecast_update()
	
	if not swimming_head_shapecast.is_colliding():
		return false
	
	return true


func _handle_water_physics(delta) -> void:
	
	input_direction = current_command.move
	
	var look_vector = get_aim_transform().basis
	var direction = look_vector * Vector3(input_direction.x, 0, input_direction.y).normalized()
	
	if current_command.is_held(ACTION.JUMP):
		direction.y = 1
	elif current_command.is_held(ACTION.CROUCH):
		if not is_on_floor():
			direction.y = -1
	
	if not is_head_in_water() and direction.dot(Vector3.UP) > 0:
		direction = direction.slide(Vector3.UP)
	
	direction = direction.normalized()
	
	current_speed = lerp(current_speed, SWIMMING_SPEED, delta * LERP_SPEED)
	
	var is_moving: bool = false
	
	if input_direction or current_command.is_held(ACTION.JUMP) or current_command.is_held(ACTION.CROUCH):
		is_moving = true
		main_velocity = lerp(main_velocity, direction * current_speed * get_element_speed_multiplier(), delta * LERP_SPEED)
	else:
		main_velocity = lerp(main_velocity, Vector3.ZERO, delta * LERP_SPEED)
		
		if not is_on_floor():
			main_velocity.y -= gravity * WATER_GRAVITY_COEFFICIENT * delta
	
	_handle_swim_under_water_sounds()
	
	if is_moving and main_velocity.length() >= 0.2:
		if can_play_swim_movement && wiggle_vector.y > 0.9:
			CogitoAudio.play_sound_3d_attached(swim_movement_sound, self)
			can_play_swim_movement = false
		
		if !can_play_swim_movement && wiggle_vector.y < 0.9:
			can_play_swim_movement = true
	
	velocity = main_velocity
	
	move_and_slide()


func _on_swimming_state_entered() -> void:
	current_moving_state = MovingState.Swimming
	
	last_velocity = Vector3.ZERO
	gravity_vec = Vector3.ZERO
	direction = Vector3.ZERO
	
	was_in_swimming_state = true
	was_in_crouching_state_before_swim = is_in_crouching_state()
	
	try_crouch = true
	state_chart.send_event("crouch")


func _on_swimming_state_exited() -> void:
	current_moving_state = MovingState.Undefined


func _on_swimming_state_physics_processing(delta: float) -> void:
	wiggle_index += WIGGLE_ON_SWIMMING_SPEED * delta
	wiggle_vector.y = sin(wiggle_index)
	wiggle_vector.x = sin(wiggle_index / 2) + 0.5
	
	if not is_head_in_water():
		_show_underwater_effect(false)
		if is_on_floor():
			state_chart.send_event("grounded")
			
			if (AUTO_STAND_AFTER_SWIM or not was_in_crouching_state_before_swim) and is_in_crouching_state():
				try_crouch = false
				state_chart.send_event("stand_up")
			
			return
	else:
		_show_underwater_effect(true)
	
	_handle_water_physics(delta)
	
	if current_command.is_held(ACTION.JUMP) and _is_ledge_climbable():
		state_chart.send_event("ledge_climb")
#endregion


#region LedgeClimbing State
func _on_ledge_climbing_state_entered() -> void:
	current_moving_state = MovingState.LedgeClimbing
	
	main_velocity = Vector3.ZERO
	last_velocity = Vector3.ZERO
	gravity_vec = Vector3.ZERO
	direction = Vector3.ZERO
	
	was_jumping = false


func _on_ledge_climbing_state_exited() -> void:
	current_moving_state = MovingState.Undefined
	is_in_ledge_climbing_final_stage = false
	is_in_ledge_climbing_middle_stage = false


func _on_ledge_climbing_state_physics_processing(delta: float) -> void:
	if not is_head_in_water():
		_show_underwater_effect(false)
	else:
		_show_underwater_effect(true)
	
	_handle_swim_under_water_sounds()
	
	if not current_command.is_held(ACTION.JUMP) and not is_in_ledge_climbing_middle_stage:
		state_chart.send_event("idle")
		try_crouch = false
		state_chart.send_event("stand_up")
		return
	
	var platfrom_linear_velocity : Vector3 = Vector3.ZERO
	
	if ledge_collider:
		platfrom_linear_velocity = PhysicsServer3D.body_get_state(ledge_collider.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		ledge_position += platfrom_linear_velocity * delta
	
	var move_direction = Vector3.UP
	velocity = move_direction * CLIMBING_SPEED + platfrom_linear_velocity
	
	if crouching_collision_shape.global_position.y + ((standing_height - (2 * crouching_height)) + crouching_height / 2) < ledge_position.y:
		move_and_slide()
		return
	
	if current_body_posture_state != BodyPostureState.Crouching:
		is_in_ledge_climbing_middle_stage = true
		try_crouch = true
		state_chart.send_event("crouch")
		return
	
	is_in_ledge_climbing_middle_stage = true
	
	if not is_in_ledge_climbing_final_stage and crouching_collision_shape.global_position.y - (crouching_height / 2 + MIN_FREE_SPACE_ABOVE_HEAD) < ledge_position.y:
		move_and_slide()
		return
	
	is_in_ledge_climbing_final_stage = true

	move_direction = crouching_collision_shape.global_position.direction_to(ledge_position + Vector3(0, crouching_height / 2, 0))

	velocity = move_direction * CLIMBING_SPEED + platfrom_linear_velocity
	
	move_and_slide()
	
	if (ledge_position + Vector3(0, crouching_height / 2, 0)).distance_to(crouching_collision_shape.global_position) < 0.1:
		state_chart.send_event("idle")
		if AUTO_STAND_AFTER_CLIMB:
			try_crouch = false
			state_chart.send_event("stand_up")
#endregion


#region Crouching State
func _on_crouching_state_entered() -> void:
	current_body_posture_state = BodyPostureState.Crouching
	standing_collision_shape.disabled = true
	crouching_collision_shape.disabled = false
	wiggle_current_intensity = WIGGLE_ON_CROUCHING_INTENSITY


func _on_crouching_state_exited() -> void:
	current_body_posture_state = BodyPostureState.Undefined


func _on_crouching_state_physics_processing(delta: float) -> void:
	head.position.y = lerp(head.position.y, CROUCHING_DEPTH, delta * LERP_SPEED)
	
	_handle_eyes_position_in_water(delta)
	
	swimming_head_shapecast.global_position = head.global_position
	
	# Kept up to date while swimming too: the swimming state sends "stand_up" itself.
	state_chart.set_expression_property("is_crouch_shapecast_colliding", crouch_shapecast.is_colliding())

	if current_moving_state != MovingState.Swimming and current_moving_state != MovingState.LedgeClimbing and !is_movement_locked_by_elements():
		if !current_command.toggle_crouch:
			try_crouch = current_command.is_held(ACTION.CROUCH)
		
		if not try_crouch and not crouch_shapecast.is_colliding():
			state_chart.send_event("stand_up")
#endregion


#region Standing State
func _on_standing_state_entered() -> void:
	current_body_posture_state = BodyPostureState.Standing
	sliding_timer.stop()
	crouch_shapecast.enabled = false


func _on_standing_state_exited() -> void:
	current_body_posture_state = BodyPostureState.Undefined
	crouch_shapecast.enabled = true


func _on_standing_state_physics_processing(delta: float) -> void:
	if not current_command.toggle_crouch and not is_movement_locked_by_elements() and current_moving_state != MovingState.Rolling:
		try_crouch = current_command.is_held(ACTION.CROUCH)
	if current_moving_state != MovingState.LedgeClimbing:
		if try_crouch or crouch_shapecast.is_colliding():
			state_chart.send_event("crouch")
			return
	
	head.position.y = lerp(head.position.y, 0.0, delta * LERP_SPEED)
	
	_handle_eyes_position_in_water(delta)
	
	swimming_head_shapecast.global_position = head.global_position
	
	if head.position.y > CROUCHING_DEPTH/4:
		if is_sitting:
			return
		standing_collision_shape.disabled = false
		crouching_collision_shape.disabled = true
#endregion


#region PushingObjects State
func _on_pushing_objects_state_physics_processing(delta: float) -> void:
	# Pushing RigidBody3Ds
	for col_idx in get_slide_collision_count():
		var col := get_slide_collision(col_idx)
		if col.get_collider() is RigidBody3D:
			col.get_collider().apply_central_impulse(-col.get_normal() * PLAYER_PUSH_FORCE)
#endregion

#endregion


class StepResult:
	var diff_position: Vector3 = Vector3.ZERO
	var normal: Vector3 = Vector3.ZERO
	var is_step_up: bool = false
