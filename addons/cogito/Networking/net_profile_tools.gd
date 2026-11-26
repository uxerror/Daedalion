extends RefCounted
## Operator actions on the same manifest and private projections as the gameplay writer.

const Files := preload("../SceneManagement/cogito_world_files.gd")

## Optional (target_profile) -> bool. True protects the target from an unforced move.
var has_progress: Callable


## Accept OLD NEW or OLD NEW force. IDs never become paths or modify the verifier registry.
static func parse_move(command: String) -> PackedStringArray:
	var words := command.strip_edges().replace("\t", " ").split(" ", false)
	if words.size() not in [2, 3] or (words.size() == 3 and words[2] != "force"):
		return []
	if words[0] == words[1] or "\n" in command.strip_edges():
		return []
	return words


## Both the live queue and the stopped CLI validate before staging any replacement.
func validate(move: PackedStringArray, profiles: Dictionary) -> Error:
	if move.is_empty():
		return ERR_INVALID_PARAMETER
	if not profiles.has(move[0]):
		return ERR_DOES_NOT_EXIST
	if profiles.has(move[1]) and move.size() == 2:
		var row: Dictionary = profiles[move[1]]
		var protected: bool = has_progress.call(row) if has_progress.is_valid() else _progress(row)
		if protected:
			return ERR_ALREADY_EXISTS
	return OK


static func _progress(row: Dictionary) -> bool:
	if row.dead or not row.stock.rows.is_empty() or not row.get("progression", {}).is_empty():
		return true
	for wallet: Variant in row.stock.money.values():
		if wallet[0] != 0:
			return true
	return row.get("quests", {}).get("revision", 0) > 0 or not row.get("unplayed", false)


## Copy the source into this batch and suppress the carried-forward old member.
static func apply_move(move: PackedStringArray, records: Dictionary, prior: Dictionary) -> void:
	var row: Dictionary = records.get(move[0], prior.get(move[0], {})).duplicate(true)
	row.id = move[1]
	records.erase(move[0])
	records[move[1]] = row


## Emit sorted machine-readable lines, including carried profiles from layout 1 worlds.
static func list_profiles(records: Dictionary) -> void:
	var ids := records.keys()
	ids.sort()
	for id: String in ids:
		var row: Dictionary = records[id]
		var count := 0
		for stack: Array in row.stock.rows.values():
			count += int(stack[2])
		var info := {
			"player_id": id,
			"display_name": row.get("display_name", ""),
			"last_level": row.level,
			"last_seen": row.get("last_seen", 0),
			"dead": row.dead,
			"item_count": count,
		}
		print("NET PROFILE ", JSON.stringify(info))
	print("NET LIST OK count=", ids.size())


## One-shot administration holds the normal world claim throughout recovery and publication.
func stopped(config: Dictionary) -> Error:
	var files := Files.new()
	var err := files.open(config.save_dir, config.world)
	if err != OK:
		return err
	var command: String = config.profile_command
	if command == "list":
		list_profiles(files.profiles)
	elif command.begins_with("rebind "):
		var move := parse_move(command.trim_prefix("rebind "))
		err = validate(move, files.profiles)
		if err == OK:
			var rows := {}
			apply_move(move, rows, files.profiles)
			err = files.commit(files.manifest, {}, rows, [], [move[0]])
	else:
		err = ERR_INVALID_PARAMETER
	files.close()
	return err
