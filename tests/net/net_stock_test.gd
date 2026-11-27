extends GdUnitTestSuite
## Item definitions embedded in pickup scenes must survive the inventory projection.

const STOCK := preload("res://addons/cogito/Networking/net_stock.gd")
const PICKUP := "res://addons/cogito/PackedScenes/Pickups/pickup_laser_rifle.tscn"


func _inventory() -> CogitoInventory:
	var inventory := CogitoInventory.new()
	inventory.grid = false
	inventory.inventory_slots.resize(4)
	return inventory


func test_scene_embedded_definition_resolves() -> void:
	var item := STOCK.pickup_template(load(PICKUP) as PackedScene).inventory_item
	assert_str(item.resource_path).contains("::")
	assert_object(STOCK.load_definition(item.resource_path)).is_same(item)
	assert_object(STOCK.load_definition("res://missing_item.tres")).is_null()
	assert_object(STOCK.load_definition("res://missing_pickup.tscn::Resource_x")).is_null()


# Exported builds regenerate sub-resource ids, so the id an editor-built world saved differs
# from the one an exported server loads (and vice versa for its peers).
func test_scene_embedded_definition_ignores_repacked_id() -> void:
	var item := STOCK.pickup_template(load(PICKUP) as PackedScene).inventory_item
	assert_object(STOCK.load_definition(PICKUP + "::Resource_exported")).is_same(item)
	var other := "res://addons/cogito/EasyMenus/Scenes/MultiplayerRoster.tscn"
	assert_object(STOCK.load_definition(other + "::Resource_x")).is_null()


func test_projection_round_trips_scene_embedded_item() -> void:
	var template := STOCK.pickup_template(load(PICKUP) as PackedScene)
	var server := STOCK.new()
	server.data = _inventory()
	server.data.inventory_slots[1] = STOCK.copy_stack(template, 1)
	var fields := server.refresh()
	var client := STOCK.new()
	client.data = _inventory()
	client.apply(fields, server.revision, true)
	var stack := client.data.inventory_slots[1]
	assert_object(stack).is_not_null()
	assert_str(stack.inventory_item.name).is_equal(template.inventory_item.name)
	assert_object(STOCK.definition(stack.inventory_item)).is_same(template.inventory_item)
