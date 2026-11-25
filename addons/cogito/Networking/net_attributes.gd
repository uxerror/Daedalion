extends RefCounted
## Per-avatar change tracking. Private rows are addressed to the owner on spawn channel 0.

const INTERVAL_MSEC := 100

var _sent := {}
var _next := {}


## Capture exact wire values, including attributes excluded from disk saves.
static func capture(actor: CogitoPlayer) -> Dictionary:
	var values := {}
	for attr: CogitoAttribute in actor.player_attributes.values():
		values[attr.attribute_name] = PackedFloat64Array([attr.value_current, attr.value_max])
	return values


## Silent baseline or sparse update. Only authored attributes can receive a value.
static func apply(actor: CogitoPlayer, values: Dictionary) -> void:
	for key: String in values:
		var attr: CogitoAttribute = actor.player_attributes.get(key)
		if attr:
			attr.apply_replica_value(values[key][0], values[key][1])


## Coalesce each meter independently. A health loss bypasses its ordinary rate limit.
func changes(actor: CogitoPlayer, now: int, hit := false) -> Dictionary:
	var delta := {}
	for attr: CogitoAttribute in actor.player_attributes.values():
		var key := attr.attribute_name
		var previous: PackedFloat64Array = _sent.get(key, PackedFloat64Array())
		if previous.size() == 2:
			if previous[0] == attr.value_current and previous[1] == attr.value_max:
				continue
			# Batch fractional environmental drains. Publish a full point of damage or death now.
			var urgent := (
				key == "health"
				and (hit or attr.value_current == 0 or previous[0] - attr.value_current >= 1.0)
			)
			if not urgent and now < int(_next[key]):
				continue
		var pair := PackedFloat64Array([attr.value_current, attr.value_max])
		delta[key] = pair
		_sent[key] = pair
		_next[key] = now + INTERVAL_MSEC
	return delta


## Public presentation exposes only normalized health and the death state.
static func health_fraction(actor: CogitoPlayer) -> float:
	var health: CogitoAttribute = actor.player_attributes.get("health")
	if health and health.value_max > 0:
		return clampf(health.value_current / health.value_max, 0, 1)
	return 0.0
