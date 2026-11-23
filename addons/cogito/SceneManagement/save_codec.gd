extends RefCounted
## One codec instance per file. Local IDs preserve sharing between slots, quickslots,
## inventories and equipped items. Only JSON primitives reach the disk.
const FORMAT := "daedalion-save"
const VERSION := 2
const SUFFIX := ".v2.json"
## Each migration takes a document and returns the document for the next version.
const MIGRATIONS: Dictionary[int, Callable] = {}

var warnings: Array[Dictionary] = []
var reason := ""

var _records: Array = []
var _ids := {}
var _instances := {}


func write(state: Resource, path: String, kind: String) -> Error:
	var root := _local(state, kind)
	var document := {
		"format": FORMAT,
		"version": VERSION,
		"kind": kind,
		"engine": "4.7",
		"root": root,
		"resources": _records,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()
	if not file.store_string(JSON.stringify(document, "\t", false, true) + "\n"):
		return ERR_FILE_CANT_WRITE
	file.flush()
	return file.get_error()


func read(path: String, kind: String) -> Resource:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return null
	var doc: Dictionary = json.data
	if doc.get("format") != FORMAT or doc.get("kind") != kind:
		return null
	var version: Variant = doc.get("version")
	if not (version is float or version is int) or version != int(version):
		return null
	if version > VERSION:
		reason = "Save from a newer version."
		return null
	while version < VERSION:
		if not MIGRATIONS.has(int(version)):
			return null
		doc = MIGRATIONS[int(version)].call(doc)
		version += 1
	if (
		not doc.get("engine") is String
		or not doc.get("resources") is Array
		or not doc.get("root") is Dictionary
		or not doc.root.has("$local")
	):
		return null
	_records = doc.resources
	var state: Variant = _decode(doc.root, kind)
	if not reason.is_empty():
		return null
	if kind == "scene" and state is CogitoSceneState:
		for group: Array in [
			state.saved_nodes,
			state.saved_states,
			state.saved_element_states,
			state.saved_destroyed_nodes
		]:
			if not group.all(func(entry: Variant) -> bool: return entry is Dictionary):
				return null
		return state
	if kind == "player" and state is CogitoPlayerState:
		return state
	return null


func _reference(path: String) -> Dictionary:
	var id := ResourceLoader.get_resource_uid(path)
	var uid := ResourceUID.id_to_text(id) if id != ResourceUID.INVALID_ID else ""
	return {"$res": uid, "path": path}


func _local(resource: Resource, field: String) -> Dictionary:
	if _ids.has(resource):
		return {"$local": _ids[resource]}
	var index := _records.size()
	_ids[resource] = index
	var props := {}
	var record := {"class": resource.get_class(), "properties": props}
	_records.append(record)
	var script: Script = resource.get_script()
	if script:
		record["script"] = _reference(script.resource_path)
	for property: Dictionary in resource.get_property_list():
		var key: String = property.name
		if not _stored(property):
			continue
		var value: Variant = resource.get(key)
		if _supported(value, field + "." + key):
			props[key] = _encode(value, field + "." + key)
	return {"$local": index}


func _stored(property: Dictionary) -> bool:
	return (
		property.usage & PROPERTY_USAGE_STORAGE
		and property.name not in [&"script", &"resource_path", &"resource_scene_unique_id"]
	)


func _supported(value: Variant, field: String) -> bool:
	if value is Script and value.is_built_in():
		push_warning("Skipping embedded script at " + field)
		return false
	if value == null or value is Resource:
		return true
	if typeof(value) in [TYPE_OBJECT, TYPE_SIGNAL, TYPE_CALLABLE, TYPE_RID]:
		push_warning("Skipping %s at %s" % [type_string(typeof(value)), field])
		return false
	if (
		value is Array
		and value.is_typed()
		and ClassDB.is_parent_class(value.get_typed_class_name(), &"Node")
	):
		push_warning("Skipping live nodes at " + field)
		return false
	return true


func _encode(value: Variant, field: String) -> Variant:
	if value is Resource:
		if not value.is_built_in():
			return _reference(value.resource_path)
		return _local(value, field)
	if value is Array:
		return _encode_array(value, field)
	if value is Dictionary:
		return _encode_dict(value, field)
	if value is String:
		if value.begins_with("uid://"):
			var id := ResourceUID.text_to_id(value)
			var path := ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
			return {"$file": {"$res": value, "path": path}}
		# Scene and prefab filenames are paths in the runtime API. Resolve their
		# names without loading the PackedScene on the menu thread.
		if value.begins_with("res://") and not value.contains("::"):
			return {"$file": _reference(value)}
		return value
	if value == null:
		return null
	if value is bool:
		return value
	# Godot tags math, packed arrays, NodePath, StringName and 64-bit numbers.
	return {"$variant": JSON.from_native(value)}


func _encode_array(value: Array, field: String) -> Variant:
	var entries := []
	for i in value.size():
		var at := "%s[%d]" % [field, i]
		if _supported(value[i], at):
			entries.append(_encode(value[i], at))
	if value.is_typed():
		return {
			"$array": entries,
			"of":
			_type_spec(
				value.get_typed_builtin(), value.get_typed_class_name(), value.get_typed_script()
			),
		}
	return entries


func _encode_dict(value: Dictionary, field: String) -> Dictionary:
	var dict := {}
	var pairs := []
	var keys: Array = value.keys()
	var plain := keys.all(func(k: Variant) -> bool: return k is String and not k.begins_with("$"))
	if plain:
		keys.sort()
	for key: Variant in keys:
		var at := "%s.%s" % [field, key]
		if _supported(key, at) and _supported(value[key], at):
			if plain:
				dict[key] = _encode(value[key], at)
			else:
				pairs.append([_encode(key, at), _encode(value[key], at)])
	var body := dict if plain else {"$pairs": pairs}
	if value.is_typed():
		return {
			"$dict": body,
			"keys":
			_type_spec(
				value.get_typed_key_builtin(),
				value.get_typed_key_class_name(),
				value.get_typed_key_script()
			),
			"values":
			_type_spec(
				value.get_typed_value_builtin(),
				value.get_typed_value_class_name(),
				value.get_typed_value_script()
			),
		}
	return body


func _type_spec(builtin: int, native_class: StringName, script: Script) -> Dictionary:
	var spec := {"type": builtin, "class": String(native_class)}
	if script:
		spec["script"] = _reference(script.resource_path)
	return spec


func _read_type(spec: Variant, field: String) -> Dictionary:
	if not spec is Dictionary or not spec.get("type") is float or not spec.get("class") is String:
		_invalid(field)
		return {}
	var builtin := int(spec.type)
	if builtin != spec.type or builtin < TYPE_NIL or builtin >= TYPE_MAX:
		_invalid(field)
		return {}
	var script: Script
	if spec.has("script"):
		if not spec.script is Dictionary:
			_invalid(field)
			return {}
		script = _resolve(spec.script, field) as Script
	return {"builtin": builtin, "native": StringName(spec["class"]), "script": script}


func _invalid(field: String) -> Variant:
	reason = "Invalid save data at " + field + "."
	return null


## ResourceLoader.exists also accepts cached resources whose file was deleted.
## Imported/remapped resources in a PCK may only have the sidecar at the source path.
static func file_exists(path: String, type_hint := "") -> bool:
	return (
		(
			FileAccess.file_exists(path)
			or FileAccess.file_exists(path + ".import")
			or FileAccess.file_exists(path + ".remap")
		)
		and ResourceLoader.exists(path, type_hint)
	)


func _resolve(ref: Dictionary, field: String, path_only := false) -> Variant:
	if not ref.get("$res") is String or not ref.get("path") is String:
		return _invalid(field)
	var id := ResourceUID.text_to_id(ref["$res"])
	var paths: Array[String] = []
	if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
		paths.append(ResourceUID.get_id_path(id))
	if ref.path not in paths:
		paths.append(ref.path)
	for path in paths:
		if not (path.begins_with("res://") or path.begins_with("user://")):
			continue
		if not file_exists(path):
			continue
		if path_only:
			return path
		var resource := ResourceLoader.load(path)
		if resource:
			return resource
	warnings.append({"path": ref.path, "uid": ref["$res"], "field": field})
	if path_only:
		return ""
	return null


func _decode(value: Variant, field: String) -> Variant:
	if value is Array:
		var entries := []
		for i in value.size():
			entries.append(_decode(value[i], "%s[%d]" % [field, i]))
		return entries
	if not value is Dictionary:
		if value == null or value is bool or value is String:
			return value
		return _invalid(field)
	if value.has("$res"):
		return _resolve(value, field)
	if value.has("$file") and value["$file"] is Dictionary:
		return _resolve(value["$file"], field, true)
	if value.has("$array") and value["$array"] is Array:
		var spec := _read_type(value.get("of"), field)
		if spec.is_empty():
			return null
		var items: Array = _decode(value["$array"], field)
		if (
			spec.builtin == TYPE_OBJECT
			and spec.script != InventorySlotPD
			and spec.script != AmmoItemPD
		):
			# Grid, quickslot and ammunition indices have positional meaning.
			# Other resource lists (quests, objectives, loot, flags) skip lost entries.
			for i in range(items.size() - 1, -1, -1):
				if items[i] == null and value["$array"][i] != null:
					items.remove_at(i)
		return Array(items, spec.builtin, spec.native, spec.script)
	if value.has("$dict") and value["$dict"] is Dictionary:
		var keys := _read_type(value.get("keys"), field)
		var values := _read_type(value.get("values"), field)
		if keys.is_empty() or values.is_empty():
			return null
		var body: Dictionary = _decode(value["$dict"], field)
		return Dictionary(
			body,
			keys.builtin,
			keys.native,
			keys.script,
			values.builtin,
			values.native,
			values.script
		)
	if value.has("$local"):
		return _restore(value["$local"], field)
	if value.has("$variant"):
		var decoded: Variant = JSON.to_native(value["$variant"], false)
		return decoded if decoded != null else _invalid(field)
	var dict := {}
	if value.has("$pairs") and value["$pairs"] is Array:
		for pair: Variant in value["$pairs"]:
			if not pair is Array or pair.size() != 2:
				return _invalid(field)
			var key: Variant = _decode(pair[0], field)
			if key != null:
				dict[key] = _decode(pair[1], "%s.%s" % [field, key])
	else:
		for key: String in value:
			if key.begins_with("$"):
				return _invalid(field)
			dict[key] = _decode(value[key], field + "." + key)
	return dict


func _restore(index: Variant, field: String) -> Resource:
	if not (index is float or index is int) or index != int(index):
		return _invalid(field)
	var i := int(index)
	if i < 0 or i >= _records.size():
		return _invalid(field)
	if _instances.has(i):
		return _instances[i]
	var record: Variant = _records[i]
	if not record is Dictionary or not record.get("properties") is Dictionary:
		return _invalid(field)
	var native_class: Variant = record.get("class")
	if not native_class is String or not ClassDB.is_parent_class(native_class, &"Resource"):
		return _invalid(field)
	if ClassDB.is_parent_class(native_class, &"Script"):
		return _invalid(field)
	var resource: Resource
	if record.has("script"):
		if not record.script is Dictionary:
			return _invalid(field)
		var script := _resolve(record.script, field + ".script") as Script
		if not script:
			return null
		if (
			not script.resource_path.begins_with("res://")
			or not script.can_instantiate()
			or script.get_instance_base_type() != StringName(native_class)
		):
			return _invalid(field)
		resource = script.new()
	elif ClassDB.can_instantiate(native_class):
		resource = ClassDB.instantiate(native_class)
	if not resource:
		return _invalid(field)
	_instances[i] = resource
	if not _restore_properties(resource, record.properties, field):
		return null
	# An empty grid cell is meaningful. All references to the lost stack,
	# including quickslots and other cells covered by it, must resolve to null.
	if resource is WieldableItemPD and resource.ammo_types.has(null):
		var selected: AmmoItemPD
		if (
			resource.current_ammo_type >= 0
			and resource.current_ammo_type < resource.ammo_types.size()
		):
			selected = resource.ammo_types[resource.current_ammo_type]
		var kept: Array = resource.ammo_types.filter(
			func(ammo: AmmoItemPD) -> bool: return ammo != null
		)
		resource.ammo_types.assign(kept)
		resource.current_ammo_type = maxi(0, resource.ammo_types.find(selected))
	if resource is SingleFlagGroup and not resource.flag:
		_instances[i] = null
	if resource is WieldableItemPD and not resource.wieldable_scene:
		if record.properties.get("wieldable_scene") != null:
			_instances[i] = null
	if (resource is InventorySlotPD or resource is LootDropEntry) and not resource.inventory_item:
		_instances[i] = null
	return _instances[i]


## The writer emits properties in Godot storage order. Some native setters (for
## example Animation tracks/N/type) create properties absent on a new instance.
func _restore_properties(resource: Resource, properties: Dictionary, field: String) -> bool:
	var known := {}
	for property: Dictionary in resource.get_property_list():
		known[property.name] = property
	for key: String in properties:
		var property: Dictionary = known.get(key, {})
		if not property.is_empty() and not _stored(property):
			continue
		var at := field + "." + key
		var decoded: Variant = _decode(properties[key], at)
		if not reason.is_empty():
			return false
		if not property.is_empty() and not _compatible(resource, property, decoded):
			_invalid(at)
			return false
		resource.set(key, decoded)
	return true


func _compatible(resource: Resource, property: Dictionary, value: Variant) -> bool:
	if property.type == TYPE_OBJECT:
		return value == null or value is Resource
	if property.type == TYPE_ARRAY:
		var array: Array = resource.get(property.name)
		return value is Array and (not array.is_typed() or array.is_same_typed(value))
	if property.type == TYPE_DICTIONARY:
		var dict: Dictionary = resource.get(property.name)
		return value is Dictionary and (not dict.is_typed() or dict.is_same_typed(value))
	# A few native storage getters differ from their declared type (Curve._data).
	return (
		property.type == TYPE_NIL
		or property.type == typeof(value)
		or typeof(resource.get(property.name)) == typeof(value)
	)
