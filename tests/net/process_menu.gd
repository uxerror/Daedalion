extends Node
## Outlives the current scene, just like a person navigating successive games in one window.

var args: Dictionary
var _control: String
var _await_solo := false
var _open_pause: CogitoPauseMenu


func _ready() -> void:
	_control = String(args["--stop"]).get_base_dir()
	CogitoNet.menu.status_changed.connect(_status)
	CogitoNet.session_failed.connect(_failed)
	get_tree().scene_changed.connect(_scene_changed)
	get_tree().change_scene_to_packed(CogitoGlobals.cogito_settings.main_menu_scene)


func _failed(reason: String) -> void:
	print("NET FAILED ", JSON.stringify(reason))


func _scene_changed() -> void:
	var main := get_tree().current_scene as CogitoMainMenuController
	if main:
		print("NET MAIN ", main.get_node("%NetworkStatus").text)
		if args["--role"] == "export-client":
			_join(main)


func _status(message: String) -> void:
	if message == tr("Ready"):
		print("NET MENU PLAYING ", CogitoNet.local_player_id())


func _join(main: CogitoMainMenuController) -> void:
	main.open_multiplayer()
	var screen := main.sub_menu
	screen.get_node("%Tabs").current_tab = 1
	screen.get_node("%Address").text = "127.0.0.1"
	screen.get_node("%JoinPort").text = args["--port"]
	screen.get_node("%PlayerName").text = args["--name"]
	screen.join_server()


func _process(_delta: float) -> void:
	if FileAccess.file_exists(args["--stop"]):
		CogitoNet.disconnect_session()
		print("NET CLIENT STOP")
		get_tree().quit()
		set_process(false)
		return
	if (
		_await_solo
		and CogitoSceneManager.get_player()
		and not CogitoSceneManager.is_currently_loading
	):
		_await_solo = false
		print("NET SOLO READY")
	var path := _control.path_join("menu.request")
	if not FileAccess.file_exists(path):
		return
	var op := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	var main := get_tree().current_scene as CogitoMainMenuController
	match op:
		"host", "host-lab":
			var config := {
				"save_dir": args["--save-dir"],
				"port": int(args["--port"]),
				"level": "res://addons/cogito/DemoScenes/COGITO_3_Lobby.tscn",
			}
			if op == "host-lab":
				config.world = "quit-test"
				config.erase("level")
			CogitoNet.menu.host(config)
		"join":
			_join(main)
		"leave":
			_open_pause._on_back_to_main_menu_pressed()
		"pause":
			var actor := CogitoNet.local_player() as CogitoPlayerAdvanced
			_open_pause = actor.pause_menu.instantiate()
			actor.add_child(_open_pause)
			CogitoNet.roster.updated.connect(_roster, CONNECT_ONE_SHOT)
		"quit-tree":
			get_tree().quit()
		"solo":
			_await_solo = true
			main.start_new_game()
		"kick":
			var buttons := _open_pause.find_children("*", "CogitoUiButton", true, false)
			for button in buttons:
				if button.text == tr("Kick"):
					button.pressed.emit()
					break
			var dialogs := _open_pause.find_children("*", "ConfirmationDialog", true, false)
			for dialog: ConfirmationDialog in dialogs:
				if dialog.visible and dialog.dialog_text.contains("Ada"):
					dialog.confirmed.emit()
					dialog.hide()
					print("NET HOST KICK confirmed")
					break


func _roster(rows: Array[Dictionary]) -> void:
	var kicks := 0
	for button in _open_pause.find_children("*", "CogitoUiButton", true, false):
		kicks += int(button.text == tr("Kick"))
	print("NET KICK BUTTONS ", kicks)
	print("NET MENU ROSTER ", JSON.stringify(rows))
