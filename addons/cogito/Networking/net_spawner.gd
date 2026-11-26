extends Node
## Server-owned runtime pickups and loot bags. Lifecycle records share MP2's late-join barrier.

const Corpse := preload("net_npc_corpse.gd")
const STOCK := preload("net_stock.gd")
const GRID := preload("net_grid.gd")

## Authority RNG for loot quantities, weights and impulses.
var rng := RandomNumberGenerator.new()
var _serial := 0
var _live := {}
var _bags := {}


## Bind authored bag archetypes before runtime spawns arrive.
func bind(root: Node) -> void:
	_live.clear()
	_bags.clear()
	for component: LootComponent in root.find_children("*", "LootComponent", true, false):
		if component.loot_bag_scene:
			_bags[str(root.get_path_to(component))] = component.loot_bag_scene


static func _pickup(node: Node) -> PickupComponent:
	var components := node.find_children("*", "PickupComponent", true, false)
	return null if components.is_empty() else components[0] as PickupComponent


## Publish initial stack quantities independently of the body motion stream.
func track_authored() -> void:
	if not multiplayer.is_server():
		return
	var world: Node = get_parent().world
	for id: String in world.entities.objects:
		var node: Node = world.entities.objects[id]
		if not node is RigidBody3D:
			continue
		var pickup := _pickup(node)
		if pickup and pickup.slot_data:
			var spec := {"quantity": pickup.slot_data.quantity}
			_live[id] = {"node": node, "spec": spec}
			world.publish(id, spec.duplicate())


## Place a stack in front of the authoritative avatar. A blocked origin rejects the drop.
func drop(actor: CogitoPlayer, stack: InventorySlotPD, count: int) -> bool:
	var aim := actor.get_aim_transform()
	var cast := actor.item_drop_shapecast
	cast.add_exception(actor)
	cast.force_shapecast_update()
	var available := cast.target_position.length() * cast.get_closest_collision_safe_fraction()
	var distance := minf(1.5, available)
	if distance <= actor.radius:
		return false
	var pos := aim.origin - aim.basis.z * distance
	return spawn_item(stack, count, pos) != null


## Only a trusted item definition chooses its authored drop scene.
func spawn_item(stack: InventorySlotPD, count: int, pos: Vector3) -> Node3D:
	if not multiplayer.is_server():
		return null
	var item := STOCK.definition(stack.inventory_item)
	if item.resource_path.is_empty() or not item.drop_scene:
		return null
	var spec := {
		"item": item.resource_path,
		"quantity": count,
		"rotated": stack.inventory_item.rotated,
	}
	if stack.inventory_item is WieldableItemPD:
		spec.charge = stack.inventory_item.charge_current
		spec.ammo = stack.inventory_item.current_ammo_type
	return _spawn(spec, pos)


## Convert a solo Persist instance to the same lifecycle record used by a live network spawn.
func import_object(source: Node3D) -> Node3D:
	var scene := load(source.scene_file_path) as PackedScene
	var pickup := _pickup(source)
	var target: Node3D
	if pickup and pickup.slot_data:
		target = spawn_item(pickup.slot_data, pickup.slot_data.quantity, source.global_position)
	elif source is CogitoContainer and scene in _bags.values():
		target = _spawn({"bag": _bags.find_key(scene)}, source.global_position)
		if target:
			target.inventory_data = source.inventory_data
	elif scene and Corpse.is_ragdoll(scene):
		var world: Node = get_parent().world
		for id: String in world.entities.objects:
			var npc := world.entities.live_object(id) as CogitoNPC
			if npc:
				var index := npc.health.spawn_on_death.find(scene)
				if index >= 0:
					target = _spawn({"corpse": id, "index": index}, source.global_position)
					break
	if target:
		target.global_transform = source.global_transform
		if target is RigidBody3D and source is RigidBody3D:
			target.linear_velocity = source.linear_velocity
			target.angular_velocity = source.angular_velocity
			target.sleeping = source.sleeping
		var world: Node = get_parent().world
		var target_id: String = world.entities.id_for(target)
		var spec: Dictionary = _live[target_id].spec
		spec.pose = target.global_transform
		world.publish(target_id, spec)
	return target


## Reserve an eligible public quest drop against retained profiles and live world holdings.
func roll_quest_drop(entry: LootDropEntry, reserved: Dictionary) -> LootDropEntry:
	if not get_parent().quests.allows_world_drop(entry):
		return null
	var item := entry.inventory_item
	var count: int = get_parent().inventory.held_count(item) + reserved.get(item.name, 0)
	for node: Node in get_parent().world.entities.objects.values():
		if node.is_queued_for_deletion():
			continue
		if node is CogitoContainer:
			for slot in node.inventory_data.find_slots(item.name):
				count += slot.quantity
		elif node is RigidBody3D:
			var pickup := _pickup(node)
			if pickup and pickup.slot_data and pickup.slot_data.inventory_item.name == item.name:
				count += pickup.slot_data.quantity
	var limit := 1 if item.is_unique else entry.quest_item_total_count
	var amount := mini(limit - count, rng.randi_range(entry.quantity_min, entry.quantity_max))
	if amount <= 0:
		return null
	reserved[item.name] = int(reserved.get(item.name, 0)) + amount
	var rolled := entry.duplicate() as LootDropEntry
	rolled.quantity_min = amount
	rolled.quantity_max = amount
	return rolled


## Roll an independent mutable stack from a server loot table entry.
func roll_stack(entry: LootDropEntry) -> InventorySlotPD:
	var template := InventorySlotPD.new()
	var count := rng.randi_range(entry.quantity_min, entry.quantity_max)
	template.create(entry.inventory_item, 1 if entry.inventory_item.is_unique else count)
	return STOCK.copy_stack(template, template.quantity)


## Fill a bag or a respawning chest without sharing mutable items with the authored table.
func fill_loot(inv: CogitoInventory, entries: Array[LootDropEntry], pad_rows: bool) -> void:
	var rows := maxi(1, ceili(entries.size() / 8.0))
	var width := 8
	if inv.grid:
		for entry in entries:
			var size := entry.inventory_item.item_size
			width = maxi(width, mini(size.x, size.y))
	inv.inventory_size = Vector2i(width, rows)
	inv.inventory_slots.clear()
	inv.inventory_slots.resize(rows * width if inv.grid or pad_rows else entries.size())
	for i in entries.size():
		var stack := roll_stack(entries[i])
		if stack.quantity <= 0:
			continue
		if inv.grid:
			# Expand the generated chest so even a rotated multi-cell prize fits.
			var size := stack.inventory_item.item_size
			while GRID.insert(inv, stack, stack.quantity, false) == 0:
				inv.inventory_size.y += maxi(1, maxi(size.x, size.y))
				inv.inventory_slots.resize(inv.inventory_size.x * inv.inventory_size.y)
		else:
			stack.origin_index = i
			inv.inventory_slots[i] = stack
	inv.first_slot = inv.inventory_slots.front() if not inv.inventory_slots.is_empty() else null
	inv.inventory_updated.emit(inv)


## Bag archetypes must be declared by a LootComponent in the registered level.
func spawn_bag(component: LootComponent, pos: Vector3) -> CogitoContainer:
	var world: Node = get_parent().world
	var key := str(world.entities.root.get_path_to(component))
	if not multiplayer.is_server() or not _bags.has(key):
		return null
	return _spawn({"bag": key}, pos) as CogitoContainer


## Resolve death drops from authored scenes. Only the server mints their runtime IDs.
func spawn_npc_remains(npc: CogitoNPC) -> void:
	var entity: String = get_parent().world.entities.id_for(npc)
	for index in npc.health.spawn_on_death.size():
		var scene := npc.health.spawn_on_death[index]
		if not scene:
			continue
		var stack := STOCK.pickup_template(scene)
		if stack:
			spawn_item(stack, stack.quantity, npc.global_position + Vector3.UP * 0.4)
		elif Corpse.is_ragdoll(scene):
			var spec := {"corpse": entity, "index": index, "basis": npc.global_basis}
			_spawn(spec, npc.global_position + Vector3.UP * 0.4)


func _spawn(spec: Dictionary, pos: Vector3) -> Node3D:
	_serial += 1
	var id := "runtime:%d" % _serial
	spec.pose = Transform3D(spec.get("basis", Basis.IDENTITY), pos)
	var node := _instantiate(id, spec)
	if node:
		get_parent().world.publish(id, spec)
		node.tree_exiting.connect(_despawn.bind(id), CONNECT_ONE_SHOT)
	return node


func _instantiate(id: String, spec: Dictionary) -> Node3D:
	var scene: PackedScene
	var item: InventoryItemPD
	if spec.has("corpse"):
		var npc := get_parent().world.entities.live_object(spec.corpse) as CogitoNPC
		if npc and spec.index >= 0 and spec.index < npc.health.spawn_on_death.size():
			scene = npc.health.spawn_on_death[spec.index]
	elif spec.has("bag"):
		scene = _bags.get(spec.bag)
	else:
		item = STOCK.load_definition(spec.item)
		if item and item.drop_scene:
			scene = load(item.drop_scene)
	if not scene:
		return null
	var instance := Corpse.create(scene) if spec.has("corpse") else scene.instantiate()
	if not instance is Node3D:
		instance.free()
		return null
	var node := instance as Node3D
	var world: Node = get_parent().world
	if item:
		var pickup := _pickup(node)
		if not pickup:
			node.free()
			return null
		var template := InventorySlotPD.new()
		template.inventory_item = item
		pickup.slot_data = STOCK.copy_stack(template, spec.quantity)
		var mutable := pickup.slot_data.inventory_item
		if mutable.rotated != spec.rotated:
			mutable.rotate()
		if mutable is WieldableItemPD:
			mutable.charge_current = spec.charge
			mutable.current_ammo_type = spec.ammo
		node.add_to_group("spawned_loot_items")
	if node is CogitoProjectile:
		# Some authored ammo drops reuse the projectile prefab as their pickup model.
		node.set_meta(&"cogito_item_drop", true)
	node.transform = world.entities.root.global_transform.affine_inverse() * spec.pose
	CogitoPersistentId.restore(node, id)
	world.entities.root.add_child(node)
	world.entities.register_runtime(id, node)
	_live[id] = {"node": node, "spec": spec.duplicate()}
	return node


## True for runtime objects created by this spawner, whose spec pose is global.
func owns(id: String) -> bool:
	return _live.has(id)


## Place an authored death drop that is an inventory pickup as a networked item.
## Returns false for other scenes, which stay local presentation on every peer.
func spawn_death_drop(scene: PackedScene, pos: Vector3) -> bool:
	var stack := STOCK.pickup_template(scene)
	if not stack:
		return false
	if multiplayer.is_server():
		spawn_item(stack, stack.quantity, pos)
	return true


## Release carry ownership and retain one removal record for a destroyed object.
func remove_world_object(node: Node, event: StringName = &"") -> void:
	var world: Node = get_parent().world
	var id: String = world.entities.id_for(node)
	if not multiplayer.is_server() or id.is_empty() or world.is_removed(id):
		return
	if node.has_meta(&"net_carrier"):
		get_parent().carry.release(node.get_meta(&"net_carrier"))
	_live.erase(id)
	world.publish(id, {"removed": true}, event)


func _despawn(id: String) -> void:
	if _live.erase(id) and is_inside_tree():
		get_parent().world.publish(id, {"removed": true})


## Reserve even removed runtime ids when restarting the allocator.
func reserve_id(id: String) -> void:
	_serial = maxi(_serial, id.trim_prefix("runtime:").to_int())


## Apply authored removal/remainder or an authority-issued runtime lifecycle record.
func apply(id: String, state: Dictionary) -> bool:
	var world: Node = get_parent().world
	var node: Node = world.entities.live_object(id)
	if state.get("removed", false):
		if node:
			node.queue_free()
		_live.erase(id)
		return true
	if not node and id.begins_with("runtime:"):
		node = _instantiate(id, state)
		if not node:
			return false
		if multiplayer.is_server():
			node.tree_exiting.connect(_despawn.bind(id), CONNECT_ONE_SHOT)
	if node and _live.has(id):
		_live[id].spec.merge(state, true)
	if node and state.has("quantity"):
		var pickup := _pickup(node)
		if pickup:
			pickup.slot_data = pickup.slot_data.duplicate()
			pickup.slot_data.quantity = state.quantity
	return id.begins_with("runtime:") or state.has("quantity")


## Commit a registered pickup, an in-place consumable use or a backpack upgrade.
func collect(
	component: InteractionComponent, pic: PlayerInteractionComponent, use: bool
) -> Dictionary:
	var node := component.get_parent()
	var world: Node = get_parent().world
	var id: String = world.entities.id_for(node)
	var rejection := _pickup_error(node, id, component)
	if not rejection.is_empty():
		return {"ok": false, "reason": rejection}
	var inv := pic.get_inventory()
	var remaining := 0
	if component is BackpackComponent:
		if not _expand(inv, component.new_inventory_size):
			return {"ok": false, "reason": "Backpack too small"}
	else:
		var pickup := component as PickupComponent
		if component is ExtendedPickupInteraction:
			pickup = component.pickup
		var stack := pickup.slot_data
		var item := stack.inventory_item
		var amount := 0
		if use and (item is AmmoItemPD or item is WieldableItemPD):
			amount = _collect_equipment(pic.player, stack)
			if not amount:
				return {"ok": false, "reason": "Item could not be used"}
		elif not use and item is CurrencyItemPD and item.add_on_pickup:
			amount = _collect_money(pic, item, stack.quantity)
		elif use:
			var reason: String = get_parent().inventory.use_item(pic.player, item)
			if not reason.is_empty():
				return {"ok": false, "reason": reason}
			amount = 1
		else:
			amount = GRID.insert(inv, stack, stack.quantity, true)
		if amount <= 0:
			return {"ok": false, "reason": "Inventory full"}
		remaining = stack.quantity - amount
		pickup.slot_data = stack.duplicate()
		pickup.slot_data.quantity = remaining
	var state: Dictionary = _live[id].spec if _live.has(id) else {}
	state.quantity = remaining
	if not remaining:
		state = {"removed": true}
		_live.erase(id)
	world.publish(id, state.duplicate())
	if not remaining:
		node.queue_free()
	var quests: Node = get_parent().quests
	var previous: String = quests.signal_subject
	quests.signal_subject = pic.player.get_meta(&"net_player_id")
	component.was_interacted_with.emit(component.interaction_text, component.input_map_action)
	if component is ExtendedPickupInteraction and not use:
		var base := component.pickup as PickupComponent
		base.was_interacted_with.emit(base.interaction_text, base.input_map_action)
	quests.signal_subject = previous
	inv.inventory_updated.emit(inv)
	return {"ok": true}


func _pickup_error(node: Node, id: String, component: InteractionComponent) -> String:
	if not multiplayer.is_server() or id.is_empty() or node.is_queued_for_deletion():
		return "Item already taken"
	var pickup := component as PickupComponent
	if component is ExtendedPickupInteraction:
		pickup = component.pickup
	if pickup:
		var item := pickup.slot_data.inventory_item
		if item.is_unique and get_parent().inventory.owns(item):
			return "Unique item already held"
	return ""


func _collect_money(pic: PlayerInteractionComponent, item: CurrencyItemPD, count: int) -> int:
	var wallet: CogitoCurrency = pic.player.player_currencies.get(item.currency_name)
	if not wallet or wallet.is_locked:
		return 0
	var unit := item.currency_change_amount
	if unit > 0:
		count = mini(count, floori((wallet.value_max - wallet.value_current) / unit))
	elif unit < 0:
		count = mini(count, floori(wallet.value_current / -unit))
	if count > 0:
		wallet.value_current += count * unit
		pic.send_hint(item.hint_icon_on_use, item.hint_text_on_use)
	return count


func _expand(inv: CogitoInventory, size: Vector2i) -> bool:
	if size.x < inv.inventory_size.x or size.y < inv.inventory_size.y:
		return false
	var width := inv.inventory_size.x
	var old := inv.inventory_slots.duplicate()
	inv.inventory_size = size
	inv.inventory_slots.resize(size.x * size.y)
	inv.inventory_slots.fill(null)
	var moved := {}
	for i in old.size():
		var index := i % width + floori(float(i) / width) * size.x
		inv.inventory_slots[index] = old[i]
		if old[i] and not moved.has(old[i]):
			old[i].origin_index = index
			moved[old[i]] = true
	return true


func _collect_equipment(actor: CogitoPlayerAdvanced, source: InventorySlotPD) -> int:
	var wield: Variant = actor.get_meta(&"net_wield")
	var item := source.inventory_item
	var count := 1
	if item is AmmoItemPD:
		count = mini(source.quantity, wield.ammo_needed(item))
	elif actor.is_sitting or actor.player_interaction_component.carrying.is_carrying:
		return 0
	elif not get_parent().wield_profile(STOCK.definition(item).resource_path).kind:
		return 0
	var before := {}
	for slot in actor.inventory_data.find_slots(item.name):
		before[slot] = slot.quantity
	if count <= 0 or not GRID.insert(actor.inventory_data, source, count, false):
		return 0
	if item is AmmoItemPD:
		wield.start_reload()
	else:
		var slots := actor.inventory_data.find_slots(item.name)
		for slot in slots:
			if int(before.get(slot, 0)) < slot.quantity:
				if slot != wield.stack:
					wield.equip(slot)
				break
	return count
