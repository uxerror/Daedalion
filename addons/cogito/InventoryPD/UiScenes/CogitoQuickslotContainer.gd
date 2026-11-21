extends SlotPanel
class_name CogitoQuickslotContainer

signal quickslot_pressed(quickslot_container: CogitoQuickslotContainer)
signal quickslot_cleared(quickslot_container: CogitoQuickslotContainer)

## The entry this container currently displays (null if empty).
var entry : CogitoQuickslotEntry
## Set when the displayed entry is an inventory item (CogitoItemQuickslotEntry), null otherwise.
var item_reference : InventoryItemPD
var inventory_slot_reference : InventorySlotPD

## Input action that activates this quickslot. Also used for the input icon.
@export var input_action : String = "quickslot_1"

## AudioStream that plays when slot gets highlighted.

@onready var item_texture: TextureRect = $MarginContainer/ItemTexture
@onready var label_stack_amount: Label = $MarginContainer/LabelStackAmount
@onready var dynamic_input_icon: DynamicInputIcon = $MarginContainerInputIcon/DynamicInputIcon


func _ready() -> void:
	item_texture.hide()
	label_stack_amount.hide()
	dynamic_input_icon.action_name = input_action
	dynamic_input_icon.update_input_icon()
	if entry:
		display_entry(entry)


func _on_gui_input(event):
	# LEFT CLICK ON QUICKSLOT CONTAINER
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.is_pressed():
				quickslot_pressed.emit(self)
	
	# RIGHT CLICK ON QUICKSLOT CONTAINER
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.is_pressed():
				clear_this_quickslot()
	
	# GAMEPAD ASSIGN HANDLING
	if event is InputEventJoypadButton and event.is_action_pressed("inventory_use_item"):
		quickslot_pressed.emit(self)
	
	# GAMEPAD ASSIGN HANDLING
	if event is InputEventJoypadButton and event.is_action_pressed("inventory_move_item"):
		clear_this_quickslot()


func clear_this_quickslot():
	display_entry(null)
	quickslot_cleared.emit(self)


## Displays an entry (icon, counter, availability). Passing null shows an empty slot.
func display_entry(new_entry: CogitoQuickslotEntry) -> void:
	entry = new_entry
	var item_entry := entry as CogitoItemQuickslotEntry
	inventory_slot_reference = item_entry.slot_data if item_entry else null
	item_reference = item_entry.get_item() if item_entry else null
	
	if !is_node_ready():
		return
	
	if !entry:
		item_texture.hide()
		label_stack_amount.hide()
		return
	
	item_texture.texture = entry.get_icon()
	item_texture.modulate = Color.WHITE if entry.is_available() else Color(1, 1, 1, 0.4)
	item_texture.show()
	
	var count : int = entry.get_count()
	if count >= 0:
		label_stack_amount.text = str(count)
		label_stack_amount.show()
	else:
		label_stack_amount.hide()
	

## Legacy: redraws the displayed entry. Quickslot sets now refresh their views automatically.
func update_quickslot_stack():
	display_entry(entry)


## Legacy: displays an inventory slot. Prefer binding entries to the CogitoQuickslotSet of CogitoQuickslots.
func update_quickslot_data(slot_data: InventorySlotPD) -> void:
	CogitoGlobals.debug_log(true,"COgitoQuickslotContainer", "update_quickslot_data(): passed slot_data was " + str(slot_data) )
	display_entry(CogitoItemQuickslotEntry.new(slot_data) if slot_data else null)
		

func get_item() -> InventoryItemPD:
	return item_reference

func set_slot_data(_a, _b, _c, _d) -> void:
	# Adding this method so the control node focus management of inventory_interface.gd
	# will treat this like a regular inventory slot.
	pass

func _on_focus_entered() -> void:
	CogitoAudio.play_sound(sound_highlight)
	selection_panel.show()

func _on_focus_exited() -> void:
	selection_panel.hide()
