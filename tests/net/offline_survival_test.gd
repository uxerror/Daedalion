extends GdUnitTestSuite

const Player := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")

var _level: Node3D
var _previous: Node
var _old_player: CogitoPlayer
var _mouse_mode: Input.MouseMode


func before_test() -> void:
	_previous = get_tree().current_scene
	_old_player = CogitoSceneManager.get_player()
	_mouse_mode = Input.mouse_mode
	_level = preload("res://tests/player/movement_level.tscn").instantiate()
	get_tree().root.add_child(_level)
	get_tree().current_scene = _level


func after_test() -> void:
	get_tree().current_scene = _previous
	_level.free()
	CogitoSceneManager.register_player(_old_player)
	Input.mouse_mode = _mouse_mode


func test_local_regen_hazard_and_reload_screen() -> void:
	var actor: CogitoPlayerAdvanced = Player.instantiate()
	_level.add_child(actor)
	await get_tree().process_frame
	var zone := preload("res://addons/cogito/Scripts/hazard_zone.gd").new()
	_level.add_child(zone)
	zone.player_attribute = "health"
	zone._on_body_entered(actor)
	zone._process(1.0)
	assert_float(actor.player_attributes.health.value_current).is_equal(78.0)
	zone._on_body_exited(actor)
	zone._process(1.0)
	assert_float(actor.player_attributes.health.value_current).is_equal(78.0)
	var stamina := actor.stamina_attribute as CogitoStaminaAttribute
	stamina.value_current = 10
	stamina.is_regenerating = true
	stamina._process(0.5)
	assert_float(stamina.value_current).is_greater(10.0)
	actor.decrease_attribute("health", 100.0)
	var screen := actor.player_hud.get_node("DeathScreen") as CogitoDeathScreen
	assert_bool(actor.is_dead).is_true()
	assert_bool(screen.visible).is_true()
	assert_str(screen.load_button.text).is_equal("BTN_Reload")
	assert_bool(get_tree().paused).is_true()
	assert_int(CogitoNet.get_child_count(true)).is_zero()
