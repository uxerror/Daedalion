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

## Refereence to Player HUD node
@export var player_hud : CogitoPlayerHudManager
# Used for handling input when UI is open/displayed
var is_showing_ui : bool
## Toggle printing debug messages or not. Works with the CogitoSceneManager
@export var is_logging : bool
## Inventory resource that stores the player inventory.
@export var inventory_data : CogitoInventory

### NEW PLAYER ATTRIBUTE SYSTEM:
var player_attributes : Dictionary
var stamina_attribute : CogitoAttribute = null
var visibility_attribute : CogitoAttribute

### CURRENCIES
var player_currencies: Dictionary

var is_mouselook_active: bool = true
## @deprecated: Use [code]CogitoPersistentId.of()[/code] to identify the player in save data.
var uid: int = -1
var main_velocity : Vector3 = Vector3.ZERO
var is_dead : bool = false

# Node caching
@onready var player_interaction_component: PlayerInteractionComponent = $PlayerInteractionComponent
@onready var body: Node3D = $Body
@onready var head: Node3D = $Body/Neck/Head


@abstract func create_new_state() -> CogitoPlayerState
@abstract func pause() -> void
@abstract func resume() -> void
@abstract func override_gravity(_external_gravity_force : float, _external_gravity_vector: Vector3)


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
