extends SceneTree
## Capture six EasyMenus reference views in a window. Pass -- --out DIR after the script.

const LAB := "res://addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn"
const MAIN := "res://addons/cogito/EasyMenus/Scenes/main_menu.tscn"

var _profile := DirAccess.create_temp("daedalion-ui")
var _output := ""


func _initialize() -> void:
	node_added.connect(_isolate_saves)
	# root.size is not final during _initialize (often 100x100). Use the project canvas
	# unless --size WxH is given.
	var canvas := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width", 1920),
		ProjectSettings.get_setting("display/window/size/viewport_height", 1080)
	)
	var requested := canvas
	var args := OS.get_cmdline_user_args()
	var at := args.find("--size")
	if at >= 0 and at + 1 < args.size() and args[at + 1].contains("x"):
		requested = Vector2i(
			args[at + 1].get_slice("x", 0).to_int(), args[at + 1].get_slice("x", 1).to_int()
		)
	_run.call_deferred(requested, canvas)


func _isolate_saves(node: Node) -> void:
	# Set the solo index before the autoload's _ready recovers or cleans any slots.
	if node.name == &"CogitoSceneManager" and _profile:
		node.cogito_state_dir = _profile.get_current_dir().path_join("saves") + "/"
		node.saves_data_file_path = node.cogito_state_dir.path_join("saves.data")
		node_added.disconnect(_isolate_saves)


func _run(requested_size: Vector2i, canvas_size: Vector2i) -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	if index < 0 or index + 1 >= args.size() or args[index + 1].is_empty():
		printerr("Usage: godot -s res://tools/ui_screenshots.gd -- --out DIR")
		quit(2)
		return
	_output = args[index + 1]
	var err := DirAccess.make_dir_recursive_absolute(_output)
	if err == OK:
		err = _seed_menu()
	if err == OK:
		# Startup may apply a saved window mode after a delay. Honor the capture resolution.
		await create_timer(0.35).timeout
		root.mode = Window.MODE_WINDOWED
		root.size = requested_size
		root.content_scale_size = canvas_size
		root.content_scale_factor = 1.0
		err = await _main_views()
	if err == OK:
		err = await _pause_views()
	if current_scene:
		unload_current_scene()
		# Allow the audio mixer to release the Laboratory streams after their players exit.
		await create_timer(0.3).timeout
	if err != OK:
		printerr("UI screenshots: ", error_string(err))
	quit(0 if err == OK else 1)


func _seed_menu() -> Error:
	if not _profile:
		return ERR_CANT_CREATE
	var api: RefCounted = root.get_node("CogitoNet").menu
	api.save_dir = _profile.get_current_dir()
	api.preferences_path = api.save_dir.path_join("recent.cfg")
	var prefs := ConfigFile.new()
	prefs.set_value("player", "name", "Ada")
	var recent := [{"address": "lab.example", "port": 7777}, {"address": "lobby.lan", "port": 7778}]
	prefs.set_value("recent", "servers", recent)
	var err := prefs.save(api.preferences_path)
	for world: String in ["Laboratory", "Expedition"]:
		if err == OK:
			err = _seed_world(api.save_dir, world)
	return err


func _seed_world(directory: String, world: String) -> Error:
	var files: RefCounted = load("res://addons/cogito/SceneManagement/cogito_world_files.gd").new()
	var err: Error = files.open(directory, world)
	if err == OK:
		var state: Resource = (
			load("res://addons/cogito/SceneManagement/cogito_scene_state.gd").new()
		)
		var scene := {
			"id": LAB,
			"path": LAB,
			"scene": state,
			"bodies": {},
			"objects": {},
			"containers": {},
		}
		var ledger := {"revision": 0, "quests": {}, "flags": {}, "triggers": {}}
		var manifest := {"tick": 0, "active": LAB, "quests": ledger, "shared": {}}
		err = files.commit(manifest, {LAB: scene}, {})
		files.close()
	return err


func _main_views() -> Error:
	var main: Control = load(MAIN).instantiate()
	main.get_node("ContentMain/OptionsTabMenu").apply_display_on_load = false
	root.add_child(main)
	current_scene = main
	var err := await _capture("01_main_menu.png")
	if err == OK:
		main.open_multiplayer()
		err = await _capture("02_mp_host.png")
	if err == OK:
		main.sub_menu.get_node("%Tabs").current_tab = 1
		err = await _capture("03_mp_join.png")
	if err == OK:
		main.sub_menu.close()
		main.open_options_menu()
		err = await _capture("04_options.png")
	return err


func _pause_views() -> Error:
	var err := change_scene_to_file(LAB)
	if err != OK:
		return err
	await scene_changed
	# Let the authored camera and HUD finish a frame before sampling the pause backdrop.
	await process_frame
	var actor: Node = root.get_node("CogitoSceneManager").get_player()
	if not actor:
		return ERR_DOES_NOT_EXIST
	var menu: Control = actor.pause_menu.instantiate()
	actor.add_child(menu)
	err = await _capture("06_pause_offline.png")
	if err == OK:
		var panel: Control = menu.show_players("host", true)
		var players: Array[Dictionary] = [
			{"player_id": "host", "display_name": "Ada", "level": "Laboratory", "ping": 0},
			{"player_id": "ben", "display_name": "Ben", "level": "Lobby", "ping": 28},
			{"player_id": "lea", "display_name": "Lea", "level": "Laboratory", "ping": -1},
		]
		panel.set_players(players)
		menu.resume_game_button.grab_focus()
		err = await _capture("05_pause_roster.png")
	menu.close_pause_menu()
	await process_frame
	return err


func _capture(filename: String) -> Error:
	if DisplayServer.get_name() == "headless":
		printerr("PNG capture requires a window.")
		return ERR_UNAVAILABLE
	# Includes the button focus tween and container layout, even while the tree is paused.
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	if not frame or frame.is_empty():
		return ERR_CANT_ACQUIRE_RESOURCE
	var path := _output.path_join(filename)
	var err := frame.save_png(path)
	if err == OK:
		print(path)
	return err
