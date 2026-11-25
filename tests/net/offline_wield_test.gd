extends GdUnitTestSuite
## Exercise the original inventory and animation callbacks without starting a session.

const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const LEVEL := preload("res://tests/player/movement_level.tscn")

var _actor: CogitoPlayerAdvanced
var _level: Node3D
var _previous: Node
var _previous_player: CogitoPlayer
var _mouse: Input.MouseMode


func before_test() -> void:
	_previous = get_tree().current_scene
	_previous_player = CogitoSceneManager.get_player()
	_mouse = Input.mouse_mode
	_level = LEVEL.instantiate()
	get_tree().root.add_child(_level)
	get_tree().current_scene = _level
	_actor = PLAYER.instantiate()
	_actor.position = Vector3.UP
	_level.add_child(_actor)
	await get_tree().process_frame


func after_test() -> void:
	get_tree().current_scene = _previous
	InputRouter.remove(_actor.on_input)
	_level.free()
	CogitoSceneManager.register_player(_previous_player)
	Input.mouse_mode = _mouse


func test_original_inventory_and_authored_actions(
	asset: String,
	_test_parameters := [
		["Flashlight"], ["LaserRifle"], ["Pickaxe"], ["Pistol"], ["Dart"], ["HealthExtension"]
	]
) -> void:
	var path := "res://addons/cogito/InventoryPD/Items/Cogito_%s.tres" % asset
	var item := (load(path) as WieldableItemPD).duplicate() as WieldableItemPD
	var slot := InventorySlotPD.new()
	slot.create(item, 2 if asset == "Dart" else 1)
	slot.origin_index = 0
	_actor.inventory_data.inventory_slots.fill(null)
	_actor.inventory_data.inventory_slots[0] = slot
	_actor.inventory_data.add_adjacent_slots(0)
	var hp: CogitoAttribute = _actor.player_attributes.health
	var maximum := hp.value_max
	var handler := _actor.player_interaction_component.wieldables
	_actor.inventory_data.use_slot_data(0)
	var model := handler.equipped_wieldable_node
	assert_object(model).is_not_null()
	assert_object(model.item_reference).is_same(item)
	assert_bool(_actor.has_meta(&"net_wield")).is_false()
	assert_int(CogitoNet.get_child_count()).is_zero()
	var equip_time := model.animation_player.current_animation_length
	await get_tree().create_timer(equip_time + 0.12).timeout
	if asset == "HealthExtension":
		assert_float(hp.value_max).is_equal(maximum + 50)
		assert_int(slot.quantity).is_zero()
		return
	var charge := item.charge_current
	var stamina := _actor.stamina_attribute.value_current
	handler.primary_action_held = true
	handler.attempt_action_primary(false)
	if asset == "LaserRifle":
		model.set_physics_process(false)
		model.call("_physics_process", 0.016)
	handler.primary_action_held = false
	handler.attempt_action_primary(true)
	match asset:
		"Flashlight":
			var duration := model.animation_player.current_animation_length + 0.2
			await get_tree().create_timer(duration).timeout
			assert_bool(model.get("is_on")).is_true()
		"LaserRifle", "Pistol":
			assert_float(item.charge_current).is_equal(charge - 1)
		"Pickaxe":
			assert_float(_actor.stamina_attribute.value_current).is_less(stamina)
		"Dart":
			assert_int(slot.quantity).is_equal(1)
			assert_int(_level.find_children("*", "CogitoProjectile", true, false).size()).is_equal(
				1
			)
