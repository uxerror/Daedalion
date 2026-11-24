extends GdUnitTestSuite

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
