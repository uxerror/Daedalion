extends VBoxContainer
## Thin EasyMenus adapter. Games can supply their own controls to the same menu API.

signal closed

const MenuApi := preload("../../Networking/net_menu_api.gd")
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

## Override before entering the tree to use an isolated menu profile.
var api: MenuApi


func _ready() -> void:
	if not api:
		api = CogitoNet.menu
	api.status_changed.connect(_show_status)
	%PlayerName.text = api.player_name()
	for spin: SpinBox in [%HostPort, %Capacity]:
		var edit := spin.get_line_edit()
		edit.add_theme_font_size_override("font_size", 18)
		edit.add_theme_font_override("font", get_theme_font("font", "OptionButton"))
	%Tabs.set_tab_title(0, tr("Host"))
	%Tabs.set_tab_title(1, tr("Join"))
	%Tabs.tab_changed.connect(_focus_tab)
	for world in api.worlds():
		var title := tr("%s — %s") % [world.name, _format_save_time(world.saved)]
		var details := tr("Generation %d · %d players") % [world.generation, world.players]
		var index: int = %Worlds.add_item(title)
		%Worlds.set_item_tooltip(index, "%s\n%s" % [title, details])
		%Worlds.set_item_metadata(index, world.name)
	_size_list(%Worlds)
	%ContinueWorld.disabled = %Worlds.item_count == 0
	if not %ContinueWorld.disabled:
		%Worlds.select(0)
	for slot: String in api.solo_slots():
		%SoloSlot.add_item(slot)
	%Import.disabled = %SoloSlot.item_count == 0
	if %Import.disabled:
		%SoloSlot.add_item(tr("No solo saves"))
		%SoloSlot.select(0)
		%SoloSlot.set_item_disabled(0, true)
		%SoloSlot.disabled = true
		%SoloSlot.clip_text = false
		%SoloSlot.fit_to_longest_item = true
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


func _format_save_time(timestamp: int) -> String:
	var time_offset: int = Time.get_time_zone_from_system().bias * 60
	var date := Time.get_datetime_dict_from_unix_time(timestamp + time_offset)
	var month := tr(MONTHS[date.month - 1])
	return tr("%02d %s %02d:%02d") % [date.day, month, date.hour, date.minute]


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
		"port": int(%HostPort.value),
		"max_players": int(%Capacity.value),
		"friendly_fire": %FriendlyFire.button_pressed,
	}
	if action == "continue" and %Worlds.is_anything_selected():
		config.world = %Worlds.get_item_metadata(%Worlds.get_selected_items()[0])
	if action == "import" and not %Import.disabled and %SoloSlot.selected >= 0:
		config.import_slot = %SoloSlot.get_item_text(%SoloSlot.selected)
	api.host(config, "continue" if action == "continue" else "new")


func _refresh_recent() -> void:
	%Recent.clear()
	for item: Dictionary in api.recent_servers():
		%Recent.add_item("%s  ·  %d" % [item.address, item.port])
		%Recent.set_item_metadata(%Recent.item_count - 1, item)
	_size_list(%Recent)
	%Remove.disabled = true


func _size_list(list: ItemList) -> void:
	var font := list.get_theme_font("font")
	var row_height := font.get_height(list.get_theme_font_size("font_size"))
	row_height += list.get_theme_constant("v_separation")
	var padding := list.get_theme_stylebox("panel").get_minimum_size().y
	list.custom_minimum_size.y = maxf(40, padding + row_height * mini(list.item_count, 5))
	list.get_node("Empty").visible = list.item_count == 0
	list.focus_mode = Control.FOCUS_NONE if list.item_count == 0 else Control.FOCUS_ALL


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
	%Status.visible = not message.is_empty()
	if api.status_is_error:
		var color := Color.SALMON
		if %Status.has_theme_color("warning_color", "Label"):
			color = %Status.get_theme_color("warning_color", "Label")
		%Status.add_theme_color_override("font_color", color)
	else:
		%Status.remove_theme_color_override("font_color")
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
	if is_queued_for_deletion():
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu"):
		accept_event()
		close()
	elif %Tabs.visible and event is InputEventJoypadButton:
		if event.is_action_pressed("ui_next_tab") or event.is_action_pressed("ui_prev_tab"):
			%Tabs.current_tab = 1 - %Tabs.current_tab
			accept_event()
