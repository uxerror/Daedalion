extends StateProcessor
## Panic: a burning NPC drops what it was doing and runs around at sprint speed until the fire is out.
## CogitoNPC sends "panic" when its CogitoProperties ignite and "calm_down" when the fire goes out.
## The state has no transitions for detection events, so the NPC doesn't chase or attack while panicking.

## Radius in meters around the NPC in which run targets are picked.
@export var panic_radius : float = 6.0
## Seconds before a new run target is picked. A new one is also picked when the target is reached.
@export var panic_repath_time : float = 1.5
## Distance in meters at which a run target counts as reached.
@export var arrive_distance : float = 0.6
## Tries to find a run target on the navigation mesh before taking the last one.
const TARGET_TRIES := 4

var target_position : Vector3 = Vector3.ZERO
var _repath_left : float = 0.0


func _on_panic_state_entered() -> void:
	super.enter_state()
	npc.move_speed = npc.sprint_speed
	state_chart.send_event("ubody_neutral")
	state_chart.send_event("body_run")
	pick_target()


func _on_panic_state_exited() -> void:
	super.exit_state()
	npc.move_speed = npc.walk_speed
	state_chart.send_event("body_walk")


func _on_panic_state_physics_processing(delta: float) -> void:
	_repath_left -= delta
	var to_target := target_position - npc.global_position
	to_target.y = 0.0
	if _repath_left <= 0.0 or to_target.length() <= arrive_distance:
		pick_target()

	if _has_navigation():
		npc.move_npc_to_next_position(delta)
	else:
		npc.move_npc_towards(target_position, delta)


## Picks a random point within panic_radius, on the navigation mesh if there is one.
func pick_target() -> void:
	_repath_left = panic_repath_time
	var origin := npc.global_position
	var map := npc.nav_agent.get_navigation_map()
	var use_navigation := _has_navigation()
	var candidate := origin
	for i in TARGET_TRIES:
		var angle := randf() * TAU
		var distance := randf_range(panic_radius * 0.4, panic_radius)
		candidate = origin + Vector3(cos(angle), 0.0, sin(angle)) * distance
		if use_navigation:
			candidate = NavigationServer3D.map_get_closest_point(map, candidate)
		var flat := candidate - origin
		flat.y = 0.0
		if flat.length() > arrive_distance * 2.0:
			break
	target_position = candidate
	npc.nav_agent.target_position = candidate


func _has_navigation() -> bool:
	var map := npc.nav_agent.get_navigation_map()
	return map.is_valid() and NavigationServer3D.map_get_regions(map).size() > 0
