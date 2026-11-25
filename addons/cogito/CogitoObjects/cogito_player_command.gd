class_name CogitoPlayerCommand
extends RefCounted
## One actor's intent for one physics tick. Angles are absolute local rotations in radians.

## Stable byte IDs in the codec. The high bit of an edge denotes release.
enum Action {
	LEFT,
	RIGHT,
	FORWARD,
	BACK,
	JUMP,
	CROUCH,
	SPRINT,
	FREE_LOOK,
	INTERACT,
	INTERACT2,
	PRIMARY,
	SECONDARY,
	CHANGE_AMMO,
	RELOAD,
	MENU,
	INVENTORY,
	DROP,
	SLOT1,
	SLOT2,
	SLOT3,
	SLOT4,
	PREVIOUS,
	NEXT,
	WHEEL,
	CONFIRM,
}

const ACTIONS: Array[StringName] = [
	&"left",
	&"right",
	&"forward",
	&"back",
	&"jump",
	&"crouch",
	&"sprint",
	&"free_look",
	&"interact",
	&"interact2",
	&"action_primary",
	&"action_secondary",
	&"change_ammo_type",
	&"reload",
	&"menu",
	&"inventory",
	&"inventory_drop_item",
	&"quickslot_1",
	&"quickslot_2",
	&"quickslot_3",
	&"quickslot_4",
	&"quickslot_prev_wieldable",
	&"quickslot_next_wieldable",
	&"quickslot_wheel",
	&"ui_accept",
]
const RELEASE := 0x80
const HEADER_SIZE := 28
const TOGGLE_CROUCH := 1 << 30
const SUPPRESSED := 1 << 31

## Increasing sequence for this actor. Encoded as an unsigned 32-bit integer.
var sequence: int
## Local horizontal axes. Forward is negative Y.
var move: Vector2:
	set(value):
		move = value.limit_length()
## Body yaw around its parent Y axis.
var yaw: float
## Head pitch around its local X axis.
var pitch: float
## Neck yaw relative to the body during free look or seated look.
var neck_yaw: float
## False during menu takeover. Active air control retains momentum when axes return to zero.
var has_control: bool = true
## Interpret crouch presses as toggles for this actor.
var toggle_crouch: bool
## Online equip generation acknowledged by the owner. Encoded only by the network channel.
var wield_generation: int
## Down state at the sampling boundary, one bit per Action.
var held: int
## Ordered presses and releases preserve two taps or a press/release within one tick.
var edges := PackedByteArray()


## Whether the action is down at the sampling boundary.
func is_held(action: Action) -> bool:
	return (held & (1 << action)) != 0


## Append one transition in routed event order.
func add_edge(action: Action, pressed: bool = true) -> void:
	edges.append(action if pressed else action | RELEASE)


## Little endian u32 sequence, two float axes, three float angles, u32 held, then byte edges.
func encode() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(HEADER_SIZE)
	data.encode_u32(0, sequence)
	data.encode_float(4, move.x)
	data.encode_float(8, move.y)
	data.encode_float(12, yaw)
	data.encode_float(16, pitch)
	data.encode_float(20, neck_yaw)
	var buttons := held | (TOGGLE_CROUCH if toggle_crouch else 0)
	data.encode_u32(24, buttons if has_control else buttons | SUPPRESSED)
	data.append_array(edges)
	return data


## Returns null for a truncated header, unknown action or non-finite input.
static func decode(data: PackedByteArray) -> CogitoPlayerCommand:
	if data.size() < HEADER_SIZE:
		return null
	var axes := Vector2(data.decode_float(4), data.decode_float(8))
	var angles := Vector3(data.decode_float(12), data.decode_float(16), data.decode_float(20))
	if not axes.is_finite() or not angles.is_finite():
		return null
	var command := CogitoPlayerCommand.new()
	command.sequence = data.decode_u32(0)
	command.move = axes
	command.yaw = angles.x
	command.pitch = angles.y
	command.neck_yaw = angles.z
	var buttons := data.decode_u32(24)
	command.has_control = (buttons & SUPPRESSED) == 0
	command.toggle_crouch = (buttons & TOGGLE_CROUCH) != 0
	command.held = buttons & ~(SUPPRESSED | TOGGLE_CROUCH)
	command.edges = data.slice(HEADER_SIZE)
	if not command.has_control and (command.held or command.move or not command.edges.is_empty()):
		return null
	if command.held >> ACTIONS.size():
		return null
	for edge in command.edges:
		if (edge & ~RELEASE) >= ACTIONS.size():
			return null
	return command
