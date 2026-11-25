extends GdUnitTestSuite
## NPC listener bookkeeping must unbind cleanly when a session closes.

const LISTENERS := preload("res://addons/cogito/Networking/net_npc_listeners.gd")
const NPC := preload("res://addons/cogito/CogitoNPC/cogito_npc.tscn")


func test_clear_unbinds_tracked_npcs() -> void:
	var listeners: Node = auto_free(LISTENERS.new())
	var kept: CogitoNPC = auto_free(NPC.instantiate())
	var left: CogitoNPC = auto_free(NPC.instantiate())
	var connections_before := kept.tree_exiting.get_connections().size()
	var other: CogitoNPC = auto_free(NPC.instantiate())
	listeners.track(kept)
	listeners.track(left)
	listeners.track(other)
	left.tree_exiting.emit()
	assert_array(listeners.tracked).contains_exactly([kept, other])
	listeners.clear()
	assert_array(listeners.tracked).is_empty()
	assert_int(kept.tree_exiting.get_connections().size()).is_equal(connections_before)
	assert_int(other.tree_exiting.get_connections().size()).is_equal(connections_before)
	listeners.clear()
