extends CogitoUiButton
class_name CogitoSaveSlotButton

@onready var screenshot_spot: TextureRect = $MarginContainer/HBoxContainer/Screenshot_Spot
@onready var slot_name_label: Label = $MarginContainer/HBoxContainer/VBoxContainer/SlotName
@onready var save_time_label: Label = $MarginContainer/HBoxContainer/VBoxContainer/SaveTime

@export var save_slot_manager_node : Control
@export var manual_save_slot_name : String
@export var empty_slot_screenshot : Texture2D

var slot_status := CogitoSceneManager.SlotStatus.EMPTY

func _ready() -> void:
	pressed.connect(_on_save_slot_button_pressed)

	### BRINGING THIS OVER FROM CogitoUiButton due to the override.
	#Attempt to make this work with focus
	self.focus_entered.connect(_on_focus_entered)
	self.focus_exited.connect(_on_focus_exited)
	self.pressed.connect(_on_pressed)
	
	# Duplicate the normal stylebox. We are going to use it as our base stylebox
	tween_stylebox = get_theme_stylebox('normal').duplicate()
	
	# Save the different styleboxes to be able to tween between their properties later
	styleboxes[BaseButton.DRAW_NORMAL] = get_theme_stylebox('normal').duplicate()
	styleboxes[BaseButton.DRAW_HOVER] = get_theme_stylebox('hover').duplicate()
	styleboxes[BaseButton.DRAW_PRESSED] = get_theme_stylebox('pressed').duplicate()
	styleboxes[BaseButton.DRAW_HOVER_PRESSED] = get_theme_stylebox('pressed').duplicate()
	
	# Override all the other styleboxes with our tween stylebox
	add_theme_stylebox_override('normal', tween_stylebox)
	add_theme_stylebox_override('hover', tween_stylebox)
	add_theme_stylebox_override('focus', tween_stylebox)
	add_theme_stylebox_override('pressed', tween_stylebox)


func refresh() -> void:
	var slot := CogitoSceneManager.prepare_slot(manual_save_slot_name)
	slot_status = slot.status
	screenshot_spot.texture = CogitoSceneManager.slot_screenshot(slot.player, empty_slot_screenshot)
	save_time_label.text = ""
	match slot_status:
		CogitoSceneManager.SlotStatus.EMPTY:
			slot_name_label.text = tr("TXT_EMPTY_SLOT")
		CogitoSceneManager.SlotStatus.BROKEN:
			slot_name_label.text = tr("TXT_SLOT") + " " + manual_save_slot_name
			save_time_label.text = slot.reason
		CogitoSceneManager.SlotStatus.OK:
			slot_name_label.text = tr("TXT_SLOT") + " " + manual_save_slot_name
			var offset: int = Time.get_time_zone_from_system().bias * 60
			save_time_label.text = Time.get_datetime_string_from_unix_time(slot.player.player_state_savetime + offset, true)


func _on_save_slot_button_pressed() -> void:
	if CogitoSceneManager.previous_menu == "pause_menu":
		if CogitoSceneManager.previous_menu_button_pressed == "save":
			if slot_status != CogitoSceneManager.SlotStatus.EMPTY:
				show_save_confirmation_dialog()
			else:
				save_in_slot()
			return
		elif CogitoSceneManager.previous_menu_button_pressed == "load":
			if slot_status != CogitoSceneManager.SlotStatus.EMPTY:
				var last_saved_slot = CogitoSceneManager.get_last_saved_slot()
				if CogitoSceneManager._active_slot == last_saved_slot and manual_save_slot_name != last_saved_slot:
					show_load_confirmation_dialog()
				else:
					load_from_slot()
			return
	
	if slot_status != CogitoSceneManager.SlotStatus.EMPTY:
		load_from_slot()


func show_save_confirmation_dialog():
	var dialog = ConfirmationDialog.new() 
	dialog.title = tr("SAVE_CONFIRMATION_DIALOG_TITLE")
	dialog.dialog_text = tr("SAVE_CONFIRMATION_DIALOG_TEXT")
	
	dialog.canceled.connect (dialog_save_canceled)
	dialog.confirmed.connect (dialog_save_confirmed)
	
	add_child(dialog)	
	dialog.popup_centered()
	dialog.show()


func dialog_save_confirmed():
	save_in_slot()


func dialog_save_canceled():
	pass


func show_load_confirmation_dialog():
	var dialog = ConfirmationDialog.new() 
	dialog.title = tr("LOAD_CONFIRMATION_DIALOG_TITLE")
	dialog.dialog_text = tr("LOAD_CONFIRMATION_DIALOG_TEXT")
	
	dialog.canceled.connect (dialog_load_canceled)
	dialog.confirmed.connect (dialog_load_confirmed)
	
	add_child(dialog)	
	dialog.popup_centered()
	dialog.show()


func dialog_load_confirmed():
	load_from_slot()


func dialog_load_canceled():
	pass


func save_in_slot() -> Error:
	var error := CogitoSceneManager.save_game(manual_save_slot_name)
	if error != OK:
		save_time_label.text = CogitoSceneManager.last_slot_message
		return error
	refresh()
	CogitoSceneManager.previous_menu = ""
	CogitoSceneManager.previous_menu_button_pressed = ""
	CogitoSceneManager.game_menu.show()
	CogitoSceneManager.save_load_menu.hide()
	CogitoSceneManager.pause_menu.load_slot_data()
	return OK


func load_from_slot() -> Error:
	var error := await CogitoSceneManager.loading_saved_game(manual_save_slot_name)
	if error != OK:
		save_time_label.text = CogitoSceneManager.last_slot_message
		return error
	if CogitoSceneManager.previous_menu == "pause_menu":
		CogitoSceneManager.pause_menu.close_pause_menu()
	CogitoSceneManager.previous_menu = ""
	CogitoSceneManager.previous_menu_button_pressed = ""
	return OK


func _on_delete_slot_pressed():
	if slot_status != CogitoSceneManager.SlotStatus.EMPTY:
		show_remove_confirmation_dialog()


func show_remove_confirmation_dialog():
	var dialog = ConfirmationDialog.new() 
	dialog.title = tr("REMOVE_CONFIRMATION_DIALOG_TITLE")
	dialog.dialog_text = tr("REMOVE_CONFIRMATION_DIALOG_TEXT")
	
	dialog.canceled.connect (dialog_remove_canceled)
	dialog.confirmed.connect (dialog_remove_confirmed)
	
	add_child(dialog)	
	dialog.popup_centered()
	dialog.show()


func dialog_remove_confirmed():
	if CogitoSceneManager.delete_save(manual_save_slot_name) != OK:
		save_time_label.text = "Cannot delete slot."
		return
	if CogitoSceneManager.delete_from_saved_slots(manual_save_slot_name) != OK:
		save_time_label.text = "Cannot update save list."
		return
	save_slot_manager_node.load_all_save_slots(false)


func dialog_remove_canceled():
	pass
