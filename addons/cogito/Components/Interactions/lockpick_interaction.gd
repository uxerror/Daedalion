extends InteractionComponent
class_name LockpickInteraction

## Gets emitted when the lockpick interaction succeeds
signal lockpick_success
## Publishes prompt availability when an authored door locks or unlocks.
signal net_changed(event: StringName)

## PackedScene reference to the lockpick minigame. Uses its signals to control cancel / success / lockpick breaking.
@export var lockpick_minigame : PackedScene
## Item that is required to initialize the interaction. Will check player inventory for it.
@export var required_lockpick_item : InventoryItemPD
## Reference to doors (if not/additionally to parent)
@export var doors_to_unlock : Array[CogitoDoor]

@export_subgroup("Hint messages")
## Hint message if player has no lockpicks. Leave blank to not send one.
@export var lockpick_item_hint : String = "HINT_item_required"
## Hint message when the lockpick breaks, displays the item name first (eg. "[ITEM NAME] broke!" )
@export var lockpick_item_breaks_hint : String = "HINT_item_broke"
## Hint message when succeeding the interaction
@export var lockpick_success_hint : String = "HINT_lockpick_success"

var spawned_lockpick_game
var player_interaction_component : PlayerInteractionComponent
var _net_game: CogitoLockpickGame

@onready var lockpick_ui: Control = $LockpickUI
@onready var label_amount_lockpicks: Label = $LockpickUI/MarginContainer/PanelContainer/MarginContainer/HBoxContainer/AmountLockpicks
@onready var item_icon_texture: TextureRect = $LockpickUI/MarginContainer/PanelContainer/MarginContainer/HBoxContainer/MarginContainer/ItemIconTexture


func _ready() -> void:	
	# Precache lockpick minigame:
	spawned_lockpick_game = lockpick_minigame.instantiate()
	lockpick_ui.hide()
	
	if doors_to_unlock:
		for door in doors_to_unlock:
			door.lock_state_changed.connect(on_door_lock_state_change)


func _notification(what: int) -> void:
	# The authored precache is detached until the first solo interaction.
	if what == NOTIFICATION_PREDELETE and is_instance_valid(spawned_lockpick_game):
		if not spawned_lockpick_game.get_parent():
			spawned_lockpick_game.free()


## A lock with linked doors is available while at least one still needs unlocking.
func net_has_locked_target() -> bool:
	for door in doors_to_unlock:
		if is_instance_valid(door) and door.is_locked:
			return true
	return doors_to_unlock.is_empty()


## Prompt state only. Attempt state belongs to the acting peer's server session.
func net_state() -> Dictionary:
	return {"disabled": is_disabled}


## Update the prompt without emitting any door or minigame signals.
func apply_net_state(state: Dictionary, _silent: bool) -> void:
	is_disabled = state.disabled


## Attach presentation to the owner's head after the server grants the lock.
func open_net_interface(pic: PlayerInteractionComponent, count: int) -> void:
	player_interaction_component = pic
	_net_game = lockpick_minigame.instantiate()
	_net_game.net_devices = pic.network_interactions.devices
	pic.open_interface()
	pic.get_view_anchor().add_child(_net_game)
	item_icon_texture.texture = required_lockpick_item.square_icon
	label_amount_lockpicks.text = str(count)
	lockpick_ui.show()


## Apply actor-private progress and break feedback from the server.
func net_feedback(event: StringName, data: Dictionary) -> void:
	if _net_game:
		_net_game.net_feedback(event, data)
		if data.has("count"):
			label_amount_lockpicks.text = str(data.count)


## Release the owner interface and play any terminal animation locally.
func close_net_interface(event: StringName) -> void:
	if is_instance_valid(_net_game):
		_net_game.net_finish(event)
		_net_game = null
	lockpick_ui.hide()
	player_interaction_component.close_interface()


func interact(_player_interaction_component: PlayerInteractionComponent) -> void:
	# Check if player has lockpick item:
	if not check_for_item(_player_interaction_component, required_lockpick_item):
		if lockpick_item_hint:
			_player_interaction_component.send_hint(null, lockpick_item_hint)
		return
	
	player_interaction_component = _player_interaction_component
	player_interaction_component.open_interface()
	
	if !spawned_lockpick_game:
		spawned_lockpick_game = lockpick_minigame.instantiate()
	player_interaction_component.get_view_anchor().add_child(spawned_lockpick_game)
	
	spawned_lockpick_game.unlocked.connect(on_lock_picked)
	spawned_lockpick_game.cancelled.connect(on_cancel)
	spawned_lockpick_game.lockpick_broke.connect(discard_lockpick)
	
	# Pass player attribute if attribute check is not NONE
	if attribute_check != AttributeCheck.NONE:
		var fetched_attribute : CogitoAttribute
		fetched_attribute = player_interaction_component.get_attribute(attribute_to_check)
		spawned_lockpick_game.pass_player_attribute(fetched_attribute)
	
	# Set the UI to show the lockpick item icon and how many lockpicks the player is carrying:
	item_icon_texture.texture = required_lockpick_item.square_icon
	label_amount_lockpicks.text = str(get_lockpick_amount_in_inventory(required_lockpick_item.name))
	
	lockpick_ui.show()


func on_lock_picked() -> void:
	if lockpick_success_hint:
		player_interaction_component.send_hint(null, tr(lockpick_success_hint))
		
	lockpick_ui.hide()
	player_interaction_component.close_interface()
	
	if doors_to_unlock:
		for door in doors_to_unlock:
			door.unlock_door()

	lockpick_success.emit()
	spawned_lockpick_game.queue_free()
	player_interaction_component.targeting.rebuild_interaction_prompts()


func on_cancel() -> void:
	player_interaction_component.close_interface()
	spawned_lockpick_game.queue_free()
	lockpick_ui.hide()


func check_for_item(interactor, item) -> bool:
	var inventory = interactor.get_inventory()
	for slot_data in inventory.inventory_slots:
		if slot_data != null and slot_data.inventory_item == item:
			return true
	return false


func discard_lockpick() -> void:
	#	Lockpick Discard Logic, used when a lockpick breaks to remove one from inventory.
	var inventory = player_interaction_component.get_inventory()
	for slot_data in inventory.inventory_slots:
		if slot_data != null and slot_data.inventory_item == required_lockpick_item:
			player_interaction_component.send_hint(null, tr(required_lockpick_item.name) + " " + tr(lockpick_item_breaks_hint) )
			inventory.remove_item_from_stack(slot_data)
	
	var lockpicks_left : int = get_lockpick_amount_in_inventory(required_lockpick_item.name)
	
	# Refresh the lockpick amount display.
	label_amount_lockpicks.text = str(lockpicks_left)
	
	# Quit the minigame if the player runs out of lockpicks.
	if lockpicks_left <= 0:
		spawned_lockpick_game.exit_game()
	else:
		spawned_lockpick_game.grab_new_lockpick()


func get_lockpick_amount_in_inventory(item_name_to_check_for: String) -> int:
	var item_count : int = 0
	if player_interaction_component.get_inventory() != null:
		var inventory_to_check = player_interaction_component.get_inventory()
		for slot in inventory_to_check.inventory_slots:
			if slot != null and slot.inventory_item.name == item_name_to_check_for:
				item_count += slot.quantity
				
	return item_count


func on_door_lock_state_change(is_locked: bool) -> void:
	if is_locked:
		self.is_disabled = false
	else:
		self.is_disabled = true
	if has_meta(&"cogito_net_world"):
		is_disabled = not net_has_locked_target()
		net_changed.emit(&"")
