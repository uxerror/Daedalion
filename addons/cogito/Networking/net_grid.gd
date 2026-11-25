extends RefCounted
## Synchronous grid transactions used by player, container, vendor and pickup commits.

const STOCK := preload("net_stock.gd")


## Validate a complete footprint on a tentative grid, including the last partial row.
static func fits(inv: CogitoInventory, cells: Array, size: Vector2i, index: int) -> bool:
	if not inv.grid:
		size = Vector2i.ONE
	var width := inv.inventory_size.x
	if index < 0 or width <= 0 or index % width + size.x > width:
		return false
	for y in size.y:
		for x in size.x:
			var cell := index + x + y * width
			if cell >= cells.size() or cells[cell]:
				return false
	return true


static func _place(inv: CogitoInventory, stack: InventorySlotPD, index: int) -> void:
	stack.origin_index = index
	inv.inventory_slots[index] = stack
	inv.add_adjacent_slots(index)


static func _erase(cells: Array, stack: InventorySlotPD) -> void:
	for i in cells.size():
		if cells[i] == stack:
			cells[i] = null


## Remove only the committed quantity. All aliases of an exhausted stack disappear together.
static func spend(inv: CogitoInventory, stack: InventorySlotPD, amount: int) -> void:
	stack.quantity -= amount
	if stack.quantity <= 0:
		_erase(inv.inventory_slots, stack)


## Plan merges and placements before changing any live slot. Return the quantity accepted.
static func insert(inv: CogitoInventory, stack: InventorySlotPD, count: int, partial: bool) -> int:
	var remaining := count
	var limit := (
		maxi(1, stack.inventory_item.stack_size) if stack.inventory_item.is_stackable else 1
	)
	var merges := {}
	for target in inv.inventory_slots:
		if not target or merges.has(target) or not target.can_merge_with(stack):
			continue
		var delta := mini(remaining, limit - target.quantity)
		merges[target] = delta
		remaining -= delta
		if remaining == 0:
			break
	var cells := inv.inventory_slots.duplicate()
	var placements := {}
	while remaining > 0:
		var item := STOCK.copy_stack(stack, mini(remaining, limit))
		var index := _free_index(inv, cells, item)
		if index < 0:
			break
		var size := item.inventory_item.item_size if inv.grid else Vector2i.ONE
		for y in size.y:
			for x in size.x:
				cells[index + x + y * inv.inventory_size.x] = item
		placements[index] = item
		remaining -= item.quantity
	if remaining and not partial:
		return 0
	for target: InventorySlotPD in merges:
		target.quantity += merges[target]
	for index: int in placements:
		_place(inv, placements[index], index)
		inv.picked_up_new_inventory_item.emit(placements[index])
	return count - remaining


static func _free_index(inv: CogitoInventory, cells: Array, item: InventorySlotPD) -> int:
	for turn in 2:
		for i in cells.size():
			if fits(inv, cells, item.inventory_item.item_size, i):
				return i
		var size := item.inventory_item.item_size
		if not inv.grid or size.x == size.y or turn == 1:
			break
		item.inventory_item.rotate()
	return -1


## Move, split, stack or swap at the requested destination, checking both footprints.
static func move(
	src: CogitoInventory,
	stack: InventorySlotPD,
	dst: CogitoInventory,
	index: int,
	count: int,
	rotated: bool
) -> bool:
	var target := dst.inventory_slots[index]
	if target != stack and target and target.can_merge_with(stack):
		if target.quantity + count > target.inventory_item.stack_size:
			return false
		target.quantity += count
		spend(src, stack, count)
		return true
	var full := count == stack.quantity
	var incoming := stack if full else STOCK.copy_stack(stack, count)
	var cells := dst.inventory_slots.duplicate()
	if full and src == dst:
		_erase(cells, stack)
	if target == stack:
		target = null
	if target:
		if not full or src != dst:
			return false
		_erase(cells, target)
	var size := stack.inventory_item.item_size
	if rotated != stack.inventory_item.rotated:
		size = Vector2i(size.y, size.x)
	if not fits(dst, cells, size, index):
		return false
	var origin: int = stack.origin_index
	if target:
		var footprint := size if dst.grid else Vector2i.ONE
		for y in footprint.y:
			for x in footprint.x:
				cells[index + x + y * dst.inventory_size.x] = incoming
		if not fits(src, cells, target.inventory_item.item_size, origin):
			return false
		_erase(dst.inventory_slots, target)
	if full:
		_erase(src.inventory_slots, stack)
	else:
		spend(src, stack, count)
	if rotated != incoming.inventory_item.rotated:
		incoming.inventory_item.rotate()
	_place(dst, incoming, index)
	if target:
		_place(src, target, origin)
	return true


## Consume one of each ingredient only if the recipe result fits after consumption.
static func combine(inv: CogitoInventory, stack: InventorySlotPD, target: InventorySlotPD) -> bool:
	var recipe := stack.inventory_item as CombinableItemPD
	if not recipe or not recipe.resulting_item or not target or target == stack:
		return false
	if target.inventory_item.name != recipe.target_item_combine:
		return false
	var cells := inv.inventory_slots.duplicate()
	var a := stack.quantity
	var b := target.quantity
	spend(inv, stack, 1)
	spend(inv, target, 1)
	var result := recipe.resulting_item
	if insert(inv, result, result.quantity, false) == 0:
		stack.quantity = a
		target.quantity = b
		inv.inventory_slots.assign(cells)
		return false
	return true
