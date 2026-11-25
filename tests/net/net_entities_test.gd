extends GdUnitTestSuite

const ACTIONS := preload("res://addons/cogito/Networking/net_actions.gd")
const PLAYER := preload("res://addons/cogito/PackedScenes/cogito_player_advanced.tscn")
const ANIMATION := preload("res://addons/cogito/Networking/net_animation.gd")
const ENTITIES := preload("res://addons/cogito/Networking/net_entities.gd")
const BASIC := preload("res://addons/cogito/Components/Interactions/BasicInteraction.gd")


func test_component_keys_duplicate_ids_and_level_epoch() -> void:
	var root := Node3D.new()
	add_child(auto_free(root))
	var keep := CogitoDoor.new()
	keep.name = "Keep"
	var use := BASIC.new()
	use.name = "Use"
	keep.add_child(use)
	root.add_child(keep)
	var first := CogitoDoor.new()
	var second := CogitoDoor.new()
	root.add_child(first)
	root.add_child(second)
	CogitoPersistentId.restore(first, "duplicate")
	CogitoPersistentId.restore(second, "duplicate")
	CogitoLevel.mark_network_root(root)
	var registry := ENTITIES.new()
	(
		assert_error(func() -> void: registry.bind(root, "vault", 3))
		. is_push_error("Duplicate network entity 'duplicate' in level 'vault'")
	)
	assert_dict(registry.address(use)).is_equal({"entity_id": "Keep", "component_key": "Use"})
	assert_object(registry.resolve("Keep", "Use")).is_same(use)
	assert_object(registry.resolve("Keep", "../Keep/Use")).is_null()
	assert_bool(registry.objects.has("duplicate")).is_false()
	assert_bool(registry.matches("vault", 3)).is_true()
	assert_bool(registry.matches("vault", 2)).is_false()
	assert_bool(registry.matches("other", 3)).is_false()
	root.remove_child(keep)
	assert_object(registry.resolve("Keep", "Use")).is_null()
	keep.free()
	assert_object(registry.live_object("Keep")).is_null()
	CogitoLevel.unmark_network_root(root)


func test_action_ids_survive_prompt_changes_and_distinguish_dual_actions() -> void:
	var use := InteractionComponent.new()
	auto_free(use)
	use.input_map_action = "interact2"
	assert_str(use.get_actions(null)[0].action_id).is_equal("interact2")
	use.interaction_text = "Another language"
	assert_str(use.get_actions(null)[0].action_id).is_equal("interact2")
	var dual := DualInteraction.new()
	auto_free(dual)
	var choices := dual.get_actions(null)
	assert_str(choices[0].action_id).is_equal("press")
	assert_str(choices[1].action_id).is_equal("hold")


func test_replica_animation_keeps_pose_tracks_and_restores_authored_library() -> void:
	var player := AnimationPlayer.new()
	add_child(auto_free(player))
	var clip := Animation.new()
	clip.add_track(Animation.TYPE_POSITION_3D)
	clip.add_track(Animation.TYPE_AUDIO)
	clip.add_track(Animation.TYPE_METHOD)
	var library := AnimationLibrary.new()
	library.add_animation(&"open", clip)
	player.add_animation_library(&"", library)
	var presentation := ANIMATION.new()
	presentation.bind(player)
	var copy := player.get_animation(&"open")
	assert_int(copy.get_track_count()).is_equal(1)
	assert_int(copy.track_get_type(0)).is_equal(Animation.TYPE_POSITION_3D)
	assert_bool(player.is_blocking_signals()).is_true()
	presentation.restore()
	assert_object(player.get_animation(&"open")).is_same(clip)
	assert_int(clip.get_track_count()).is_equal(3)
	assert_bool(player.is_blocking_signals()).is_false()


func test_hud_protocol_diagnostics() -> void:
	for reason in ["Stale revision", "Old request", "No matching hold", "Hold too short"]:
		assert_str(ACTIONS.hud_reason(reason)).is_empty()
	for reason in ["Wrong level epoch", "Invalid payload", "Unknown entity or component"]:
		assert_str(ACTIONS.hud_reason(reason)).is_equal("Unavailable")
	assert_str(ACTIONS.hud_reason("In use")).is_equal("In use")


func test_offline_authored_devices_keep_local_input_links_and_save_fields() -> void:
	var previous := CogitoSceneManager.get_player()
	var mouse_mode := Input.mouse_mode
	var level: Node3D = preload("process_arena.tscn").instantiate()
	add_child(level)
	var actor: CogitoPlayerAdvanced = PLAYER.instantiate()
	level.add_child(actor)
	var pic := actor.player_interaction_component
	assert_object(pic.network_interactions).is_null()
	assert_int(CogitoNet.get_child_count()).is_zero()
	var spinner: SpinnerInteraction = level.get_node("Spinner/SpinnerInteraction")
	spinner.interact(pic)
	spinner.spin_accumulator = spinner.rotation_speed * 2.0
	spinner.apply_spin()
	assert_float(spinner.spinner_value).is_equal(2.0)
	spinner.force_exit()
	assert_bool(InputRouter.is_input_active(actor)).is_true()
	var wheel: CogitoTurnwheel = level.get_node("Wheel")
	var hold: HoldInteraction = wheel.get_node("Hold")
	hold.is_being_held.emit(0.1, 0.1)
	hold.perform_hold_action(pic)
	assert_bool(wheel.save().has_been_turned).is_true()
	assert_bool(level.get_node("WheelDoor").is_open).is_true()
	var pick: LockpickInteraction = level.get_node("PickDoor/Pick")
	var item := InventorySlotPD.new()
	item.inventory_item = pick.required_lockpick_item
	item.quantity = 1
	actor.inventory_data.inventory_slots[0] = item
	pick.interact(pic)
	assert_bool(pick.lockpick_ui.visible).is_true()
	pick.spawned_lockpick_game.unlock_animation = ""
	pick.spawned_lockpick_game.unlock_lock()
	assert_bool(level.get_node("PickDoor").is_locked).is_false()
	assert_bool(pick.lockpick_ui.visible).is_false()
	var trigger: CogitoCutsceneTrigger = level.get_node("Cutscene")
	trigger._on_body_entered(actor)
	assert_bool(trigger.cutscene_animation_player.is_playing()).is_true()
	assert_bool(trigger.save().has_been_triggered).is_false()
	trigger.finish_cutscene()
	assert_bool(trigger.save().has_been_triggered).is_true()
	assert_bool(InputRouter.is_input_active(actor)).is_true()
	level.free()
	CogitoSceneManager.register_player(previous)
	Input.mouse_mode = mouse_mode
