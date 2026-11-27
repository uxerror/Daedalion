extends ScrollContainer
## Keep buttons alive across ping updates so keyboard and controller focus stays put.

const Roster := preload("../../Networking/net_roster.gd")

var _session_roster: Roster
var _list := VBoxContainer.new()
var _confirm := ConfirmationDialog.new()
var _target := ""
var _rows := {}


func _ready() -> void:
	custom_minimum_size.y = 160
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_list)
	add_child(_confirm)
	_confirm.confirmed.connect(_kick)
	_session_roster = CogitoNet.roster
	_session_roster.updated.connect(_refresh)
	_session_roster.watch(true)
	_refresh(_session_roster.rows)


func _exit_tree() -> void:
	if is_instance_valid(_session_roster) and _session_roster == CogitoNet.roster:
		_session_roster.watch(false)


func _refresh(snapshot: Array[Dictionary]) -> void:
	var present := {}
	for row in snapshot:
		var id: String = row.player_id
		present[id] = true
		var line: HBoxContainer = _rows.get(id)
		if not line:
			line = HBoxContainer.new()
			_list.add_child(line)
			_rows[id] = line
			var label := Label.new()
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line.add_child(label)
			if CogitoNet.mode() == CogitoNet.Mode.LISTEN_HOST and id != CogitoNet.local_player_id():
				var button := CogitoUiButton.new()
				button.text = tr("Kick")
				button.pressed.connect(_ask.bind(id, row.display_name))
				line.add_child(button)
		var local := tr(" (you)") if id == CogitoNet.local_player_id() else ""
		var ping := tr("%d ms") % row.ping if row.ping >= 0 else "—"
		var level := tr(row.level) if not row.level.is_empty() else tr("Loading…")
		line.get_child(0).text = "%s%s  ·  %s  ·  %s" % [row.display_name, local, level, ping]
	for id: String in _rows.keys():
		if not present.has(id):
			_rows[id].queue_free()
			_rows.erase(id)
			if _target == id:
				_confirm.hide()


func _ask(id: String, label: String) -> void:
	_target = id
	_confirm.dialog_text = tr("Kick %s from this world?") % label
	_confirm.popup_centered()
	_confirm.get_cancel_button().grab_focus()


func _kick() -> void:
	if CogitoNet.roster:
		CogitoNet.roster.kick(_target)
