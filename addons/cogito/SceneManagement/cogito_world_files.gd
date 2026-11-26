extends RefCounted
## One exclusive local writer and a flat, manifest-verified slot generation.

const Stock := preload("../Networking/net_stock.gd")
const Storage := preload("cogito_slot_storage.gd")
const Codec := preload("save_codec.gd")
const Record := preload("cogito_world_record.gd")
const SLOT := "current"
const MANIFEST := "world.v2.json"
const LOCK := "writer-"

var storage: Storage
var directory: String
var manifest := {}
var scenes := {}
var profiles := {}
var _claim := ""


## Claim before recovery or opening the transport. An unreadable live world fails closed.
func open(save_dir: String, world: String) -> Error:
	if not _claim.is_empty() or not valid_name(world):
		return ERR_INVALID_PARAMETER
	directory = save_dir.path_join("worlds").path_join(world)
	var err := DirAccess.make_dir_recursive_absolute(directory)
	if err == OK:
		err = _lock()
	if err == OK:
		storage = Storage.new(directory)
		err = _recover(world)

	if err != OK:
		close()
	return err


# Validate candidates before the slot recovery routine cleans its other directories.
# Preserve a damaged higher-priority generation for diagnosis if a complete fallback exists.
func _recover(world: String) -> Error:
	var damaged: Array[String] = []
	for prefix: String in ["", Storage.PREVIOUS, Storage.READY]:
		var path := directory.path_join(prefix + SLOT)
		if not DirAccess.dir_exists_absolute(path):
			continue
		var data := _read(path)
		if not data.is_empty() and data.world.id == world:
			for bad_path in damaged:
				var suffix := Crypto.new().generate_random_bytes(8).hex_encode()
				var err := DirAccess.rename_absolute(bad_path, bad_path + ".damaged-" + suffix)
				if err != OK:
					return err
			var recovery_error := storage.recover(SLOT)
			if recovery_error == OK:
				manifest = data.world
				scenes = data.scenes
				profiles = data.profiles
			return recovery_error
		damaged.append(path)
	return storage.recover(SLOT) if damaged.is_empty() else ERR_FILE_CORRUPT


## World directories use a single, visible, portable filename component.
static func valid_name(world: String) -> bool:
	return (
		world.is_valid_filename()
		and world.validate_node_name() == world
		and not world.begins_with(".")
	)


# Create our unique claim first. Two contenders may both back off, but cannot both win.
# Only remove unique claims, never unlink a common lock while another writer could acquire it.
func _lock() -> Error:
	var dir := DirAccess.open(directory)
	if not dir:
		return DirAccess.get_open_error()
	var pid := OS.get_process_id()
	var name := "%s%d-%s.lock" % [LOCK, pid, Crypto.new().generate_random_bytes(16).hex_encode()]
	var file := FileAccess.open(directory.path_join(name), FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()
	file.close()
	_claim = directory.path_join(name)
	for entry in dir.get_files():
		if entry == name or not entry.begins_with(LOCK) or not entry.ends_with(".lock"):
			continue
		var owner := entry.trim_prefix(LOCK).get_slice("-", 0)
		if not owner.is_valid_int() or int(owner) == pid or _process_alive(int(owner)):
			return ERR_BUSY
		dir.remove(entry)
	return OK


# Godot logs an engine ERROR for a dead PID that is not its child. Ask procfs first on Linux.
static func _process_alive(pid: int) -> bool:
	if OS.get_name() == "Linux" and DirAccess.dir_exists_absolute("/proc/self"):
		return DirAccess.dir_exists_absolute("/proc/%d" % pid)
	return OS.is_process_running(pid)


## Release only this instance's claim. Never flush gameplay on close.
func close() -> void:
	if not _claim.is_empty():
		DirAccess.remove_absolute(_claim)
		_claim = ""
	manifest = {}
	scenes = {}
	profiles = {}


static func _filename(id: String, kind: String) -> String:
	var token := id.sha256_text()
	if kind == "world_scene":
		if valid_name(id) and id == id.to_lower() and not id.begins_with("hash-"):
			return "scene_" + id + Codec.SUFFIX
		return "scene_hash-" + token + Codec.SUFFIX
	return "player_" + token + Codec.SUFFIX


static func _write(path: String, kind: String, fields: Dictionary) -> Error:
	var record := Record.new()
	record.fields = fields
	return Codec.new().write(record, path, kind)


static func _load(path: String, kind: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var codec := Codec.new()
	var record := codec.read(path, kind) as Record
	return record.fields if record and codec.warnings.is_empty() else {}


static func _read(path: String) -> Dictionary:
	var world := _load(path.path_join(MANIFEST), "world")
	if (
		world.get("layout") != 1
		or not world.get("id") is String
		or not world.get("generation") is int
		or world.generation < 1
		or not world.get("tick") is int
		or not world.get("levels") is Dictionary
		or not world.get("players") is Dictionary
		or not _ledger_valid(world.get("quests"))
		or not world.get("shared") is Dictionary
		or not world.has("active")
		or not world.levels.has(world.active)
	):
		return {}
	var result := {"world": world, "scenes": {}, "profiles": {}}
	for kind: String in ["world_scene", "profile"]:
		var levels := kind == "world_scene"
		var index: Dictionary = world.levels if levels else world.players
		var records: Dictionary = result.scenes if levels else result.profiles
		for id: Variant in index:
			if not id is String or id.is_empty() or not index[id] is String:
				return {}
			var file := path.path_join(_filename(id, kind))
			if not FileAccess.file_exists(file) or FileAccess.get_sha256(file) != index[id]:
				return {}
			var fields := _load(file, kind)
			if fields.get("id") != id or not _valid_member(fields, levels):
				return {}
			if not levels and not world.levels.has(fields.level):
				return {}
			records[id] = fields
	return result


static func _valid_member(fields: Dictionary, level: bool) -> bool:
	if level:
		return (
			fields.get("scene") is CogitoSceneState
			and fields.get("path") is String
			and _valid_objects(fields.get("objects"))
			and fields.get("flights", []) is Array
			and fields.get("perception", {}) is Dictionary
			and fields.get("bodies") is Dictionary
			and fields.get("containers") is Dictionary
			and fields.containers.values().all(Stock.valid_projection)
		)
	return (
		fields.get("display_name", "") is String
		and fields.get("last_seen", 0) is int
		and fields.get("last_seen", 0) >= 0
		and fields.get("unplayed", false) is bool
		and fields.get("level") is String
		and fields.get("pose") is Transform3D
		and fields.pose.is_finite()
		and fields.get("dead") is bool
		and fields.get("elements") is Dictionary
		and fields.get("attributes") is Dictionary
		and fields.get("stock") is Dictionary
		and fields.stock.get("money") is Dictionary
		and Stock.valid_projection(fields.stock)
		and (not fields.has("quests") or _ledger_valid(fields.quests))
	)


static func _valid_objects(records: Variant) -> bool:
	if not records is Dictionary:
		return false
	for id: Variant in records:
		if not id is String or not records[id] is Dictionary:
			return false
		var row: Dictionary = records[id]
		if id.begins_with("runtime:") and not row.get("removed", false):
			if not row.get("pose") is Transform3D or not row.pose.is_finite():
				return false
			if not _valid_spawn(row):
				return false
	return true


static func _valid_spawn(row: Dictionary) -> bool:
	if row.has("corpse"):
		return row.corpse is String and row.get("index") is int and row.index >= 0
	if row.has("bag"):
		return row.bag is String and not row.bag.is_empty()
	if not row.get("item") is String or not row.get("quantity") is int:
		return false
	var item := Stock.load_definition(row.item)
	return (
		item != null
		and row.quantity > 0
		and row.get("rotated") is bool
		and (not item is WieldableItemPD or row.has_all(["charge", "ammo"]))
	)


static func _ledger_valid(data: Variant) -> bool:
	return (
		data is Dictionary
		and data.get("revision") is int
		and data.get("quests") is Dictionary
		and data.get("flags") is Dictionary
		and data.get("triggers") is Dictionary
	)


## Copy unchanged members from the prior generation, then verify the whole staged manifest.
func commit(
	world: Dictionary,
	levels: Dictionary,
	players: Dictionary,
	aliases := PackedStringArray(),
	removed_players := PackedStringArray()
) -> Error:
	if _claim.is_empty():
		return ERR_UNAUTHORIZED
	var batch := prepare(world, levels, players, aliases, removed_players)
	var err := publish(batch)
	if err == OK:
		accept(batch)
	return err


## Freeze indexes on the owner thread. The publisher only accesses this isolated batch.
func prepare(
	world: Dictionary,
	levels: Dictionary,
	players: Dictionary,
	aliases: PackedStringArray,
	removed_players: PackedStringArray
) -> Dictionary:
	var next := world.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)
	next.id = directory.get_file()
	next.layout = 1
	next.generation = manifest.get("generation", 0) + 1
	next.levels = manifest.get("levels", {}).duplicate()
	next.players = manifest.get("players", {}).duplicate()
	var skip := PackedStringArray()
	for alias in aliases:
		next.levels.erase(alias)
		skip.append(_filename(alias, "world_scene"))
	for id in removed_players:
		next.players.erase(id)
		skip.append(_filename(id, "profile"))
	return {
		"world": next,
		"scenes": levels,
		"profiles": players,
		"source": "" if manifest.is_empty() else SLOT,
		"skip": skip,
		"aliases": aliases,
		"removed": removed_players,
	}


## Only the serialized writer calls this. Never touch live caches or scene nodes here.
func publish(batch: Dictionary, stage_only := false) -> Error:
	if _claim.is_empty():
		return ERR_UNAUTHORIZED
	var writer := _stage.bind(batch.world, batch.scenes, batch.profiles)
	var err := storage.stage(SLOT, batch.source, writer, batch.skip)
	return err if err != OK or stage_only else seal()


## Hot profile moves do their final roster check and these renames in one main-thread turn.
func seal() -> Error:
	return storage.publish_staged(SLOT, storage.before.bind("after publish"))


## Install verified indexes on the owner thread after the publication barrier.
func accept(batch: Dictionary) -> void:
	for alias: String in batch.aliases:
		scenes.erase(alias)
	for id: String in batch.removed:
		profiles.erase(id)
	manifest = batch.world
	scenes.merge(batch.scenes, true)
	profiles.merge(batch.profiles, true)


func _stage(path: String, world: Dictionary, levels: Dictionary, players: Dictionary) -> Error:
	for kind: String in ["world_scene", "profile"]:
		var records := levels if kind == "world_scene" else players
		var index: Dictionary = world.levels if kind == "world_scene" else world.players
		for id: String in records:
			var file := path.path_join(_filename(id, kind))
			var member_error := storage.before("write " + kind)
			if member_error == OK:
				member_error = storage.check(_write(file, kind, records[id]), file)
			if member_error != OK:
				return member_error
			index[id] = FileAccess.get_sha256(file)
	var err := storage.check(_write(path.path_join(MANIFEST), "world", world), MANIFEST)
	if err == OK:
		err = storage.before("verify world")
	if err == OK and _read(path).is_empty():
		err = storage.check(ERR_FILE_CORRUPT, "verify staged world")
	return err
