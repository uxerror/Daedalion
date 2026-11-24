@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoPlayer.svg")
## The player class controls movement from input from the mouse, keyboard, and gamepad, as well as behavior parameters like stair and ladder handling.
## This base class holds what the rest of Cogito expects from any player controller. Extend it to make your own.
@abstract class_name CogitoPlayer
extends CharacterBody3D

## Emits when ESC/Menu input map action is pressed. Can be used to exit out other interfaces, etc.
signal menu_pressed(player_interaction_component: PlayerInteractionComponent)
signal player_state_loaded()
## Used to hide UI elements like the crosshair when another interface is active (like a container or readable)
signal toggled_interface(is_showing_ui:bool)
## Emitted when elemental damage (fire, cold, poison, shock...) was dealt to the player, see CogitoProperties.deal_elemental_damage().
signal elemental_damage_received(amount: float, element: CogitoProperties.Element, source: Node)

## Set before tree entry. Only the local avatar presents UI and owns viewport input.
@export var is_local_presentation: bool = true

## Seat driving this actor. The facade retains the local seat for legacy callers and saves.
var current_seat: CogitoSittable:
	get:
		return CogitoSceneManager._current_sittable_node if is_local_presentation else current_seat
	set(value):
		current_seat = value
		if is_local_presentation:
			CogitoSceneManager._current_sittable_node = value

## Refereence to Player HUD node
@export var player_hud : CogitoHud
# Used for handling input when UI is open/displayed
var is_showing_ui : bool
## Toggle printing debug messages or not. Works with the CogitoSceneManager
@export var is_logging : bool
## Inventory resource that stores the player inventory.
@export var inventory_data : CogitoInventory
## Mouse mode while playing. Interfaces and menus restore it when they close (see CogitoSceneManager.restore_gameplay_mouse_mode()).
## First person players capture the mouse; a player controlled with the cursor keeps it visible.
@export var gameplay_mouse_mode : Input.MouseMode = Input.MOUSE_MODE_CAPTURED
## Item Drop Shapecast
@export var item_drop_shapecast : ShapeCast3D

### NEW PLAYER ATTRIBUTE SYSTEM:
var player_attributes : Dictionary
var stamina_attribute : CogitoAttribute = null
var visibility_attribute : CogitoAttribute

### CURRENCIES
var player_currencies: Dictionary
## Progression from older quest implementations, retained across load/save.
var saved_quest_progression: Dictionary

var is_mouselook_active: bool = true
## @deprecated: Use [code]CogitoPersistentId.of()[/code] to identify the player in save data.
var uid: int = -1
var main_velocity : Vector3 = Vector3.ZERO
var is_dead : bool = false
## Radius of the player's collision shapes, set with _calculate_player_radius().
var radius : float

### ELEMENTS
## The player's CogitoProperties (element states), or null. Lets CogitoProperties.get_properties_of() find it.
var cogito_properties : CogitoProperties = null
## The player's CogitoActorElements (element effects on movement and actions), or null.
var actor_elements : CogitoActorElements = null

@export_group("Node Paths")
## The PlayerInteractionComponent of this player. Required.
@export_node_path("Node3D") var player_interaction_component_path : NodePath = ^"PlayerInteractionComponent"
## The node that turns when the player turns. Its rotation is saved, and set when entering a scene through a connector.
@export_node_path("Node3D") var body_path : NodePath = ^"Body"
## The node at the player's point of view. Things shown in front of the player (like the lockpick minigame) are attached to it.
@export_node_path("Node3D") var head_path : NodePath = ^"Body/Neck/Head"
@export_group("")

# Node caching
@onready var player_interaction_component: PlayerInteractionComponent = get_node(player_interaction_component_path)
@onready var body: Node3D = get_node(body_path)
@onready var head: Node3D = get_node(head_path)


@abstract func create_new_state() -> CogitoPlayerState


## Stops the player from moving and acting, for example while a loading screen or the death screen is shown.
## Does nothing by default; override it if your player has states to pause.
func pause() -> void:
	pass


## Lets the player move and act again after pause().
## Does nothing by default; override it if your player has states to pause.
func resume() -> void:
	pass


## Sets the gravity acting on the player, for example inside a gravity zone. Called again with the defaults on leaving it.
## Does nothing by default; override it if your player has its own gravity.
func override_gravity(_external_gravity_force : float, _external_gravity_vector: Vector3):
	pass


## Collects the CogitoAttribute and CogitoCurrency children of the player and connects them: health to death,
## visibility to sanity. Player controllers call this in _ready().
func setup_attributes_and_currencies() -> void:
	### NEW PLAYER ATTRIBUTE SETUP:
	# Grabs all attached player attributes
	for attribute in find_children("","CogitoAttribute",false):
		player_attributes[attribute.attribute_name] = attribute
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Cogito Attribute found: " + attribute.attribute_name)

	# If found, hookup health attribute signal to detect player death
	var health_attribute = player_attributes.get("health")
	if health_attribute:
		health_attribute.death.connect(_on_death)
	# Save reference to stamina attribute for movements that require stamina checks (null if not found)
	stamina_attribute = player_attributes.get("stamina")
	# Save reference to visibilty attribute for that require visibility checks (null if not found)
	visibility_attribute = player_attributes.get("visibility")
	# Hookup sanity attribute to visibility attribute
	var sanity_attribute = player_attributes.get("sanity")
	if sanity_attribute and visibility_attribute:
		visibility_attribute.attribute_changed.connect(sanity_attribute.on_visibility_changed)
		visibility_attribute.check_current_visibility()

	### CURRENCY SETUP
	for currency in find_children("", "CogitoCurrency", false):
		player_currencies[currency.currency_name] = currency
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Cogito Currency found: " + currency.currency_name)


## Finds the player's CogitoActorElements and CogitoProperties children. Player controllers that support
## element states call this in _ready().
func setup_elements() -> void:
	for child in get_children():
		if child is CogitoActorElements and !actor_elements:
			actor_elements = child
		elif child is CogitoProperties and !cogito_properties:
			cogito_properties = child
	if actor_elements and actor_elements.properties:
		cogito_properties = actor_elements.properties


## False while an element state keeps the player from acting (stunned, frozen). Checked before
## interacting, using wieldables and using items.
func can_act() -> bool:
	return actor_elements == null or actor_elements.can_act()


## Multiplier for the player's movement speed from element states (chilled, frozen, stunned). 1 without CogitoActorElements.
func get_element_speed_multiplier() -> float:
	return actor_elements.speed_multiplier if actor_elements else 1.0


## Called by CogitoProperties.deal_elemental_damage(): the damage already has resistances applied.
func receive_elemental_damage(amount: float, element: CogitoProperties.Element, source: Node = null, _hit_direction := Vector3.ZERO, _hit_position := Vector3.ZERO) -> void:
	if is_dead:
		return
	decrease_attribute("health", amount)
	elemental_damage_received.emit(amount, element, source)


func _on_death():
	player_interaction_component.on_death()
	is_dead = true


# Use these functions to manipulate player attributes.
func increase_attribute(attribute_name: String, value: float, value_type: ConsumableItemPD.ValueType) -> bool:
	var attribute = player_attributes.get(attribute_name)
	if not attribute:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Increase attribute: Attribute not found")
		return false
	if value_type == ConsumableItemPD.ValueType.CURRENT:
		if attribute.value_current == attribute.value_max:
			return false
		attribute.add(value)
		return true
	elif value_type == ConsumableItemPD.ValueType.MAX:
		attribute.value_max += value
		attribute.add(value)
		return true
	return false


func decrease_attribute(attribute_name: String, value: float):
	var attribute = player_attributes.get(attribute_name)
	if not attribute:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Decrease attribute: " + attribute_name + " - Attribute not found")
		return
	attribute.subtract(value)


# Use these functions to manipulate player currencies.
func increase_currency(currency_name: String, value: float) -> bool:
	var currency = player_currencies.get(currency_name)
	if not currency:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Increase currency: Currency not found")
		return false
	else:
		currency.add(value)
		return true


func decrease_currency(currency_name: String, value: float):
	var currency = player_currencies.get(currency_name)
	if not currency:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Decrease currency: " + currency_name + " - Currency not found")
		return
	currency.subtract(value)


func apply_external_force(force_vector: Vector3):
	if force_vector and force_vector.length() > 0:
		CogitoGlobals.debug_log(is_logging, "cogito_player.gd", "Applying external force " + str(force_vector))
		velocity += force_vector
		move_and_slide()


## A stationary input frame retaining the current look, including after a load or teleport.
func neutral_command(sequence: int) -> CogitoPlayerCommand:
	var command := CogitoPlayerCommand.new()
	command.sequence = sequence
	command.yaw = body.rotation.y
	command.pitch = head.rotation.x
	return command


## Aim origin and orientation for interaction, carrying and wieldables.
## Custom offline controllers default to the viewport camera.
func get_aim_transform() -> Transform3D:
	var view := get_viewport().get_camera_3d()
	return view.global_transform if view else head.global_transform


## Drops the item in the slot into the world in front of the camera, where item_drop_shapecast finds room for it.
## Returns false if there is no room. Override it for a different way of dropping items.
func drop_item(slot_data: InventorySlotPD) -> bool:
	var player_radius = radius
	var shape_cast = item_drop_shapecast
	var item_drop_distance_offset = player_hud.item_drop_distance_offset if player_hud else 0.0
	var camera_basis_z = get_aim_transform().basis.z
	
	var drop_distance = abs(shape_cast.target_position.z - item_drop_distance_offset)
	
	var scene_to_drop = load(slot_data.inventory_item.drop_scene)
	var dropped_item = scene_to_drop.instantiate()
	
	if dropped_item is not CogitoObject:		
		return false
	
	# Pass the existing data of the slot to the object, otherwise infinite ammo glitch
	dropped_item.pass_inventory_data(slot_data.duplicate())
		
	var item_aabb = dropped_item.get_aabb()
	var item_length = item_aabb.size.z
	
	shape_cast.add_exception(self)
	
	shape_cast.shape.size = item_aabb.size
	
	var previous_target_position = shape_cast.target_position
	shape_cast.target_position = Vector3.ZERO
	
	shape_cast.force_shapecast_update()
	
	if shape_cast.is_colliding():
		shape_cast.target_position = previous_target_position
		return false
	
	shape_cast.target_position = previous_target_position
	
	shape_cast.force_shapecast_update()
	
	var collision_safe_fraction = shape_cast.get_closest_collision_safe_fraction()
	var safe_drop_distance = drop_distance * collision_safe_fraction
	
	if item_length < player_radius:
		if safe_drop_distance < player_radius:
			return false
	else:
		if safe_drop_distance < item_length:
			return false
			
	CogitoLevel.root_of(self).add_child(dropped_item)
	dropped_item.global_rotation = body.global_rotation
	dropped_item.position = shape_cast.global_position + (safe_drop_distance - item_length / 2) * -camera_basis_z
		
	if is_local_presentation:
		CogitoAudio.play_sound(slot_data.inventory_item.sound_drop)
	
	if item_length < player_radius:
		dropped_item.position = shape_cast.global_position + (safe_drop_distance - item_length / 2) * -camera_basis_z
	else:
		dropped_item.position = shape_cast.global_position + (safe_drop_distance - item_length / 2 + player_radius) * -camera_basis_z
		
	dropped_item.find_interaction_nodes()
	for node in dropped_item.interaction_nodes:
		if node.has_method("get_item_type"):
			node.slot_data = slot_data
	return true


func _calculate_player_radius():
	var radius : float = 0.0
	for child in find_children("*", "CollisionShape3D", false, false):
		if child.shape is BoxShape3D:
			var edge = max(child.shape.size.x, child.shape.size.z)
			var r = sqrt(2 * pow(edge / 2, 2))
			radius = max(r, radius)
		elif child.shape is CylinderShape3D or child.shape is CapsuleShape3D:
			radius = max(child.shape.radius, radius)
	
	return radius
