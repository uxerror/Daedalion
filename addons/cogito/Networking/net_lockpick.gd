extends RefCounted
## One attempt on authority. Only the resulting keyhole angle and cues are private view data.

var spot: float
var rotation := 0.0
var tension := false
var _position := 0.0
var _range: float
var _threshold: float
var _health: float
var _max_health: float
var _game: CogitoLockpickGame


## Use the authored minigame settings and the acting avatar's skill.
func begin(component: LockpickInteraction, pic: PlayerInteractionComponent) -> void:
	if not is_instance_valid(component.spawned_lockpick_game):
		component.spawned_lockpick_game = component.lockpick_minigame.instantiate()
	_game = component.spawned_lockpick_game
	spot = snappedf(randf_range(0.0, _game.max_range), 0.1)
	_range = _game.default_sweet_spot_range
	_threshold = 90.0
	_max_health = _game.lockpick_health_max
	if component.attribute_check:
		var attribute := pic.get_attribute(component.attribute_to_check)
		var skill := clampf(attribute.value_current / maxf(attribute.value_max, 0.001), 0, 1)
		if _game.attribute_influences_difficulty:
			_range *= skill
			_threshold -= 10.0 * skill
		if _game.attribute_influences_lockpick_health:
			_max_health *= skill
	_health = _max_health


## Sample the submitted pick position only on the rising tension edge.
func press(angle: int) -> void:
	if not tension:
		_position = snappedf(remap(angle, -900, 900, 0, _game.max_range), 0.1)
		tension = true


## Advance from physics time. Breaking requires a new press before another pick can break.
func advance(delta: float) -> StringName:
	if not tension:
		rotation = move_toward(rotation, 0.0, rad_to_deg(_game.keyhole_rotation_speed) * delta)
		return &""
	var distance := absf(_position - spot)
	var limit := 90.0 * clampf(1.0 - distance / maxf(_range, 0.001), 0.0, 1.0)
	rotation = minf(rotation + rad_to_deg(_game.keyhole_rotation_speed) * delta, limit)
	if rotation >= _threshold - 0.001:
		return &"success"
	if rotation >= limit - 0.01:
		var damage := lerpf(
			_game.lockpick_damage_per_second_min,
			_game.lockpick_damage_per_second_max,
			clampf(distance / 10.0, 0, 1)
		)
		_health -= damage * delta
		if _health <= 0.0:
			_health = _max_health
			tension = false
			rotation = 0.0
			return &"break"
		return &"jiggle"
	return &""


## Resolve exactly one occupied server stack, including private item instances.
static func stack(pic: PlayerInteractionComponent, item: InventoryItemPD) -> InventorySlotPD:
	for slot in pic.get_inventory().inventory_slots:
		if slot and slot.quantity > 0 and pic.matches_item(slot.inventory_item, item):
			return slot
	return null
