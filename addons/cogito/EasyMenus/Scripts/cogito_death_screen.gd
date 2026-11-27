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
var _actor: CogitoPlayerAdvanced
var _request: Callable
var _countdown: Timer
var _unlock_msec := 0

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
	if _actor and (event.is_action_pressed("menu") or event.is_action_pressed("ui_cancel")):
		_actor._handle_command_edge(CogitoPlayerCommand.Action.MENU, 0)


## Open for one network owner. The countdown is a display estimate of the server deadline.
func open_online(actor: CogitoPlayerAdvanced, seconds: float, request: Callable) -> void:
	_actor = actor
	_request = request
	_pauses_world = false
	label_active_slot.hide()
	%Screenshot_Spot.get_parent().get_parent().get_parent().hide()
	show()
	InputRouter.push(on_input)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_unlock_msec = Time.get_ticks_msec() + ceili(seconds * 1000.0)
	if seconds > 0:
		_countdown = Timer.new()
		_countdown.wait_time = 0.05
		_countdown.ignore_time_scale = true
		add_child(_countdown)
		_countdown.timeout.connect(_display_remaining)
		_countdown.start()
	_display_remaining()


func _display_remaining() -> void:
	var seconds := maxf(0, (_unlock_msec - Time.get_ticks_msec()) / 1000.0)
	if seconds == 0 and _countdown:
		_countdown.stop()
	load_button.disabled = seconds > 0.0
	load_button.text = tr("Respawn (%d)") % ceili(seconds) if seconds > 0 else tr("Respawn")
	if not load_button.disabled and InputRouter.is_input_active(self):
		load_button.grab_focus()


## Called only after a server-approved respawn or local avatar removal.
func close_online() -> void:
	if _countdown:
		_countdown.stop()
		_countdown.queue_free()
		_countdown = null
	InputRouter.remove(on_input)
	hide()
	if _actor and InputRouter.is_input_active(_actor):
		Input.mouse_mode = _actor.gameplay_mouse_mode
	_actor = null
	_request = Callable()


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
	# Leave after the button's input event, as the session frees this screen.
	_quit.call_deferred()


func _quit() -> void:
	var tree := get_tree()
	CogitoNet.disconnect_session()
	tree.quit()


func _on_back_to_main_menu_pressed() -> void:
	var menu := CogitoGlobals.cogito_settings.main_menu_scene
	if menu and _actor:
		var tree := get_tree()
		CogitoNet.disconnect_session.call_deferred()
		tree.change_scene_to_packed.call_deferred(menu)
	elif menu:
		if await CogitoSceneManager.load_next_scene(
			menu.resource_path, "", "temp", CogitoSceneManager.CogitoSceneLoadMode.RESET
		) != OK:
			load_button.text = CogitoSceneManager.last_slot_message


func _on_reload_button_pressed() -> void:
	if _request.is_valid():
		_request.call()
		return
	if await CogitoSceneManager.restart_after_death() != OK:
		load_button.text = CogitoSceneManager.last_slot_message
