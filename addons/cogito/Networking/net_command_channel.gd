extends RefCounted
## Four length-prefixed MP1a commands, oldest first. No actor ID or position on this channel.

const REDUNDANCY := 4
const MAX_EDGES := 32
const MAX_FRAME := CogitoPlayerCommand.HEADER_SIZE + MAX_EDGES
const MOVEMENT_MASK := (1 << (CogitoPlayerCommand.Action.FREE_LOOK + 1)) - 1

var _history: Array[PackedByteArray] = []


## Discard pre-teleport or previous-incarnation commands before changing revision.
func clear() -> void:
	_history.clear()


## Remembers this tick even when the caller drops the resulting datagram.
func packet(command: CogitoPlayerCommand) -> PackedByteArray:
	var frame := command.encode().slice(0, CogitoPlayerCommand.HEADER_SIZE)
	var flags := CogitoPlayerCommand.TOGGLE_CROUCH | CogitoPlayerCommand.SUPPRESSED
	frame.encode_u32(24, frame.decode_u32(24) & (MOVEMENT_MASK | flags))
	frame.append_array(_movement_edges(command.edges))
	_history.append(frame)
	if _history.size() > REDUNDANCY:
		_history.pop_front()
	var data := PackedByteArray()
	for item in _history:
		data.append(item.size())
		data.append_array(item)
	return data


## Rejects malformed packets atomically and limits wire input to locomotion.
static func decode(data: PackedByteArray) -> Array[CogitoPlayerCommand]:
	var result: Array[CogitoPlayerCommand] = []
	if data.size() > REDUNDANCY * (MAX_FRAME + 1):
		return []
	var offset := 0
	while offset < data.size():
		var size := int(data[offset])
		offset += 1
		if size > MAX_FRAME or offset + size > data.size() or result.size() == REDUNDANCY:
			return []
		var command := CogitoPlayerCommand.decode(data.slice(offset, offset + size))
		if not command:
			return []
		command.yaw = wrapf(command.yaw, -PI, PI)
		command.pitch = clampf(command.pitch, -PI / 2, PI / 2)
		command.neck_yaw = clampf(command.neck_yaw, -PI, PI)
		command.held &= MOVEMENT_MASK
		command.edges = _movement_edges(command.edges)
		result.append(command)
		offset += size
	return result


static func _movement_edges(edges: PackedByteArray) -> PackedByteArray:
	var movement := PackedByteArray()
	for edge in edges:
		if (edge & ~CogitoPlayerCommand.RELEASE) <= CogitoPlayerCommand.Action.FREE_LOOK:
			movement.append(edge)
			if movement.size() == MAX_EDGES:
				break
	return movement
