extends "memory_session_suite.gd"

const MenuApi := preload("res://addons/cogito/Networking/net_menu_api.gd")
const Files := preload("res://addons/cogito/SceneManagement/cogito_world_files.gd")
const Screen := preload("res://addons/cogito/EasyMenus/Scenes/MultiplayerMenu.tscn")
const PlayerPanel := preload("res://addons/cogito/EasyMenus/Scenes/MultiplayerRoster.tscn")
const Main := preload("res://addons/cogito/EasyMenus/Scenes/main_menu.tscn")

var _previous: Node
var _root: Node
var _dir: String


func before_test() -> void:
	_previous = get_tree().current_scene
	_root = Node3D.new()
	get_tree().root.add_child(_root)
	get_tree().current_scene = _root
	_dir = create_temp_dir("menu-%d" % Time.get_ticks_usec())


func after_test() -> void:
	var scene := get_tree().current_scene
	get_tree().current_scene = _previous
	if scene and scene != _previous:
		scene.queue_free()
	if is_instance_valid(_root) and _root != scene:
		_root.queue_free()
	super.after_test()
	await get_tree().process_frame


func test_open_navigate_back_and_restore_keyboard_focus() -> void:
	var main: CogitoMainMenuController = Main.instantiate()
	_root.add_child(main)
	main.open_multiplayer()
	await get_tree().process_frame
	var screen := main.sub_menu
	assert_bool(main.game_menu.is_visible_in_tree()).is_true()
	assert_bool(screen.get_node("%Worlds/Empty").visible).is_true()
	assert_bool(screen.get_node("%Recent/Empty").visible).is_true()
	var background: Button = main.get_node("%Multiplayer")
	assert_int(background.get_focus_mode_with_override()).is_equal(Control.FOCUS_NONE)
	assert_object(get_viewport().gui_get_focus_owner()).is_same(screen.get_node("%WorldName"))
	var next := InputEventAction.new()
	next.action = "ui_focus_next"
	next.pressed = true
	get_viewport().push_input(next)
	var port: SpinBox = screen.get_node("%HostPort")
	assert_object(get_viewport().gui_get_focus_owner()).is_same(port.get_line_edit())
	var tabs: TabContainer = screen.get_node("%Tabs")
	tabs.get_tab_bar().grab_focus()
	next.action = "ui_right"
	get_viewport().push_input(next)
	await get_tree().process_frame
	assert_int(tabs.current_tab).is_equal(1)
	assert_object(get_viewport().gui_get_focus_owner()).is_same(screen.get_node("%PlayerName"))
	next.action = "ui_cancel"
	get_viewport().push_input(next)
	await get_tree().create_timer(0.3).timeout
	assert_bool(main.game_menu.visible).is_true()
	assert_object(get_viewport().gui_get_focus_owner()).is_same(main.get_node("%Multiplayer"))


func test_join_screen_validates_cancel_retries_and_remembers_endpoints() -> void:
	var authority := _branch(1)
	assert_int(authority.start_server({"save_dir": _dir})).is_equal(OK)
	var client := _branch(2)
	var api := client.menu
	api.preferences_path = _dir.path_join("prefs.cfg")
	var screen := Screen.instantiate()
	screen.api = api
	_root.add_child(screen)
	screen.get_node("%Tabs").current_tab = 1
	screen.get_node("%Address").text = "https://bad/host"
	screen.join_server()
	assert_bool(client.is_online()).is_false()
	assert_str(screen.get_node("%Status").text).contains("address")
	screen.get_node("%Address").text = "Example.COM"
	screen.get_node("%JoinPort").text = "7.5"
	screen.join_server()
	assert_bool(client.is_online()).is_false()
	screen.get_node("%PlayerName").text = "Ada"
	for port in range(1100, 1112):
		screen.get_node("%JoinPort").text = str(port)
		screen.join_server()
		assert_str(api.status).is_equal("Connecting…")
		screen.close()
		_pump()
		assert_bool(client.is_online()).is_false()
		assert_int(client.get_child_count()).is_zero()
	screen.get_node("%JoinPort").text = "1105"
	var statuses: Array[String] = []
	api.status_changed.connect(func(message: String): statuses.append(message))
	screen.join_server()
	_pump()
	assert_array(statuses).contains_exactly(["Connecting…", "Authenticating…", "Loading…"])
	assert_str(authority.player_for_peer(2).display_name).is_equal("Ada")
	var restored := MenuApi.new(client)
	restored.preferences_path = api.preferences_path
	assert_str(restored.player_name()).is_equal("Ada")
	var recents := restored.recent_servers()
	assert_int(recents.size()).is_equal(10)
	assert_dict(recents[0]).is_equal({"address": "example.com", "port": 1105})
	assert_int(recents[1].port).is_equal(1111)
	assert_int(restored.forget_server("example.com", 1105)).is_equal(OK)
	assert_int(restored.recent_servers().size()).is_equal(9)
	var file := ConfigFile.new()
	assert_int(file.load(api.preferences_path)).is_equal(OK)
	assert_array(Array(file.get_sections())).contains_exactly_in_any_order(["player", "recent"])
	api.cancel()


func test_host_screen_validates_and_reports_lock_and_import_errors() -> void:
	var host := _branch(1)
	host.menu.save_dir = _dir
	var screen := Screen.instantiate()
	screen.api = host.menu
	_root.add_child(screen)
	screen.get_node("%WorldName").text = "../bad"
	screen.host_world("new")
	assert_bool(host.is_online()).is_false()
	var files := Files.new()
	assert_int(files.open(_dir, "held")).is_equal(OK)
	screen.get_node("%WorldName").text = "held"
	screen.host_world("new")
	assert_str(screen.get_node("%Status").text).is_equal("World is locked")
	files.close()
	assert_int(host.menu.host({"world": "held", "import_slot": "absent"}, "new")).is_not_equal(OK)
	assert_bool(host.is_online()).is_false()
	assert_str(host.menu.status).contains("import")
	var config := {"world": "held", "level": "res://tests/player/movement_level.tscn"}
	assert_int(host.menu.host(config, "new")).is_equal(OK)
	assert_int(host.save_world()).is_equal(OK)
	assert_int(host.disconnect_session()).is_equal(OK)
	var worlds := host.menu.worlds()
	assert_int(worlds.size()).is_equal(1)
	assert_str(worlds[0].name).is_equal("held")
	assert_int(worlds[0].saved).is_greater(0)
	assert_int(worlds[0].generation).is_greater(0)
	assert_int(worlds[0].players).is_equal(1)
	assert_int(host.menu.host(config, "new")).is_equal(ERR_ALREADY_EXISTS)
	var reopened := Screen.instantiate()
	reopened.api = host.menu
	_root.add_child(reopened)
	var saved: ItemList = reopened.get_node("%Worlds")
	assert_bool(saved.get_node("Empty").visible).is_false()
	assert_str(saved.get_item_metadata(saved.get_selected_items()[0])).is_equal("held")
	reopened.host_world("continue")
	assert_bool(host.is_online()).is_true()
	assert_int(host.disconnect_session()).is_equal(OK)
	await get_tree().process_frame


func test_roster_subscription_rate_authority_kick_and_dedicated_request(_timeout := 10000) -> void:
	var server := _branch(1)
	assert_int(server.start_server({"save_dir": _dir})).is_equal(OK)
	_level(server)
	var client := _branch(2)
	client.menu.preferences_path = _dir.path_join("prefs.cfg")
	var writer := server.player_world.persistence
	for target in ["unknown", "Ada", "id"]:
		if not client.is_online():
			assert_int(client.menu.join("demo", 1555, "Ada")).is_equal(OK)
			_level(client)
			_pump()
		var id := client.local_player_id()
		assert_str(id).is_not_empty()
		assert_int(client.roster.kick(id)).is_equal(ERR_UNAUTHORIZED)
		client.roster.watch(true)
		_pump()
		var deadline := Time.get_ticks_msec() + 1800
		while client.roster.rows.is_empty() and Time.get_ticks_msec() < deadline:
			await _ticks(1)
		var rows := client.roster.rows
		assert_int(rows.size()).is_equal(1)
		assert_str(rows[0].display_name).is_equal("Ada")
		assert_str(rows[0].level).is_equal("Movement Level")
		assert_int(rows[0].ping).is_equal(-1)
		var received: Array[int] = []
		client.roster.updated.connect(func(_rows: Array[Dictionary]): received.append(1))
		for i in 5:
			server.roster._process(0.0)
			_pump()
		assert_array(received).is_empty()
		if target == "unknown":
			deadline = Time.get_ticks_msec() + 1800
			while received.is_empty() and Time.get_ticks_msec() < deadline:
				await _ticks(1)
			assert_int(received.size()).is_equal(1)
		client.roster.watch(false)
		_pump()
		var file := FileAccess.open(
			writer.files.directory.path_join("kick.request"), FileAccess.WRITE
		)
		file.store_string(id if target == "id" else target)
		file.close()
		assert_bool(writer._kick_request(server.player_world)).is_true()
		_pump()
		assert_bool(client.is_online()).is_equal(target == "unknown")
		if target != "unknown":
			await get_tree().scene_changed
			assert_object(get_tree().current_scene).is_instanceof(CogitoMainMenuController)
			assert_str(client.menu.return_message).is_equal("Kicked by host")


func test_failure_messages_cover_protocol_and_transport_reasons() -> void:
	var client := _branch(2)
	for reason: String in ["Protocol version mismatch", "Content version mismatch"]:
		assert_str(client.menu.readable(reason)).contains("same game build")
	assert_str(client.menu.readable("Handshake timed out")).contains("firewall")
	assert_str(client.menu.readable("Connection failed")).contains("port")
	assert_str(client.menu.readable("Name rejected")).contains("player name")
	assert_str(client.menu.readable("Server full")).contains("player leaves")
	assert_str(client.menu.readable("Cannot bind *:77")).contains("another port")
	assert_str(client.menu.readable("Kicked by host")).is_equal("Kicked by host")


func test_roster_keeps_kick_visible_and_focused_across_snapshots() -> void:
	var panel := PlayerPanel.instantiate()
	panel.local_id = "0"
	panel.can_kick = true
	_root.add_child(panel)
	var players: Array[Dictionary] = []
	for i in 8:
		var player := {"player_id": str(i), "display_name": "Ada".repeat(20), "ping": -1}
		player.level = "Laboratory"
		players.append(player)
	panel.set_players(players)
	await get_tree().process_frame
	await get_tree().process_frame
	var scroll: ScrollContainer = panel.get_node("%Scroll")
	var rows: VBoxContainer = panel.get_node("%Rows")
	assert_bool(scroll.get_v_scroll_bar().visible).is_false()
	assert_bool(scroll.get_h_scroll_bar().visible).is_false()
	assert_object(rows.get_child(0).get_node_or_null("%Kick")).is_null()
	assert_bool(rows.get_child(0).get_node("%Local").visible).is_true()
	var kick: Button = rows.get_child(1).get_node("%Kick")
	assert_bool(scroll.get_global_rect().encloses(kick.get_global_rect())).is_true()
	kick.grab_focus()
	assert_str(rows.get_child(1).get_node("%Ping").text).is_equal("—")
	players[1].ping = 28
	players.append({"player_id": "8", "display_name": "Ben", "level": "Lobby", "ping": -1})
	panel.set_players(players)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_object(get_viewport().gui_get_focus_owner()).is_same(kick)
	assert_str(rows.get_child(1).get_node("%Ping").text).is_equal("28 ms")
	assert_str(panel.get_node("%Count").text).is_equal("Players (9)")
	assert_bool(scroll.get_v_scroll_bar().visible).is_true()
	assert_bool(scroll.get_h_scroll_bar().visible).is_false()
