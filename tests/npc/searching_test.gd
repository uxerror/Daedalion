extends GdUnitTestSuite

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const SEARCHING := ^"StateChart/Root/BehaviourState/Searching/SearchingState"


func test_free_before_first_search() -> void:
	var initial_count := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var npc: CogitoNPC = FIXTURES.NPC.instantiate()
	npc.get_node(SEARCHING).show_search_points = true
	add_child(npc)
	npc.free()
	var final_count := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	assert_int(final_count).is_equal(initial_count)


func test_search_state_reenters_tree_without_duplicating_children() -> void:
	var npc: CogitoNPC = auto_free(FIXTURES.NPC.instantiate())
	var state := npc.get_node(SEARCHING)
	state.show_search_points = true
	add_child(npc)
	var children := state.get_children()
	var parent := state.get_parent()
	parent.remove_child(state)
	parent.add_child(state)
	assert_array(state.get_children()).contains_exactly(children)
