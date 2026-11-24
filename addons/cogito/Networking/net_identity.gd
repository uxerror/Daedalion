extends RefCounted
## Default identity provider. A game may subclass this and install it before opening a session.

const CLIENT_PATH := "user://net/identity.cfg"
const HASH := HashingContext.HASH_SHA256

var _verifiers := ConfigFile.new()
var _server_path := ""


## Opens the server's registry. Existing unreadable data fails closed.
func open_server(save_dir: String) -> Error:
	_server_path = save_dir.path_join("identities.cfg")
	_verifiers.clear()
	if FileAccess.file_exists(_server_path):
		return _verifiers.load(_server_path)
	return DirAccess.make_dir_recursive_absolute(save_dir)


## Loads an address-scoped profile. An empty dictionary signals a storage error.
func load_client(scope: String, _credentials: Dictionary) -> Dictionary:
	var file := ConfigFile.new()
	if FileAccess.file_exists(CLIENT_PATH) and file.load(CLIENT_PATH) != OK:
		return {}
	if not file.has_section(scope):
		return {"player_id": "", "key": PackedByteArray()}
	var key: Variant = file.get_value(scope, "key", null)
	var id: Variant = file.get_value(scope, "player_id", "")
	if not (key is PackedByteArray and key.size() == 96 and id is String and not id.is_empty()):
		return {}
	return {"player_id": id, "key": key}


## Commits the assigned ID and secret together after admission.
func save_client(scope: String, profile: Dictionary, player_id: String) -> Error:
	var file := ConfigFile.new()
	if FileAccess.file_exists(CLIENT_PATH):
		var err := file.load(CLIENT_PATH)
		if err != OK:
			return err
	file.set_value(scope, "player_id", player_id)
	file.set_value(scope, "key", profile.key)
	return _publish(file, CLIENT_PATH)


## Used by the server to decide whether registration is necessary.
func is_known(player_id: String) -> bool:
	return _verifiers.has_section_key("players", player_id)


## Builds the wire response. Enrollment rotates the secret, including after a server reset.
func respond(profile: Dictionary, nonce: PackedByteArray, enrolling: bool) -> Dictionary:
	var crypto := Crypto.new()
	if enrolling:
		profile.key = crypto.generate_random_bytes(96)
	var key: PackedByteArray = profile.key
	if key.size() != 96:
		return {}
	var reply := {"proof": crypto.hmac_digest(HASH, key, nonce)}
	if enrolling:
		# HMAC-SHA256 normalizes keys longer than its 64-byte block to SHA256(key).
		var digest := HashingContext.new()
		digest.start(HASH)
		digest.update(key)
		reply.verifier = digest.finish()
	return reply


## Consumes a fresh challenge. Returns a verified or newly issued ID, or "" on failure.
func authenticate(claim: String, nonce: PackedByteArray, reply: Dictionary) -> String:
	var enrolling := not is_known(claim)
	var verifier: Variant = reply.get("verifier")
	if not enrolling:
		verifier = _verifiers.get_value("players", claim)
	var proof: Variant = reply.get("proof")
	if not (verifier is PackedByteArray and verifier.size() == 32):
		return ""
	if not (proof is PackedByteArray and proof.size() == 32 and nonce.size() == 32):
		return ""
	var crypto := Crypto.new()
	if not crypto.constant_time_compare(proof, crypto.hmac_digest(HASH, verifier, nonce)):
		return ""
	if not enrolling:
		return claim
	var player_id := crypto.generate_random_bytes(16).hex_encode()
	_verifiers.set_value("players", player_id, verifier)
	if _publish(_verifiers, _server_path) != OK:
		_verifiers.erase_section_key("players", player_id)
		return ""
	return player_id


func _publish(file: ConfigFile, path: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK:
		return err
	var temp := path + ".tmp"
	err = file.save(temp)
	if err == OK:
		if OS.get_name() in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD"]:
			var permissions := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
			err = FileAccess.set_unix_permissions(temp, permissions)
	if err == OK:
		err = DirAccess.rename_absolute(temp, path)
	if err != OK and FileAccess.file_exists(temp):
		DirAccess.remove_absolute(temp)
	return err
