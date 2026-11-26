extends "slot_fixture.gd"

const Files := preload("res://addons/cogito/SceneManagement/cogito_world_files.gd")
const Import := preload("res://addons/cogito/Networking/net_solo_import.gd")
const Config := preload("res://addons/cogito/Networking/net_config.gd")


func after_test() -> void:
	var directory := manager.cogito_state_dir.trim_suffix("/")
	for slot in DirAccess.get_directories_at(directory):
		manager.storage.remove_directory(directory.path_join(slot))
	manager.storage.remove_directory(directory)
	super.after_test()


func test_import_preserves_each_source_byte(
	legacy: bool, _test_parameters := [[false], [true]]
) -> void:
	var player := make_slot("source")
	var scene_file := manager.legacy_scene_file("source", player.player_current_scene)
	var level := CogitoSceneState.new()
	level.saved_destroyed_nodes = [{"cogito_id": "Removed", "path": "."}]
	assert_int(ResourceSaver.save(level, scene_file)).is_equal(OK)
	if not legacy:
		assert_int(player.write_state("source")).is_equal(OK)
	var directory := manager.cogito_state_dir.path_join("source")
	var digests := {}
	for file in DirAccess.get_files_at(directory):
		digests[file] = FileAccess.get_sha256(directory.path_join(file))
	var files := Files.new()
	assert_int(files.open(create_temp_dir("import-%d" % Time.get_ticks_usec()), "world")).is_equal(
		OK
	)
	assert_int(Import.copy("source", "host", files)).is_equal(OK)
	assert_str(files.manifest.quests.flags.loaded).is_equal("source")
	assert_bool(files.profiles.has("host")).is_true()
	assert_int(Import.copy("source", "another", files)).is_equal(ERR_ALREADY_EXISTS)
	var target := files.directory.get_base_dir().get_base_dir()
	files.close()
	# A copied legacy resource must be self-contained even after restarting elsewhere.
	var away := directory + "-away"
	assert_int(DirAccess.rename_absolute(directory, away)).is_equal(OK)
	var reopen := files.open(target, "world")
	assert_int(DirAccess.rename_absolute(away, directory)).is_equal(OK)
	assert_int(reopen).is_equal(OK)
	var restored: CogitoSceneState = files.scenes[files.manifest.active].scene
	assert_array(restored.saved_destroyed_nodes).is_equal(level.saved_destroyed_nodes)
	files.close()
	assert_int(DirAccess.get_files_at(directory).size()).is_equal(digests.size())
	for file: String in digests:
		assert_str(FileAccess.get_sha256(directory.path_join(file))).is_equal(digests[file])


func test_malformed_v2_cannot_fall_back_on_good_legacy() -> void:
	make_slot("bad")
	write_text(manager.player_file("bad"), "{")
	var files := Files.new()
	assert_int(files.open(create_temp_dir("bad-import"), "world")).is_equal(OK)
	assert_int(Import.copy("bad", "host", files)).is_equal(ERR_FILE_CORRUPT)
	assert_dict(files.manifest).is_empty()
	files.close()


func test_server_options() -> void:
	assert_int(Config.server_config({}, true).autosave_seconds).is_equal(60)
	var settings := Config.parse_cli(["--server", "--world", "demo", "--autosave-seconds", "0"])
	assert_str(settings.world).is_equal("demo")
	assert_int(settings.autosave_seconds).is_zero()
	assert_bool(Config.parse_cli(["--autosave-seconds", "-1"]).has("reason")).is_true()
	assert_bool(Config.parse_cli(["--world", "../save"]).has("reason")).is_true()
