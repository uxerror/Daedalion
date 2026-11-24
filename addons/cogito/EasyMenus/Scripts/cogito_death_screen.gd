extends Control
class_name CogitoDeathScreen

signal back_to_main_pressed

#region Variables
@export var nodes_to_focus: Array[Control]
@export var sound_hover : AudioStream
@export var sound_click : AudioStream
@export var empty_slot_texture : Texture

var playback : AudioStreamPlaybackPolyphonic
var _pauses_world: bool

@onready var label_active_slot: Label = %Label_ActiveSlot
@onready var load_button: Button = %ReloadButton

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


func open_death_screen() -> void:
	_pauses_world = not CogitoNet.is_online()
	if _pauses_world:
		get_tree().paused = true
	InputRouter.push(on_input)
	if InputHelper.device_index == -1:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var slot := CogitoSceneManager.find_latest_loadable_slot()
	var state := slot.player if slot else null
	%Screenshot_Spot.texture = CogitoSceneManager.slot_screenshot(state, empty_slot_texture)
	label_active_slot.visible = slot != null
	%Label_SaveTime2.visible = slot != null
	%Label_SaveTime.visible = slot != null
	if slot:
		label_active_slot.text = tr("TXT_SLOT") + " " + slot.slot
		var offset: int = Time.get_time_zone_from_system().bias * 60
		%Label_SaveTime.text = Time.get_datetime_string_from_unix_time(slot.save_time + offset, true)
	load_button.text = "BTN_Reload"
	show()
	nodes_to_focus[0].grab_focus.call_deferred()


func _exit_tree() -> void:
	if InputRouter.input_stack.has(on_input):
		InputRouter.remove(on_input)
		if _pauses_world:
			get_tree().paused = false


func _on_quit_button_pressed() -> void:
	get_tree().quit()


func _on_back_to_main_menu_pressed() -> void:
	var menu := CogitoGlobals.cogito_settings.main_menu_scene
	if menu:
		if await CogitoSceneManager.load_next_scene(
			menu.resource_path, "", "temp", CogitoSceneManager.CogitoSceneLoadMode.RESET
		) != OK:
			load_button.text = CogitoSceneManager.last_slot_message


func _on_reload_button_pressed() -> void:
	if await CogitoSceneManager.restart_after_death() != OK:
		load_button.text = CogitoSceneManager.last_slot_message
