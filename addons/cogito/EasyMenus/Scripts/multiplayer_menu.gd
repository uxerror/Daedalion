extends PanelContainer
## Thin EasyMenus adapter. Games can supply their own controls to the same menu API.

signal closed

const MenuApi := preload("../../Networking/net_menu_api.gd")

var api: MenuApi


func _ready() -> void:
	if not api:
		api = CogitoNet.menu
	api.status_changed.connect(_show_status)
	%PlayerName.text = api.player_name()
	%Tabs.set_tab_title(0, tr("Host"))
	%Tabs.set_tab_title(1, tr("Join"))
	%Tabs.tab_changed.connect(_focus_tab)
	for world in api.worlds():
		var saved := Time.get_datetime_string_from_unix_time(world.saved, true)
		var pattern := tr("%s · %s UTC · generation %d · %d players")
		var title := pattern % [world.name, saved, world.generation, world.players]
		%Worlds.add_item(title)
		%Worlds.set_item_metadata(%Worlds.item_count - 1, world.name)
	%ContinueWorld.disabled = %Worlds.item_count == 0
	for slot: String in api.solo_slots():
		%SoloSlot.add_item(slot)
	%Import.disabled = %SoloSlot.item_count == 0
	%ContinueWorld.pressed.connect(host_world.bind("continue"))
	%NewWorld.pressed.connect(host_world.bind("new"))
	%Import.pressed.connect(host_world.bind("import"))
	%JoinServer.pressed.connect(join_server)
	%Recent.item_selected.connect(_fill)
	%Recent.item_activated.connect(_join_recent)
	%Remove.pressed.connect(_remove)
	%Back.pressed.connect(close)
	%Cancel.pressed.connect(close)
	_refresh_recent()
	_show_status("")
	_focus_tab(0)


func _focus_tab(index: int) -> void:
	var field: Control = %WorldName if index == 0 else %PlayerName
	field.grab_focus.call_deferred()


## Submit the visible endpoint fields. Errors stay on this screen.
func join_server() -> void:
	api.join(%Address.text, _port(%JoinPort.text), %PlayerName.text)
	_refresh_recent()


func _port(value: String) -> int:
	return value.to_int() if value.is_valid_int() else 0


## Submit the selected world, or create a named world optionally seeded by a solo slot.
func host_world(action: String) -> void:
	var config := {
		"world": %WorldName.text.strip_edges(),
		"port": _port(%HostPort.text),
		"max_players": _port(%Capacity.text),
		"friendly_fire": %FriendlyFire.button_pressed,
	}
	if action == "continue" and %Worlds.selected >= 0:
		config.world = %Worlds.get_selected_metadata()
	if action == "import" and %SoloSlot.selected >= 0:
		config.import_slot = %SoloSlot.get_item_text(%SoloSlot.selected)
	api.host(config, "continue" if action == "continue" else "new")


func _refresh_recent() -> void:
	%Recent.clear()
	for item: Dictionary in api.recent_servers():
		%Recent.add_item("%s  ·  %d" % [item.address, item.port])
		%Recent.set_item_metadata(%Recent.item_count - 1, item)
	%Remove.disabled = true


func _fill(index: int) -> void:
	var item: Dictionary = %Recent.get_item_metadata(index)
	%Address.text = item.address
	%JoinPort.text = str(item.port)
	%Remove.disabled = false


func _join_recent(index: int) -> void:
	_fill(index)
	join_server()


func _remove() -> void:
	var selected: PackedInt32Array = %Recent.get_selected_items()
	if not selected.is_empty():
		var item: Dictionary = %Recent.get_item_metadata(selected[0])
		api.forget_server(item.address, item.port)
		_refresh_recent()


func _show_status(message: String) -> void:
	%Status.text = message
	%Cancel.visible = api.pending
	%Back.visible = not api.pending
	%Tabs.visible = not api.pending
	if api.pending:
		%Cancel.grab_focus()
	elif %Cancel.has_focus() or get_viewport().gui_get_focus_owner() == null:
		_focus_tab(%Tabs.current_tab)


## Back and Cancel both restore focus to the button which opened the screen.
func close() -> void:
	api.cancel()
	closed.emit()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu"):
		accept_event()
		close()
