extends RefCounted
## A slot is a flat directory. All renames below stay in the same parent directory.
## Copy the source into a fresh .writing-S, run the writer there, then seal the
## complete generation by renaming it to .ready-S. Move S to .previous-S and
## publish .ready-S as S. Never copy into a live slot. On startup, live wins.
## If live is missing, restore previous first, otherwise finish a sealed ready.
## A writing directory is never eligible for recovery. Cleanup is retryable.
## A manual save keeps previous until the index file has been atomically
## replaced. A reported index error rolls the directory back. A crash between
## these commits can leave a complete new live slot with the previous history.

const WRITING := ".writing-"
const READY := ".ready-"
const PREVIOUS := ".previous-"
const PREFIXES := [WRITING, READY, PREVIOUS]

var root: String
## Test seam. Return true to simulate an I/O error before the named operation.
var fail_before: Callable
var last_failure := ""


func _init(directory: String) -> void:
	root = directory


func valid_slot(slot: String) -> bool:
	return slot.is_valid_filename() and not slot.begins_with(".") and slot != "saves.data"


func check(error: Error, operation: String) -> Error:
	if error != OK:
		var message := "%s: %s" % [operation, error_string(error)]
		last_failure = message
		push_warning(message)
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			CogitoGlobals.debug_log(true, "SlotStorage", message)
	return error


func before(operation: String) -> Error:
	if fail_before.is_valid() and fail_before.call(operation):
		return check(ERR_CANT_CREATE, operation)
	return OK


func recover_all() -> Error:
	var error := DirAccess.make_dir_recursive_absolute(root)
	if error != OK:
		return check(error, root)
	var directory := DirAccess.open(root)
	if not directory:
		return check(DirAccess.get_open_error(), root)
	directory.include_hidden = true
	var slots := {}
	for entry in directory.get_directories():
		for prefix: String in PREFIXES:
			if entry.begins_with(prefix):
				slots[entry.trim_prefix(prefix)] = true
	var first_error := OK
	for slot: String in slots:
		error = recover(slot)
		if first_error == OK:
			first_error = error
	return first_error


func recover(slot: String) -> Error:
	if not valid_slot(slot):
		return check(ERR_INVALID_PARAMETER, slot)
	var live := root.path_join(slot)
	if not DirAccess.dir_exists_absolute(live):
		for prefix: String in [PREVIOUS, READY]:
			var candidate := root.path_join(prefix + slot)
			if DirAccess.dir_exists_absolute(candidate):
				var error := _rename(candidate, live, "recover " + slot)
				if error != OK:
					return error
				break
	for prefix: String in PREFIXES:
		var error := remove_directory(root.path_join(prefix + slot))
		if error != OK:
			return error
	return OK


func remove_directory(path: String) -> Error:
	if not DirAccess.dir_exists_absolute(path):
		return OK
	var parent := DirAccess.open(path.get_base_dir())
	if not parent:
		return check(DirAccess.get_open_error(), path.get_base_dir())
	if parent.is_link(path.get_file()):
		return check(ERR_INVALID_DATA, path)
	var directory := DirAccess.open(path)
	if not directory:
		return check(DirAccess.get_open_error(), path)
	directory.include_hidden = true
	for entry in directory.get_files():
		var error := directory.remove(entry)
		if error != OK:
			return check(error, path.path_join(entry))
	directory = null
	return check(DirAccess.remove_absolute(path), path)


## source is an existing slot, or empty for a fresh generation. writer receives
## the full staging directory and returns Error after closing its last file.
func replace(
	slot: String,
	source: String,
	writer := Callable(),
	skip := PackedStringArray(),
	after_publish := Callable()
) -> Error:
	var error := stage(slot, source, writer, skip)
	return publish_staged(slot, after_publish) if error == OK else error


## Prepare and verify an ineligible .writing directory under the caller's exclusive claim.
func stage(slot: String, source: String, writer: Callable, skip: PackedStringArray) -> Error:
	last_failure = ""
	if not valid_slot(slot) or (not source.is_empty() and not valid_slot(source)):
		return check(ERR_INVALID_PARAMETER, slot)
	var error := recover(slot)
	if error != OK:
		return error
	var writing := root.path_join(WRITING + slot)
	error = before("create staging")
	if error == OK:
		error = check(DirAccess.make_dir_recursive_absolute(writing), writing)
	if error == OK and not source.is_empty():
		error = _copy_files(root.path_join(source), writing, skip)
	if error == OK and writer.is_valid():
		error = writer.call(writing)
	if error != OK:
		remove_directory(writing)
	return error


## Seal only after any final eligibility check. Roll back a reported publication failure.
func publish_staged(slot: String, after_publish: Callable) -> Error:
	if not valid_slot(slot):
		return ERR_INVALID_PARAMETER
	var writing := root.path_join(WRITING + slot)
	var ready := root.path_join(READY + slot)
	var previous := root.path_join(PREVIOUS + slot)
	var live := root.path_join(slot)
	var error := _rename(writing, ready, "seal staging")
	if error == OK and DirAccess.dir_exists_absolute(live):
		error = _rename(live, previous, "back up live")
	if error == OK:
		error = _rename(ready, live, "publish staging")
	if error == OK and after_publish.is_valid():
		error = after_publish.call()
		if error != OK:
			var rollback := _rename(live, writing, "withdraw publication")
			if rollback != OK:
				return rollback
	if error != OK:
		# Prefer the old generation on a reported failure. If rollback itself
		# fails, keep previous intact so recover() can retry after a restart.
		if DirAccess.dir_exists_absolute(previous) and not DirAccess.dir_exists_absolute(live):
			var restored := _rename(previous, live, "restore backup")
			if restored != OK:
				return restored
		remove_directory(ready)
		remove_directory(writing)
		return error
	remove_directory(previous)  # Published already. Retry leftover cleanup during recovery.
	return OK


func _copy_files(source: String, destination: String, skip: PackedStringArray) -> Error:
	var directory := DirAccess.open(source)
	if not directory:
		return check(DirAccess.get_open_error(), source)
	directory.include_hidden = true
	var error := directory.list_dir_begin()
	if error != OK:
		return check(error, source)
	var entry := directory.get_next()
	while not entry.is_empty():
		if directory.current_is_dir() or directory.is_link(entry):
			return check(ERR_INVALID_DATA, source.path_join(entry))
		if not skip.has(entry):
			var from := source.path_join(entry)
			var to := destination.path_join(entry)
			error = before("copy " + entry)
			if error == OK:
				error = check(DirAccess.copy_absolute(from, to), from)
			if error != OK:
				return error
		entry = directory.get_next()
	return OK


func _rename(source: String, destination: String, operation: String) -> Error:
	var error := before(operation)
	if error == OK:
		error = check(DirAccess.rename_absolute(source, destination), operation + " " + destination)
	return error
