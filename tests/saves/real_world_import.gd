extends SceneTree
## Read a real slot from an isolated user directory, verify the generation and the source bytes.


func _initialize() -> void:
	_run.call_deferred()


func _digest(path: String) -> Dictionary:
	var digest := {}
	for file in DirAccess.get_files_at(path):
		digest[file] = FileAccess.get_sha256(path.path_join(file))
	return digest


func _run() -> void:
	var slot := OS.get_cmdline_user_args()[0]
	var source := "user://saves".path_join(slot)
	var original := _digest(source)
	var facade := root.get_node("CogitoNet")
	var suite: Script = load("res://tests/net/memory_session_suite.gd")
	var peers := {}
	facade.transport_factory = func(): return suite.MemoryTransport.new(peers, 1)
	var options := {"save_dir": "user://import", "world": "copy-" + slot, "import_slot": slot}
	var err: Error = facade.host(options)
	facade.disconnect_session()
	# The probe owns this test copy. Boot from disk while its source directory is unavailable.
	var away := source + "-probe"
	var moved := false
	if err == OK:
		err = DirAccess.rename_absolute(source, away)
		moved = err == OK
	if err == OK:
		options.erase("import_slot")
		err = facade.host(options)
	if err == OK:
		err = change_scene_to_file(facade.starting_level(""))
	if err == OK:
		await scene_changed
		await process_frame
		if not facade.local_player():
			err = ERR_UNCONFIGURED
		else:
			err = facade.save_world()
	facade.disconnect_session()
	var files: RefCounted = load("res://addons/cogito/SceneManagement/cogito_world_files.gd").new()
	if err == OK:
		err = files.open(options.save_dir, options.world)
	var runtime := 0
	if err == OK:
		var scene: Dictionary = files.scenes[files.manifest.active]
		for id: String in scene.objects:
			if id.begins_with("runtime:") and not scene.objects[id].get("removed", false):
				runtime += 1
	if moved:
		var rename_error := DirAccess.rename_absolute(away, source)
		if rename_error != OK:
			err = rename_error
	var passed: bool = (
		err == OK
		and not original.is_empty()
		and _digest(source) == original
		and files.manifest.get("generation") == 2
		and files.profiles.size() == 1
		and not files.scenes.is_empty()
		and (slot != "11" or runtime == 2)
	)
	var result := "PASS" if passed else "FAILED " + error_string(err)
	print("REAL WORLD IMPORT ", slot, " ", result, " runtime=", runtime)
	files.close()
	quit(0 if passed else 1)
