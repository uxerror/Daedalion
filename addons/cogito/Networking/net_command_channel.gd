extends RefCounted
## Four length-prefixed MP1a commands, oldest first. No actor ID or position on this channel.

const REDUNDANCY := 4
const MAX_EDGES := 32
const GENERATION_BYTES := 4
const MAX_FRAME := CogitoPlayerCommand.HEADER_SIZE + MAX_EDGES + GENERATION_BYTES
const ACTION := CogitoPlayerCommand.Action
const MOVEMENT_MASK := (1 << (ACTION.FREE_LOOK + 1)) - 1
const TRIGGER_MASK := (1 << ACTION.PRIMARY) | (1 << ACTION.SECONDARY)
const WIELD_MASK := TRIGGER_MASK | (1 << ACTION.RELOAD) | (1 << ACTION.CHANGE_AMMO)
const WIRE_MASK := MOVEMENT_MASK | WIELD_MASK

var _history: Array[PackedByteArray] = []


## Discard pre-teleport or previous-incarnation commands before changing revision.
func clear() -> void:
	_history.clear()


## Remembers this tick even when the caller drops the resulting datagram.
func packet(command: CogitoPlayerCommand) -> PackedByteArray:
	var frame := command.encode().slice(0, CogitoPlayerCommand.HEADER_SIZE)
	var flags := CogitoPlayerCommand.TOGGLE_CROUCH | CogitoPlayerCommand.SUPPRESSED
	frame.encode_u32(24, frame.decode_u32(24) & (WIRE_MASK | flags))
	frame.encode_float(12, wrapf(command.yaw, -PI, PI))
	frame.append_array(_wire_edges(command.edges))
	var end := frame.size()
	frame.resize(end + GENERATION_BYTES)
	frame.encode_u32(end, command.wield_generation)
	_history.append(frame)
	if _history.size() > REDUNDANCY:
		_history.pop_front()
	var data := PackedByteArray()
	for item in _history:
		data.append(item.size())
		data.append_array(item)
	return data


## Rejects malformed packets atomically and limits wire input to movement and wield actions.
static func decode(data: PackedByteArray, driving := false) -> Array[CogitoPlayerCommand]:
	var result: Array[CogitoPlayerCommand] = []
	if data.size() > REDUNDANCY * (MAX_FRAME + 1):
		return []
	var offset := 0
	while offset < data.size():
		var size := int(data[offset])
		offset += 1
		if size < CogitoPlayerCommand.HEADER_SIZE + GENERATION_BYTES or size > MAX_FRAME:
			return []
		if offset + size > data.size() or result.size() == REDUNDANCY:
			return []
		var end := offset + size - GENERATION_BYTES
		if driving:
			var axes := Vector2(data.decode_float(offset + 4), data.decode_float(offset + 8))
			if not axes.is_finite() or axes.length_squared() > 1.00001:
				return []
		var command := CogitoPlayerCommand.decode(data.slice(offset, end))
		if not command:
			return []
		command.wield_generation = data.decode_u32(end)
		if _invalid_wield_aim(command):
			return []
		command.yaw = wrapf(command.yaw, -PI, PI)
		command.pitch = clampf(command.pitch, -PI / 2, PI / 2)
		command.neck_yaw = clampf(command.neck_yaw, -PI, PI)
		command.held &= WIRE_MASK
		command.edges = _wire_edges(command.edges)
		result.append(command)
		offset += size
	return result


static func _wire_edges(edges: PackedByteArray) -> PackedByteArray:
	var filtered := PackedByteArray()
	for edge in edges:
		if WIRE_MASK & (1 << (edge & ~CogitoPlayerCommand.RELEASE)):
			filtered.append(edge)
			if filtered.size() == MAX_EDGES:
				break
	return filtered


static func _invalid_wield_aim(command: CogitoPlayerCommand) -> bool:
	# Allow for the nearest float32 representation of pi at the wire boundary.
	if absf(command.yaw) <= PI + 1e-6 and absf(command.pitch) <= PI / 2 + 1e-6:
		if absf(command.neck_yaw) <= PI + 1e-6:
			return false
	if command.held & WIELD_MASK:
		return true
	for edge in command.edges:
		if WIELD_MASK & (1 << (edge & ~CogitoPlayerCommand.RELEASE)):
			return true
	return false
