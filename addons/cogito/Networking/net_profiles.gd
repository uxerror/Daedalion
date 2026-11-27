extends RefCounted
## Server snapshots of private lives. Cached rows contain no actor or peer references.

const Attributes := preload("net_attributes.gd")
const Ledger := preload("net_quest_ledger.gd")

var retained := {}
var pending := {}


## Install holdings and progression before any party evaluation. Bind private life on admission.
func install(records: Dictionary, players: Node) -> void:
	for id: String in records:
		install_row(id, records[id], players)


## Replace all private caches for one disconnected identity without touching the party.
func install_row(id: String, row: Dictionary, players: Node) -> void:
	pending[id] = row
	players.inventory.restore(id, row.stock)
	players.quests.personal.erase(id)
	if row.has("quests"):
		var ledger := Ledger.new()
		ledger.restore(row.quests)
		players.quests.personal[id] = ledger


## Drop the old identity's disconnected holdings and private progression after publication.
func forget(id: String, players: Node) -> void:
	pending.erase(id)
	retained.erase(id)
	players.inventory.forget_profile(id)
	players.death.forget(id)
	players.quests.personal.erase(id)


## Record the same private data for an active player or just before its bindings are released.
func capture(id: String, actor: CogitoPlayerAdvanced, players: Node) -> Dictionary:
	var row := {
		"id": id,
		"display_name": actor.get_meta(&"profile_name", ""),
		"last_seen": int(Time.get_unix_time_from_system()),
		"level": players.world.entities.level_key,
		"pose": Transform3D(actor.body.basis, actor.position),
		"pitch": actor.head.rotation.x,
		"neck": actor.neck.rotation.y,
		"crouched": actor.is_in_crouching_state(),
		"dead": actor.is_dead,
		"respawn_remaining": players.death.remaining(id),
		"attributes": Attributes.capture(actor),
		"stock": players.inventory.capture(id, actor),
		"progression": actor.saved_quest_progression.duplicate(true),
		"elements": {},
	}
	var transfer: Dictionary = players.travel.pending.get(id, {})
	var zone: String = transfer.get("zone", actor.get_meta(&"travel_spawn_zone", ""))
	if not zone.is_empty():
		row.travel_zone = zone
	if actor.cogito_properties:
		row.elements.properties = actor.cogito_properties.get_element_save_data()
	if actor.actor_elements:
		row.elements.actor = actor.actor_elements.get_element_save_data()
	if players.quests.personal.has(id):
		row.quests = players.quests.personal[id].capture()
	var initial: Dictionary = actor.get_meta(&"profile_initial", {})
	row.unplayed = not initial.is_empty() and _fingerprint(row) == initial
	return row.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)


## Establish evidence of an unused new identity. Old or imported lives are protected.
static func _fingerprint(row: Dictionary) -> Dictionary:
	var data := row.duplicate()
	for key: String in ["display_name", "last_seen", "unplayed"]:
		data.erase(key)
	return data


## Consume the latest life exactly once. Death penalties already happened at the original death.
func attach(id: String, actor: CogitoPlayerAdvanced, players: Node, policy: Resource) -> void:
	if not pending.has(id):
		actor.set_meta(&"profile_initial", _fingerprint(capture(id, actor, players)))
		return
	var row: Dictionary = pending[id]
	pending.erase(id)
	if row.has("travel_zone"):
		actor.set_meta(&"travel_spawn_zone", row.travel_zone)
	Attributes.apply(actor, row.attributes)
	actor.saved_quest_progression = row.get("progression", {}).duplicate(true)
	var start: Transform3D = policy.select(actor, row, players)
	actor.position = start.origin
	actor.body.rotation.y = start.basis.get_euler().y
	actor.head.rotation.x = row.get("pitch", 0.0) if not row.dead else 0.0
	actor.neck.rotation.y = row.get("neck", 0.0) if not row.dead else 0.0
	if row.dead:
		players.death.policy.restore_attributes(actor)
	if actor.cogito_properties:
		actor.cogito_properties.reset_element_state()
		if not row.dead and row.elements.has("properties"):
			actor.cogito_properties.apply_element_save_data(row.elements.properties)
	if actor.actor_elements:
		actor.actor_elements.reset_element_state()
		if not row.dead and row.elements.has("actor"):
			actor.actor_elements.apply_element_save_data(row.elements.actor)
	if not row.dead and row.get("crouched", false):
		actor.try_crouch = true
		actor.state_chart.send_event("crouch")
	actor.reset_physics_interpolation()
	if row.get("unplayed", false):
		actor.set_meta(&"profile_initial", _fingerprint(capture(id, actor, players)))
