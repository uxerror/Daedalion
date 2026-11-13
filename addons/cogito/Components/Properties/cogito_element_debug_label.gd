extends Label3D
## Debug readout of an object's elemental state, shown as a billboard above it: active states
## (FIRE, WET, SHOCK, CHILL, FROZEN, POISON), element buildup levels and health.
## Also works on a CogitoElementArea (element, ON/OFF, ELECTRIC).
## Updates a few times per second with a Timer, so it costs nothing while the scene has none.
class_name CogitoElementDebugLabel

## Node to watch: an object with CogitoProperties, a CogitoProperties node or a CogitoElementArea.
## Defaults to the parent.
@export var target : Node
## Shows non-zero element buildup levels below the states.
@export var show_levels : bool = true
## Seconds between updates.
@export var update_interval : float = 0.2

var _properties : CogitoProperties
var _area : CogitoElementArea
var _health : CogitoHealthAttribute
var _timer : Timer


func _init() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	font_size = 20
	pixel_size = 0.004
	outline_size = 6
	modulate = Color(1, 1, 0.85)


func _ready() -> void:
	if !target:
		target = get_parent()
	_find_target()
	_timer = Timer.new()
	_timer.wait_time = maxf(update_interval, 0.05)
	_timer.autostart = true
	_timer.timeout.connect(update_text)
	add_child(_timer)
	update_text()


func _find_target() -> void:
	_properties = null
	_area = null
	_health = null
	if target is CogitoProperties:
		_properties = target
	elif target is CogitoElementArea:
		_area = target
	else:
		_properties = CogitoProperties.get_properties_of(target)
		if !_properties and is_instance_valid(target):
			for child in target.get_children():
				if child is CogitoProperties:
					_properties = child
					break
	var owner_node : Node = _properties.get_parent() if _properties else target
	if is_instance_valid(owner_node) and !(owner_node is CogitoElementArea):
		for child in owner_node.get_children():
			if child is CogitoHealthAttribute:
				_health = child
				break


## Refreshes the text. Called by the timer.
func update_text() -> void:
	if _area:
		text = _area_text()
	elif is_instance_valid(_properties):
		text = _properties_text()
	else:
		text = ""


func _area_text() -> String:
	var element_name : String = CogitoProperties.Element.keys()[_area.element]
	var line := element_name + " " + ("ON" if _area.enabled else "OFF")
	if _area.is_electric:
		line += " ELECTRIC"
	return line


func _properties_text() -> String:
	var p := _properties
	var states : PackedStringArray = []
	if p.is_on_fire: states.append("FIRE")
	if p.is_wet: states.append("WET")
	if p.is_electric: states.append("SHOCK")
	if p.is_chilled: states.append("CHILL")
	if p.is_frozen: states.append("FROZEN")
	if p.is_poisoned: states.append("POISON")
	var lines : PackedStringArray = []
	if !states.is_empty():
		lines.append(" ".join(states))
	if show_levels:
		var levels : PackedStringArray = []
		for element in p.element_levels:
			var level : float = p.element_levels[element]
			if level > 0.0:
				levels.append(CogitoProperties.Element.keys()[element].left(4) + " " + str(snappedf(level, 0.1)))
		if !levels.is_empty():
			lines.append(" ".join(levels))
	if is_instance_valid(_health):
		lines.append("HP " + str(snappedf(_health.value_current, 0.1)) + "/" + str(snappedf(_health.value_max, 0.1)))
	return "\n".join(lines)
