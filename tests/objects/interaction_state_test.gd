extends "res://tests/saves/slot_fixture.gd"
## The player's no_interaction_states (rolling, free fall) block interactions.

var _player: CogitoPlayerAdvanced
var _component: InteractionComponent
var _calls := 0


func before_test() -> void:
	super()
	_player = (load(LEVEL) as PackedScene).instantiate()
	_player.inventory_data = _player.inventory_data.duplicate(true)
	get_tree().current_scene.add_child(_player)
	_component = InteractionComponent.new()
	_component.input_map_action = "interact"
	get_tree().current_scene.add_child(_component)
	_calls = 0
	await get_tree().process_frame


func _action() -> CogitoInteractionAction:
	return CogitoInteractionAction.new("Use", _component, func(_pic: Variant) -> void: _calls += 1)


func test_action_runs_in_an_interaction_state() -> void:
	_player.is_in_interaction_state = true
	await _player.player_interaction_component.perform_action(_action())
	assert_int(_calls).is_equal(1)


func test_no_interaction_state_blocks_action() -> void:
	_player.is_in_interaction_state = false
	await _player.player_interaction_component.perform_action(_action())
	assert_int(_calls).is_zero()


func test_no_interaction_state_blocks_input_interaction() -> void:
	var pic := _player.player_interaction_component
	var blocked: bool = pic._is_interaction_blocked(_component)
	assert_bool(blocked).is_false()
	_player.is_in_interaction_state = false
	blocked = pic._is_interaction_blocked(_component)
	assert_bool(blocked).is_true()


func test_in_air_blocks_only_components_that_ask_for_it() -> void:
	var pic := _player.player_interaction_component
	assert_bool(_player.is_on_floor()).is_false()
	assert_bool(pic._is_interaction_blocked(_component)).is_false()
	_component.disable_interaction_in_air = true
	assert_bool(pic._is_interaction_blocked(_component)).is_true()


func test_offline_action_uses_original_callable_without_network_binding() -> void:
	assert_bool(CogitoNet.is_online()).is_false()
	var pic := _player.player_interaction_component
	assert_object(pic.network_interactions).is_null()
	var action := _action()
	action.action_id = &"third_party_context"
	await pic.perform_action(action)
	assert_int(_calls).is_equal(1)
	assert_int(CogitoNet.get_child_count()).is_zero()
