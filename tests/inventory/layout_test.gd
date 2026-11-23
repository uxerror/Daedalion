extends GdUnitTestSuite


func test_loot_fits_in_complete_rows(
	count: int, rows: int, _test_parameters := [[8, 1], [9, 2], [0, 1]]
) -> void:
	var items: Array[LootDropEntry] = []
	var entry := LootDropEntry.new()
	entry.inventory_item = InventoryItemPD.new()
	for i in count:
		items.append(entry)

	var inventory := CogitoInventory.new()
	var container: LootableContainer = auto_free(LootableContainer.new())
	container._populate_the_container(inventory, items)
	assert_int(inventory.inventory_size.y).is_equal(rows)
	assert_int(inventory.inventory_slots.size()).is_equal(8 * rows)

	var bag_inventory := CogitoInventory.new()
	var loot: LootComponent = auto_free(LootComponent.new())
	loot._populate_the_container(bag_inventory, items)
	assert_int(bag_inventory.inventory_size.y).is_equal(rows)
	assert_int(bag_inventory.inventory_slots.size()).is_equal(count)


func test_regions_include_last_icon_row_and_column() -> void:
	var texture := GradientTexture2D.new()
	texture.gradient = Gradient.new()
	texture.width = 5
	texture.height = 7
	var item := InventoryItemPD.new()
	item.icon = texture
	item.item_size = Vector2i(2, 3)
	var bottom_right := item.get_region(1, 2)
	assert_vector(bottom_right.get_size()).is_equal(Vector2i(3, 3))
	assert_that(bottom_right.get_pixel(2, 2)).is_equal(texture.get_image().get_pixel(4, 6))
