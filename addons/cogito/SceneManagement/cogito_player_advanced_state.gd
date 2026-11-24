class_name CogitoPlayerAdvancedState
extends CogitoPlayerState


@export var version : int = 1


@export var player_uid : int
@export var player_try_crouch : bool

#Using Vector2 for saving player attributes. X = current, Y = max.
@export var player_health: Vector2
@export var player_stamina : Vector2
@export var player_sanity : Vector2

#New way of saving player attributes

# Saving currencies

# Saving world dict

#Saving parameters from the player interaction component

#Saving quests:

# Sitting vars
@export var is_sitting: bool = false
@export var sittable_look_marker: Vector3 = Vector3()
@export var sittable_look_angle: float = 0.0
@export var moving_seat: bool = false
@export var displacement_position: Vector3 = Vector3()
@export var original_position: Transform3D = Transform3D()
@export var original_neck_basis: Basis = Basis()
@export var is_ejected: bool = false
@export var currently_tweening: bool = false
@export var current_sittable_path: NodePath
## Persistent id of the sittable the player sits on. Saves made before ids only have current_sittable_path.
@export var current_sittable_id: String

#Collision shapes
@export var standing_collision_shape_enabled : bool = true
@export var crouching_collision_shape_enabled : bool = false

@export var player_transform: Transform3D
@export var body_transform: Transform3D
@export var neck_transform: Transform3D
@export var head_transform: Transform3D
@export var eyes_transform: Transform3D
@export var camera_transform: Transform3D

@export var main_velocity: Vector3
@export var last_velocity: Vector3
@export var direction: Vector3

@export var current_speed: float

@export var jump_target_speed: float

@export var swimming_head_shapecast_position: Vector3
@export var is_under_water_effect_visible: bool

@export var state_chart: SerializedStateChart = null

## Element states of the player: {"properties": CogitoProperties.get_element_save_data(),
## "actor": CogitoActorElements.get_element_save_data()}. Empty in saves made before element states were saved.
@export var element_state : Dictionary = {}


func populate_player_data(player):
	load_common_data(player)
	player.uid = player_uid
	player.try_crouch = self.player_try_crouch
	# important: ensures the player isn't crouching on game load, regardless
	# of whether the option "Toggle Crouching" is set to OFF or ON
	
	## Loading player sitting state
	self.load_sitting_state(player) 
	self.load_collision_shapes(player)
	self.load_node_transforms(player)
	
	if CogitoSceneManager.scene_load_mode != CogitoSceneManager.CogitoSceneLoadMode.TEMP:
		player.main_velocity = self.main_velocity
		player.last_velocity = self.last_velocity
		player.direction = self.direction
	
		player.current_speed = self.current_speed
	
	if player.try_crouch:
		player.current_body_posture_state = CogitoPlayerAdvanced.BodyPostureState.Crouching
	else:
		player.current_body_posture_state = CogitoPlayerAdvanced.BodyPostureState.Standing
	
	_load_state_chart(player)
	
	player.jump_target_speed = jump_target_speed
	
	player.swimming_head_shapecast.global_position = swimming_head_shapecast_position
	player.under_water_effect.visible = is_under_water_effect_visible
	
	_load_element_state(player)
	

func _load_state_chart(player):
	StateChartSerializer.deserialize(state_chart, player.state_chart)


func populate_save_data(player, slot):
	save_common_data(player, slot)
	
	self.player_uid = player.uid
	self.player_try_crouch = player.try_crouch
	
	## Save player sitting state
	self.save_sitting_state(player)
	self.save_collision_shapes(player)
	self.save_node_transforms(player)
	
	self.main_velocity = player.main_velocity
	self.last_velocity = player.last_velocity
	self.direction = player.direction
	
	self.current_speed = player.current_speed
	
	jump_target_speed = player.jump_target_speed
	
	swimming_head_shapecast_position = player.swimming_head_shapecast.global_position
	is_under_water_effect_visible = player.under_water_effect.visible
	
	_save_state_chart(player)
	_save_element_state(player)


func _save_state_chart(player):
	state_chart = StateChartSerializer.serialize(player.state_chart)


func _save_element_state(player):
	element_state = {}
	var props : CogitoProperties = player.get("cogito_properties")
	if props:
		element_state["properties"] = props.get_element_save_data()
	var actor_elements : CogitoActorElements = player.get("actor_elements")
	if actor_elements:
		element_state["actor"] = actor_elements.get_element_save_data()


func _load_element_state(player):
	if element_state.is_empty():
		return
	# Deferred like the scene's element states, so the on-ready states of a freshly loaded level come first.
	var props : CogitoProperties = player.get("cogito_properties")
	if props and element_state.has("properties"):
		props.apply_element_save_data.call_deferred(element_state["properties"].duplicate(true))
	var actor_elements : CogitoActorElements = player.get("actor_elements")
	if actor_elements and element_state.has("actor"):
		actor_elements.apply_element_save_data.call_deferred(element_state["actor"].duplicate(true))


func save_node_transforms(player):
	player_transform = player.transform
	body_transform = player.get_node("Body").transform
	neck_transform = player.get_node("Body/Neck").transform
	head_transform = player.get_node("Body/Neck/Head").transform
	eyes_transform = player.get_node("Body/Neck/Head/Eyes").transform
	camera_transform = player.get_node("Body/Neck/Head/Eyes/Camera").transform


func load_node_transforms(player):
	player.transform = player_transform
	player.get_node("Body").transform = body_transform
	player.get_node("Body/Neck").transform = neck_transform
	player.get_node("Body/Neck/Head").transform = head_transform
	player.get_node("Body/Neck/Head/Eyes").transform = eyes_transform
	player.get_node("Body/Neck/Head/Eyes/Camera").transform = camera_transform


# Save the state of the player's collision shapes
func save_collision_shapes(player):
	standing_collision_shape_enabled = not player.standing_collision_shape.disabled
	crouching_collision_shape_enabled = not player.crouching_collision_shape.disabled


# Load the state of the player's collision shapes
func load_collision_shapes(player):
	player.standing_collision_shape.disabled = not standing_collision_shape_enabled
	player.crouching_collision_shape.disabled = not crouching_collision_shape_enabled


func save_sitting_state(player):
	is_sitting = player.is_sitting
	sittable_look_marker = player.sittable_look_marker if player.is_sitting else Vector3()
	sittable_look_angle = player.sittable_look_angle if player.is_sitting else 0.0
	moving_seat = player.moving_seat
	displacement_position = player.displacement_position if player.is_sitting else Vector3()
	original_position = player.original_position if player.is_sitting else Transform3D()
	original_neck_basis = player.original_neck_basis if player.is_sitting else Basis()
	is_ejected = player.is_ejected
	currently_tweening = player.currently_tweening
	if is_sitting:
		current_sittable_path = CogitoSceneManager._current_sittable_node.get_path()
		current_sittable_id = CogitoPersistentId.of(CogitoSceneManager._current_sittable_node)


func load_sitting_state(player):
	player.is_sitting = is_sitting
	player.sittable_look_marker = sittable_look_marker
	player.sittable_look_angle = sittable_look_angle
	player.moving_seat = moving_seat
	player.displacement_position = displacement_position
	player.original_position = original_position
	player.original_neck_basis = original_neck_basis
	player.is_ejected = is_ejected
	player.currently_tweening = currently_tweening
	if is_sitting and !current_sittable_id.is_empty():
		CogitoSceneManager._current_sittable_node = CogitoPersistentId.find(CogitoSceneManager.get_tree(), current_sittable_id)
	elif is_sitting and current_sittable_path != null:
		CogitoSceneManager._current_sittable_node = CogitoSceneManager.get_node(current_sittable_path)


# Functions for attributes
