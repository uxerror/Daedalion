extends RefCounted
## Revisioned projection of one inventory. Rows describe stack origins, never duplicate grid cells.

var data: CogitoInventory
var revision := 0
var snapshot := {}
var _serial := 0
var _ids := {}


## Resolve scene-local copies through their authored pickup template.
static func definition(item: InventoryItemPD) -> InventoryItemPD:
	if item.has_meta(&"cogito_item_definition"):
		return item.get_meta(&"cogito_item_definition")
	if item.resource_path.is_empty() and item.drop_scene and ResourceLoader.exists(item.drop_scene):
		var scene := load(item.drop_scene) as PackedScene
		var template := pickup_template(scene)
		if template and template.inventory_item.name == item.name:
			return template.inventory_item
	return item


## Read the authored pickup slot without instantiating gameplay or physics.
static func pickup_template(scene: PackedScene) -> InventorySlotPD:
	if not scene:
		return null
	var state := scene.get_state()
	for node in state.get_node_count():
		for prop in state.get_node_property_count(node):
			if state.get_node_property_name(node, prop) == &"slot_data":
				return state.get_node_property_value(node, prop) as InventorySlotPD
	return null


## Copy mutable per-stack fields while retaining identity of the authored definition.
static func copy_stack(original: InventorySlotPD, amount: int) -> InventorySlotPD:
	var stack := InventorySlotPD.new()
	stack.inventory_item = original.inventory_item.duplicate()
	stack.inventory_item.set_meta(&"cogito_item_definition", definition(original.inventory_item))
	stack.quantity = amount
	return stack


## Isolate a container resource even when several instances override it with one subresource.
static func private_copy(template: CogitoInventory) -> CogitoInventory:
	var inv := template.duplicate() as CogitoInventory
	var copied := {}
	inv.inventory_slots = template.inventory_slots.duplicate()
	for i in inv.inventory_slots.size():
		var slot := template.inventory_slots[i]
		if slot:
			if not copied.has(slot):
				copied[slot] = copy_stack(slot, slot.quantity)
				copied[slot].origin_index = i
			inv.inventory_slots[i] = copied[slot]
	inv.first_slot = copied.get(template.first_slot)
	return inv


## Stable during moves and quantity changes. A split or incoming transfer mints a fresh id.
func id_of(slot: InventorySlotPD) -> int:
	return _ids.get(slot, 0) if slot else 0


## Mint an id for a newly inserted stack even if an equip precedes the first inventory scan.
func ensure_id(slot: InventorySlotPD) -> int:
	if not _ids.has(slot):
		_serial += 1
		_ids[slot] = _serial
	return _ids[slot]


## Resolve the owner's private equipment id to the same mutable stack used by the UI.
func equipped_stack() -> InventorySlotPD:
	var row: Array = snapshot.get("rows", {}).get(snapshot.get("equipped", 0), [])
	return data.inventory_slots[row[1]] if not row.is_empty() else null


func _capture() -> Dictionary:
	var rows := {}
	var live := {}
	for i in data.inventory_slots.size():
		var stack := data.inventory_slots[i]
		if not stack or live.has(stack):
			continue
		var id := ensure_id(stack)
		live[stack] = id
		stack.origin_index = i
		var item := stack.inventory_item
		var row := [definition(item).resource_path, i, stack.quantity, item.rotated]
		if item is WieldableItemPD:
			row.append_array([item.charge_current, item.current_ammo_type])
		rows[id] = row
	_ids = live
	var binds := PackedInt64Array()
	for i in data.assigned_quickslots.size():
		var id := id_of(data.assigned_quickslots[i])
		if not id:
			data.assigned_quickslots[i] = null
		binds.append(id)
	return {
		"rows": rows,
		"binds": binds,
		"size": data.inventory_size,
		"length": data.inventory_slots.size(),
		"grid": data.grid,
	}


## Diff the latest committed model, including changes from MP2 key and lockpick consumers.
func refresh(extra: Dictionary = {}) -> Dictionary:
	var current := _capture()
	current.merge(extra)
	var changes := {}
	for key: String in current:
		if snapshot.get(key) != current[key]:
			changes[key] = current[key]
	if changes.has("rows") and snapshot.has("rows"):
		var rows := {}
		for id: int in snapshot.rows:
			if not current.rows.has(id):
				rows[id] = []
		for id: int in current.rows:
			if snapshot.rows.get(id) != current.rows[id]:
				rows[id] = current.rows[id]
		changes.rows = rows
	if not changes.is_empty():
		revision += 1
	snapshot = current
	return changes


## Install a private server projection into the same Resource the existing UI observes.
func apply(fields: Dictionary, version: int, full: bool) -> void:
	var rows: Dictionary = {} if full else snapshot.get("rows", {}).duplicate()
	for id: int in fields.get("rows", {}):
		var row: Array = fields.rows[id]
		if row.is_empty():
			rows.erase(id)
		else:
			rows[id] = row
	if full:
		snapshot.clear()
	snapshot.merge(fields, true)
	snapshot.rows = rows
	revision = version
	data.grid = snapshot.grid
	data.inventory_size = snapshot.size
	data.inventory_slots.resize(snapshot.length)
	data.inventory_slots.fill(null)
	var stacks := {}
	for stack: InventorySlotPD in _ids:
		stacks[_ids[stack]] = stack
	_ids.clear()
	for id: int in rows:
		var row: Array = rows[id]
		var stack: InventorySlotPD = stacks.get(id)
		if not stack:
			if String(row[0]).is_empty():
				continue
			var original := load(row[0]) as InventoryItemPD
			stack = InventorySlotPD.new()
			stack.inventory_item = original.duplicate()
			stack.inventory_item.set_meta(&"cogito_item_definition", original)
		stacks[id] = stack
		_ids[stack] = id
		stack.origin_index = row[1]
		stack.quantity = row[2]
		if stack.inventory_item.rotated != row[3]:
			stack.inventory_item.rotate()
		if stack.inventory_item is WieldableItemPD:
			stack.inventory_item.charge_current = row[4]
			stack.inventory_item.current_ammo_type = row[5]
		data.inventory_slots[row[1]] = stack
		data.add_adjacent_slots(row[1])
	data.assigned_quickslots.clear()
	for id in snapshot.binds:
		data.assigned_quickslots.append(stacks.get(id))
	data.inventory_updated.emit(data)
