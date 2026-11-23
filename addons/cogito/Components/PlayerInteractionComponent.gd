extends Node3D
class_name PlayerInteractionComponent
## Handles the player's interaction input and passes it to interactables.
## What the player looks at, carrying and wieldables live in the child nodes targeting, carrying and wieldables.

# Signals for UI/HUD use
signal interaction_prompt(interaction_text: String)
signal hint_prompt(hint_icon: Texture2D, hint_text: String)
signal updated_wieldable_data(wielded_item: WieldableItemPD, ammo_in_inventory: int, ammo_item: AmmoItemPD)
# Signals for Interaction raycast system
signal interactive_object_detected(interaction_nodes: Array[Node])
signal nothing_detected()
signal started_carrying(interaction_node: Node)
signal update_crosshair(is_visible: bool)

var look_vector: Vector3
var device_id: int = -1  # Used for displaying correct input prompts depending on input device.

## Raycast3D for interaction check.
@export var interaction_raycast: InteractionRayCast
@export var carryable_position: Node3D

# Power with which object are thrown (opposed to being dropped)
#@export var throw_power: float = 10
@export_group("Throw Settings")
## The maximum power you can apply to a thrown object
@export var max_throw_power: float = 25.0
## Multiplied with the mass of the thrown object, up to the Max Throw Power. Prevents throwing lightweight objects incredibly fast.
@export var throw_power_mass_multiplier: float = 10.0
## Drain stamina if calculated throw power exceeds this value
@export var throw_stamina_threshold: float = 20.0
@export var throw_stamina_drain: float = 5.0
## When stamina is below cost on a throw attempt, drop instead
@export var drop_when_cant_throw: bool = true
## Leave empty to ignore stamina cost evaluation when throwing
@export var stamina_attribute: CogitoAttribute
var player: CogitoPlayer

@export_group("Drop Settings")
## The maximum power you can use when dropping objects
@export var max_drop_power: float = 1.0
## Multiplied by the mass of the thrown object, up to the Max Drop Power
@export var drop_power_mass_multiplier: float = 1.0

@export_group("Wieldable Settings")
## List of Wieldable nodes
@export var wieldable_nodes: Array[Node]
@export var wieldable_container: Node3D

var player_rid
# Briefly interrupt quickslot cycling after an interactable is unseen
var can_cycle_quickslots: bool = true
@onready var cycle_quickslots_interrupt_timer: Timer = $Timer

@onready var targeting: InteractionTargeting = $InteractionTargeting
@onready var carrying: CarryHandler = $CarryHandler
@onready var wieldables: WieldableHandler = $WieldableHandler


func _ready():
	player = get_parent() as CogitoPlayer
	cycle_quickslots_interrupt_timer.connect("timeout", Callable(self, "_on_can_cycle_quickslots_timeout"))


func exclude_player(rid: RID):
	player_rid = rid
	interaction_raycast.add_exception_rid(rid)


func _process(_delta):
	pass


func on_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") or event.is_action_pressed("interact2"):
		var action: String = "interact" if event.is_action_pressed("interact") else "interact2"
		start_interaction(action)

	if event.is_action_pressed("action_primary"):
		wieldables.primary_action_held = true
		if carrying.is_carrying and is_instance_valid(carrying.carried_object):
			carrying.attempt_throw()
			get_viewport().set_input_as_handled()
		elif wieldables.is_wielding:
			wieldables.attempt_action_primary(false)
			get_viewport().set_input_as_handled()

	elif event.is_action_released("action_primary"):
		wieldables.primary_action_held = false
		if wieldables.is_wielding and !carrying.is_carrying:
			wieldables.attempt_action_primary(true)
			get_viewport().set_input_as_handled()

	if event.is_action_pressed("action_secondary"):
		if wieldables.is_wielding:
			wieldables.attempt_action_secondary(false)
			get_viewport().set_input_as_handled()
	elif event.is_action_released("action_secondary"):
		if wieldables.is_wielding:
			wieldables.attempt_action_secondary(true)
			get_viewport().set_input_as_handled()

	if event.is_action_pressed("change_ammo_type") and wieldables.is_wielding:
		wieldables.attempt_change_ammo()

	if event.is_action_pressed("reload") and wieldables.is_wielding:
		# The below is a fix to avoid triggering reload when player attempts to interact and both actions are bound to same (gamepad) button
		if InputHelper.device_index == -1: # If mouse/keyboard
			wieldables.attempt_reload()
		else:
			if targeting.interactable == null:
				wieldables.attempt_reload()

## Interacts with the current target (targeting.interactable) using the given input action, like pressing that action does.
## Lets other controllers trigger interactions, for example after walking to an object that was clicked.
func start_interaction(action: String) -> void:
	# if carrying an object, drop it.
	if carrying.is_carrying:
		if is_instance_valid(carrying.carried_object):
			if carrying.carried_object.input_map_action == action:
				carrying.drop_carried_object()
				#carried_object.throw(1)
				return
			else:
				# Allow 'take' input actions for the carried object
				var carry_parent: CogitoObject = carrying.carried_object.get_parent() as CogitoObject
				if carry_parent:
					for node: InteractionComponent in carry_parent.interaction_nodes:
						if node.input_map_action == action and not node.is_disabled:
							if node is PickupComponent or node is BackpackComponent or node is ExtendedPickupInteraction:
								if !node.ignore_open_gui and get_parent().is_showing_ui:
									return
								node.interact(self)

								#Dual interaction components need to await signal to update correctly
								if node is DualInteraction or node is ExtendedPickupInteraction:
									await node.interaction_complete  # Wait until the interaction_complete signal is recieved
									targeting.rebuild_interaction_prompts()  # rebuild prompt after signal is received
								else:
									# Update the prompts after an interaction. This is especially crucial for doors and switches.
									targeting.rebuild_interaction_prompts()
								break
		else:
			carrying.stop_carrying()
			return

	# Check if we have an interactable in view and are pressing the correct button
	if targeting.interactable != null and not carrying.is_carrying:
		for node: InteractionComponent in targeting.interactable.interaction_nodes:
			if node.input_map_action == action and not node.is_disabled:
				if player.get("is_in_interaction_state") and !player.is_in_interaction_state or (!player.is_on_floor() and node.disable_interaction_in_air):
					return

				if !node.ignore_open_gui and get_parent().is_showing_ui:
					return
				node.interact(self)

				#Dual interaction components need to await signal to update correctly
				if node is DualInteraction or node is ExtendedPickupInteraction:
					#(player.player_hud as CogitoPlayerHudManager).hold_ui.
					await node.interaction_complete  # Wait until the interaction_complete signal is recieved
					targeting.rebuild_interaction_prompts()  # rebuild prompt after signal is received
				else:
					# Update the prompts after an interaction. This is especially crucial for doors and switches.
					targeting.rebuild_interaction_prompts()
				break


## Performs an action from InteractionComponent.get_actions(), for example one picked from a context menu.
## Checks the same things as start_interaction() and updates the prompts afterwards.
func perform_action(action: CogitoInteractionAction) -> void:
	if !action.enabled:
		return
	var node := action.component
	# While carrying, only the carried object's own actions work, like with input actions in start_interaction().
	if carrying.is_carrying:
		if !is_instance_valid(carrying.carried_object) or node.get_parent() != carrying.carried_object.get_parent():
			return
	if player.get("is_in_interaction_state") and !player.is_in_interaction_state or (!player.is_on_floor() and node.disable_interaction_in_air):
		return
	if !node.ignore_open_gui and get_parent().is_showing_ui:
		return
	await action.perform(self)
	targeting.rebuild_interaction_prompts()


func on_death():
	if wieldables.equipped_wieldable_item:
		wieldables.equipped_wieldable_item.is_being_wielded = false

	if carrying.carried_object:
		carrying.carried_object = null


# Function called by interactables if they need to send a hint. The signal sent here gets picked up by the Player_Hud_Manager.
func send_hint(hint_icon: Texture2D, hint_text: String):
	hint_prompt.emit(hint_icon, hint_text)


#region Interaction contract
# What interactables may use from the one interacting with them, instead of reaching into the player node.

## Returns the attribute with this name (for example "health" or "stamina"), or null if there is none.
func get_attribute(attribute_name: String) -> CogitoAttribute:
	return player.player_attributes.get(attribute_name)


## Called by interactables that open their own UI (keypad, readable, etc). The player stops moving and looking around while it is open.
## If on_menu_pressed is valid, it gets called with this component when the menu action is pressed, usually to close that UI.
func open_interface(on_menu_pressed: Callable = Callable()) -> void:
	player.toggled_interface.emit(true)
	if on_menu_pressed.is_valid():
		player.menu_pressed.connect(on_menu_pressed)


## Counterpart of open_interface(). Pass the same on_menu_pressed that was passed to open_interface().
func close_interface(on_menu_pressed: Callable = Callable()) -> void:
	if on_menu_pressed.is_valid():
		player.menu_pressed.disconnect(on_menu_pressed)
	player.toggled_interface.emit(false)


func get_hud() -> CogitoHud:
	return player.player_hud


## Turns mouse and stick look on or off, for example while the player rotates a carried object.
func set_mouselook_enabled(is_enabled: bool) -> void:
	player.is_mouselook_active = is_enabled


## Node that follows the player's view, for interactables that show 3D content in front of the player (like the lockpick minigame).
func get_view_anchor() -> Node3D:
	return player.head
#endregion


func save():
	return wieldables.save()


func set_state():
	wieldables.set_state()


func _on_interaction_raycast_interactable_seen(new_interactable) -> void:
	targeting.interactable = new_interactable


func _on_interaction_raycast_interactable_unseen() -> void:
	targeting.interactable = null
	can_cycle_quickslots = false
	cycle_quickslots_interrupt_timer.start()


## Briefly interrupt quickslot cycling after an interactable is unseen
## This prevents incidental quickslot cycling when only attempting to interact with an item in the world that uses the same input action
func _on_can_cycle_quickslots_timeout() -> void:
	can_cycle_quickslots = true


func get_inventory() -> CogitoInventory:
	return get_parent().inventory_data


#region Forwarding to child nodes
# Kept so existing code using these members on PlayerInteractionComponent keeps working.
# Use the child nodes targeting, carrying and wieldables instead.

## @deprecated: Use [code]targeting.interactable[/code] instead.
var interactable:
	get: return targeting.interactable
	set(value): targeting.interactable = value

## @deprecated: Use [code]carrying.carried_object[/code] instead.
var carried_object:
	get: return carrying.carried_object
	set(value): carrying.carried_object = value

## @deprecated: Use [code]carrying.is_carrying[/code] instead.
var is_carrying: bool:
	get: return carrying.is_carrying

## @deprecated: Use [code]wieldables.is_changing_wieldables[/code] instead.
var is_changing_wieldables: bool:
	get: return wieldables.is_changing_wieldables
	set(value): wieldables.is_changing_wieldables = value

## @deprecated: Use [code]wieldables.equipped_wieldable_item[/code] instead.
var equipped_wieldable_item: WieldableItemPD:
	get: return wieldables.equipped_wieldable_item
	set(value): wieldables.equipped_wieldable_item = value

## @deprecated: Use [code]wieldables.equipped_wieldable_node[/code] instead.
var equipped_wieldable_node: CogitoWieldable:
	get: return wieldables.equipped_wieldable_node
	set(value): wieldables.equipped_wieldable_node = value

## @deprecated: Use [code]wieldables.wieldable_was_on[/code] instead.
var wieldable_was_on: bool:
	get: return wieldables.wieldable_was_on
	set(value): wieldables.wieldable_was_on = value

## @deprecated: Use [code]wieldables.is_wielding[/code] instead.
var is_wielding: bool:
	get: return wieldables.is_wielding

## @deprecated: Use [code]wieldables.wieldable_item_to_auto_equip[/code] instead.
var wieldable_item_to_auto_equip: WieldableItemPD:
	get: return wieldables.wieldable_item_to_auto_equip
	set(value): wieldables.wieldable_item_to_auto_equip = value

## @deprecated: Use [code]wieldables.auto_equip_wieldable_after_carrying[/code] instead.
var auto_equip_wieldable_after_carrying: bool:
	get: return wieldables.auto_equip_wieldable_after_carrying
	set(value): wieldables.auto_equip_wieldable_after_carrying = value

## @deprecated: Use [code]wieldables.primary_action_held[/code] instead.
var primary_action_held: bool:
	get: return wieldables.primary_action_held
	set(value): wieldables.primary_action_held = value


## @deprecated: Use [method start_interaction] instead.
func _handle_interaction(action: String) -> void:
	await start_interaction(action)


## @deprecated: Use [code]targeting.is_interaction_raycast_colliding()[/code] instead.
func is_interaction_raycast_colliding() -> bool:
	return targeting.is_interaction_raycast_colliding()


## @deprecated: Use [code]targeting.get_interaction_raycast_tip()[/code] instead.
func get_interaction_raycast_tip(distance_offset: float) -> Vector3:
	return targeting.get_interaction_raycast_tip(distance_offset)


## @deprecated: Use [code]targeting.get_look_direction()[/code] instead.
func get_look_direction() -> Vector3:
	return targeting.get_look_direction()


## @deprecated: Use [code]targeting.rebuild_interaction_prompts()[/code] instead.
func _rebuild_interaction_prompts() -> void:
	targeting.rebuild_interaction_prompts()


## @deprecated: Use [code]carrying.get_carryable_destination_point()[/code] instead.
func get_carryable_destination_point(distance_offset: float) -> Vector3:
	return carrying.get_carryable_destination_point(distance_offset)


## @deprecated: Use [code]carrying.start_carrying()[/code] instead.
func start_carrying(_carried_object):
	carrying.start_carrying(_carried_object)


## @deprecated: Use [code]carrying.stop_carrying()[/code] instead.
func stop_carrying():
	carrying.stop_carrying()


## @deprecated: Use [code]carrying.get_carried_object_mass()[/code] instead.
func get_carried_object_mass(carried_object) -> float:
	return carrying.get_carried_object_mass(carried_object)


## @deprecated: Use [code]carrying.attempt_throw()[/code] instead.
func _attempt_throw() -> void:
	carrying.attempt_throw()


## @deprecated: Use [code]carrying.drop_carried_object()[/code] instead.
func _drop_carried_object() -> void:
	carrying.drop_carried_object()


## @deprecated: Use [code]wieldables.equip_wieldable()[/code] instead.
func equip_wieldable(wieldable_item: WieldableItemPD):
	await wieldables.equip_wieldable(wieldable_item)


## @deprecated: Use [code]wieldables.change_wieldable_to()[/code] instead.
func change_wieldable_to(next_wieldable: InventoryItemPD):
	await wieldables.change_wieldable_to(next_wieldable)


## @deprecated: Use [code]wieldables.attempt_action_primary()[/code] instead.
func attempt_action_primary(is_released: bool):
	wieldables.attempt_action_primary(is_released)


## @deprecated: Use [code]wieldables.attempt_action_secondary()[/code] instead.
func attempt_action_secondary(is_released: bool):
	wieldables.attempt_action_secondary(is_released)


## @deprecated: Use [code]wieldables.attempt_change_ammo()[/code] instead.
func attempt_change_ammo():
	wieldables.attempt_change_ammo()


## @deprecated: Use [code]wieldables.attempt_reload()[/code] instead.
func attempt_reload():
	wieldables.attempt_reload()


## @deprecated: Use [code]wieldables.get_camera_collision()[/code] instead.
func get_camera_collision() -> Vector3:
	return wieldables.get_camera_collision()


## @deprecated: Use [code]wieldables.setup_wieldable_to_auto_equip()[/code] instead.
func setup_wieldable_to_auto_equip(next_wieldable: WieldableItemPD = null) -> void:
	wieldables.setup_wieldable_to_auto_equip(next_wieldable)


## @deprecated: Use [code]wieldables.auto_equip_last_wieldable()[/code] instead.
func auto_equip_last_wieldable() -> void:
	await wieldables.auto_equip_last_wieldable()


## @deprecated: Use [code]wieldables.update_equipped()[/code] instead.
func update_equipped() -> void:
	wieldables.update_equipped()
#endregion
