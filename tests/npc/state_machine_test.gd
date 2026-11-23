extends GdUnitTestSuite

const MACHINE := preload("res://addons/cogito/CogitoNPC/npc_states/npc_state_machine.gd")


class AsyncState:
	extends Node
	var entries := 0

	func _state_enter() -> void:
		await get_tree().process_frame
		entries += 1


func test_await_goto_current_state_waits_for_entry() -> void:
	var machine: MACHINE = auto_free(MACHINE.new())
	var state := AsyncState.new()
	state.name = "Idle"
	machine.host = ^"."
	machine.add_child(state)
	add_child(machine)
	await machine.goto("Idle")
	assert_int(state.entries).is_equal(1)
	await machine.goto("Idle")
	assert_int(state.entries).is_equal(2)
