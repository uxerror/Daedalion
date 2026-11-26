extends GdUnitTestSuite

const ProfileTools := preload("res://addons/cogito/Networking/net_profile_tools.gd")
const Files := preload("res://addons/cogito/SceneManagement/cogito_world_files.gd")

var _files: Files
var _dir: String


func before_test() -> void:
	_dir = create_temp_dir("mp9-%d" % Time.get_ticks_usec())
	_files = Files.new()
	assert_int(_files.open(_dir, "test")).is_equal(OK)


func after_test() -> void:
	_files.close()


func _save(players: Dictionary) -> Error:
	var ledger := {"revision": 0, "quests": {}, "flags": {}, "triggers": {}}
	var data := {"tick": 12, "active": "lab", "quests": ledger, "shared": {}}
	var scene := {
		"id": "lab",
		"path": "",
		"scene": CogitoSceneState.new(),
		"bodies": {},
		"objects": {},
		"containers": {}
	}
	return _files.commit(data, {"lab": scene}, players)


func test_zero_players_and_exclusive_writer() -> void:
	var other := Files.new()
	assert_int(other.open(_dir, "test")).is_equal(ERR_BUSY)
	assert_int(_save({})).is_equal(OK)
	_files.close()
	assert_int(other.open(_dir, "test")).is_equal(OK)
	assert_dict(other.profiles).is_empty()
	other.close()


func test_recovery_prefers_complete_backup_to_damaged_live() -> void:
	assert_int(_save({})).is_equal(OK)
	var dir := _files.directory
	var live := dir.path_join("current")
	var backup := dir.path_join(".previous-current")
	_files.close()
	assert_int(DirAccess.rename_absolute(live, backup)).is_equal(OK)
	assert_int(DirAccess.make_dir_absolute(live)).is_equal(OK)
	var manifest := "world.v2.json"
	(
		assert_int(DirAccess.copy_absolute(backup.path_join(manifest), live.path_join(manifest)))
		. is_equal(OK)
	)
	var recovered := Files.new()
	assert_int(recovered.open(_dir, "test")).is_equal(OK)
	assert_int(recovered.manifest.generation).is_equal(1)
	assert_bool(recovered.scenes.has("lab")).is_true()
	recovered.close()


func _layout_one_profile() -> Dictionary:
	return {
		"id": "a/b",
		"level": "lab",
		"pose": Transform3D.IDENTITY,
		"dead": false,
		"elements": {},
		"attributes": {},
		"stock":
		{
			"rows": {},
			"binds": PackedInt64Array(),
			"size": Vector2i.ONE,
			"length": 1,
			"grid": false,
			"money": {},
			"equipped": 0
		}
	}


func test_lost_member_keeps_previous_generation(
	prefix: String, _test_parameters := [["player_"], ["scene_"]]
) -> void:
	var profile := _layout_one_profile()
	assert_int(_save({"a/b": profile})).is_equal(OK)
	var staging := _files.directory.path_join(".writing-current")
	_files.storage.fail_before = func(op: String) -> bool:
		if op == "verify world":
			for filename in DirAccess.get_files_at(staging):
				if filename.begins_with(prefix):
					DirAccess.remove_absolute(staging.path_join(filename))
		return false
	assert_int(_save({})).is_equal(ERR_FILE_CORRUPT)
	_files.close()
	var restarted := Files.new()
	assert_int(restarted.open(_dir, "test")).is_equal(OK)
	assert_int(restarted.manifest.generation).is_equal(1)
	assert_bool(restarted.profiles.has("a/b")).is_true()
	restarted.close()


func test_abandoned_staging_never_replaces_complete_world() -> void:
	assert_int(_save({})).is_equal(OK)
	var staging := _files.directory.path_join(".writing-current")
	assert_int(DirAccess.make_dir_absolute(staging)).is_equal(OK)
	var partial := FileAccess.open(staging.path_join("world.v2.json"), FileAccess.WRITE)
	partial.store_string("{")
	partial.close()
	_files.close()
	assert_int(_files.open(_dir, "test")).is_equal(OK)
	assert_int(_files.manifest.generation).is_equal(1)
	assert_bool(DirAccess.dir_exists_absolute(staging)).is_false()


func test_stopped_tools_move_layout_one_profile_with_exclusive_claim() -> void:
	var tools := ProfileTools.new()
	var empty := _layout_one_profile()
	empty.id = "newly-issued"
	empty.unplayed = true
	var used := _layout_one_profile()
	used.id = "returnee"
	used.stock.money = {"credits": PackedFloat64Array([50, 100])}
	assert_int(_save({"a/b": _layout_one_profile(), empty.id: empty, used.id: used})).is_equal(OK)
	var config := {"world": "test", "save_dir": _dir, "profile_command": "list"}
	assert_int(tools.stopped(config)).is_equal(ERR_BUSY)
	_files.close()
	assert_int(tools.stopped(config)).is_equal(OK)
	config.profile_command = "rebind a/b returnee"
	assert_int(tools.stopped(config)).is_equal(ERR_ALREADY_EXISTS)
	config.profile_command = "rebind a/b newly-issued"
	assert_int(tools.stopped(config)).is_equal(OK)
	assert_int(_files.open(_dir, "test")).is_equal(OK)
	assert_int(_files.manifest.generation).is_equal(2)
	assert_int(_files.manifest.layout).is_equal(1)
	assert_bool(_files.profiles.has("a/b")).is_false()
	assert_str(_files.profiles["newly-issued"].id).is_equal("newly-issued")
	_files.close()
	config.profile_command = "rebind newly-issued returnee force"
	assert_int(tools.stopped(config)).is_equal(OK)
	assert_int(_files.open(_dir, "test")).is_equal(OK)
	assert_int(_files.manifest.generation).is_equal(3)
	assert_array(_files.profiles.keys()).contains_exactly(["returnee"])
	assert_dict(_files.profiles.returnee.stock.money).is_empty()
	var members := DirAccess.get_files_at(_files.directory.path_join("current"))
	assert_int(members.size()).is_equal(3)
