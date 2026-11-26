extends GdUnitTestSuite

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


func test_lost_member_keeps_previous_generation(
	prefix: String, _test_parameters := [["player_"], ["scene_"]]
) -> void:
	var profile := {
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
