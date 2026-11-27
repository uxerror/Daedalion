extends PanelContainer
## A pause roster keeps the same buttons and focus across ping updates.

const Roster := preload("../../Networking/net_roster.gd")
const PlayerRow := preload("../Scenes/MultiplayerPlayerRow.tscn")
const VISIBLE_ROWS := 8

var local_id := ""
var can_kick := false
var _session_roster: Roster
var _target := ""
var _rows: Dictionary[String, HBoxContainer] = {}


func _ready() -> void:
	%Confirm.confirmed.connect(_kick)
	set_players([])


## Subscribe while the panel is in the session's pause menu.
func watch(source: Roster) -> void:
	_session_roster = source
	source.updated.connect(set_players)
	source.watch(true)
	set_players(source.rows)


func _exit_tree() -> void:
	if is_instance_valid(_session_roster):
		_session_roster.updated.disconnect(set_players)
		_session_roster.watch(false)


## Display a public snapshot. A negative ping denotes an unmeasured round trip.
func set_players(snapshot: Array[Dictionary]) -> void:
	%Count.text = tr("Players (%d)") % snapshot.size()
	var present := {}
	for player in snapshot:
		var id: String = player.player_id
		present[id] = true
		if not _rows.has(id):
			var row: HBoxContainer = PlayerRow.instantiate()
			if can_kick and id != local_id:
				row.get_node("%Kick").pressed.connect(_ask.bind(id))
			else:
				row.get_node("%Kick").free()
			row.get_node("%Moderation").visible = can_kick
			row.get_node("%Local").visible = id == local_id
			%Rows.add_child(row)
			_rows[id] = row
		var line := _rows[id]
		line.get_node("%PlayerName").text = player.display_name
		line.get_node("%PlayerName").tooltip_text = player.display_name
		var level := tr(player.level) if not player.level.is_empty() else tr("Loading…")
		line.get_node("%Level").text = level
		line.get_node("%Level").tooltip_text = level
		line.get_node("%Ping").text = tr("%d ms") % player.ping if player.ping >= 0 else "—"
	for id: String in _rows.keys():
		if not present.has(id):
			_rows[id].free()
			_rows.erase(id)
			if _target == id:
				%Confirm.hide()
	var count := mini(snapshot.size(), VISIBLE_ROWS)
	var height: float = %Rows.get_child(0).get_combined_minimum_size().y if count else 0.0
	var gap: int = %Rows.get_theme_constant("separation")
	%Scroll.custom_minimum_size.y = count * height + maxi(count - 1, 0) * gap


func _ask(id: String) -> void:
	_target = id
	%Confirm.dialog_text = tr("Kick %s from this world?") % _rows[id].get_node("%PlayerName").text
	%Confirm.popup_centered()
	%Confirm.get_cancel_button().grab_focus()


func _kick() -> void:
	if is_instance_valid(_session_roster):
		_session_roster.kick(_target)
