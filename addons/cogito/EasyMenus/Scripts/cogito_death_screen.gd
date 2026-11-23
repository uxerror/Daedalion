extends Control
class_name CogitoDeathScreen

signal back_to_main_pressed

#region Variables
@export var nodes_to_focus: Array[Control]
@export var sound_hover : AudioStream
@export var sound_click : AudioStream
@export var empty_slot_texture : Texture

var playback : AudioStreamPlaybackPolyphonic
var temp_screenshot : Image

@onready var label_active_slot: Label = %Label_ActiveSlot
@onready var load_button := %ReloadButton

#endregion


func _enter_tree() -> void:
	# Create an audio player
	var player = AudioStreamPlayer.new()
	player.bus = OptionsConstants.sfx_bus_name
	add_child(player)

	# Create a polyphonic stream so we can play sounds directly from it
	var stream = AudioStreamPolyphonic.new()
	stream.polyphony = 32
	player.stream = stream
	player.play()
	# Get the polyphonic playback stream to play sounds
	playback = player.get_stream_playback()

	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node:Node) -> void:
	if node is Button:
		# If the added node is a button we connect to its mouse_entered and pressed signals
		# and play a sound
		node.mouse_entered.connect(_play_hover)
		node.focus_entered.connect(_play_hover)
		node.pressed.connect(_play_pressed)


func _play_hover() -> void:
	playback.play_stream(sound_hover, 0, 0, 1)


func _play_pressed() -> void:
	playback.play_stream(sound_click, 0, 0, 1)


# Empty Input Event to take over inputs.
func on_input(event : InputEvent) -> void:
	pass


func open_death_screen():
	#Stops game and shows pause menu
	get_tree().paused = true
	
	InputRouter.push(on_input)
	
	if InputHelper.device_index == -1:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	if CogitoSceneManager.is_loaded_from_start_new_game:
		label_active_slot.text = ""
	else:
		label_active_slot.text = tr("TXT_CURRENT_SLOT") + ": " + CogitoSceneManager._active_slot
		
	temp_screenshot = CogitoSceneManager.grab_screenshot(CogitoGlobals.screenshot_scale)
	show()
	if CogitoSceneManager.is_loaded_from_start_new_game or !load_current_slot_data():
		#load_button.disabled = true
		hide_saved_slot_display()
		change_load_btn_to_new_game_btn()
	else:
		show_saved_slot_display()
		
	nodes_to_focus[0].grab_focus.call_deferred()


func hide_saved_slot_display():
	%Screenshot_Spot.texture = empty_slot_texture
	#%Screenshot_Spot.visible = false
	%Label_SaveTime2.visible = false
	%Label_SaveTime.visible = false

func show_saved_slot_display():
	#%Screenshot_Spot.visible = true
	%Label_SaveTime2.visible = true
	%Label_SaveTime.visible = true


func load_current_slot_data() -> bool:
	var state := CogitoSceneManager.get_existing_player_state(CogitoSceneManager._active_slot)
	%Screenshot_Spot.texture = CogitoSceneManager.slot_screenshot(state, empty_slot_texture)
	var savetime := state.player_state_savetime if state else 0
	if savetime == 0:
		%Label_SaveTime.text = ""
		return false
	else:
		var timeoffset = Time.get_time_zone_from_system().bias*60
		var save_time_string = Time.get_datetime_string_from_unix_time(savetime+timeoffset,true)
		%Label_SaveTime.text = save_time_string
		return true


func change_load_btn_to_new_game_btn() -> void:
	print("Death Screen: chaning load button to new game button.")
	if load_button.pressed.is_connected(_on_reload_button_pressed):
		load_button.pressed.disconnect(_on_reload_button_pressed)
	load_button.text = tr("TXT_NEW_GAME")
	if !load_button.pressed.is_connected(_on_new_game_button_pressed):
		load_button.pressed.connect(_on_new_game_button_pressed)


func _on_new_game_button_pressed() -> void:
	CogitoSceneManager.delete_temp_saves()
	InputRouter.pop()
	get_tree().paused = false
	start_new_game()


func start_new_game():
	if CogitoGlobals.cogito_settings.new_game_start_scene:
		CogitoSceneManager.is_starting_new_game = true
		var path_to_scene = CogitoGlobals.cogito_settings.new_game_start_scene.resource_path
		CogitoSceneManager.load_next_scene(path_to_scene, "", "temp", CogitoSceneManager.CogitoSceneLoadMode.RESET) #Load_mode 2 means there's no attempt to load a state.
		#Setting new game world state:
		CogitoSceneManager._current_world_dict = CogitoGlobals.cogito_settings.get_new_game_world_dict()
	else:
		print("ISSUE: No start game scene set.")


func _on_quit_button_pressed():
	CogitoSceneManager.delete_temp_saves()
	get_tree().quit()


func _on_back_to_main_menu_pressed() -> void:
	if CogitoGlobals.cogito_settings.main_menu_scene:
		var path_to_scene = CogitoGlobals.cogito_settings.main_menu_scene.resource_path
		
		# Cleanup
		get_tree().paused = false
		InputRouter.pop()
		
		CogitoSceneManager.load_next_scene(path_to_scene, "", "temp", CogitoSceneManager.CogitoSceneLoadMode.RESET) #Load_mode 2 means there's no attempt to load a state.
	else:
		CogitoGlobals.debug_log(true, "CogitoPauseMenu", "ISSUE: No main menu scene set.")


func _on_reload_button_pressed() -> void:
	if await CogitoSceneManager.loading_saved_game(CogitoSceneManager._active_slot) != OK:
		load_button.text = CogitoSceneManager.last_slot_message
		return
	get_tree().paused = false
	hide()
	InputRouter.pop()
	# Ensure the game resumes properly when loading after death
	var player = CogitoSceneManager.get_player()
	player.is_dead = false
	player.resume()
	# player.get_node(player.pause_menu).close_pause_menu()
	player.is_showing_ui = false
	player.animationPlayer.stop()
	CogitoSceneManager.restore_gameplay_mouse_mode()
