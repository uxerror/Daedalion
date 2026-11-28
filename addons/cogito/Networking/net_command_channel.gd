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
	var frame: PackedByteArray = (
		_history.pop_front() if _history.size() == REDUNDANCY else PackedByteArray()
	)
	_encode_frame(command, frame)
	_history.append(frame)
	var data := PackedByteArray()
	for item in _history:
		data.append(item.size())
		data.append_array(item)
	return data


## Freeze a private movement command with precisely the same wire representation.
static func freeze(
	command: CogitoPlayerCommand, target: CogitoPlayerCommand = null, frame := PackedByteArray()
) -> CogitoPlayerCommand:
	_encode_frame(command, frame)
	if not target:
		target = CogitoPlayerCommand.new()
	if not _read_frame(frame, 0, frame.size(), target):
		return null
	target.sequence = command.sequence
	return target


static func _encode_frame(command: CogitoPlayerCommand, frame: PackedByteArray) -> void:
	var count := 0
	for edge in command.edges:
		if WIRE_MASK & (1 << (edge & ~CogitoPlayerCommand.RELEASE)):
			count += 1
			if count == MAX_EDGES:
				break
	frame.resize(CogitoPlayerCommand.HEADER_SIZE + count + GENERATION_BYTES)
	frame.encode_u32(0, command.sequence)
	frame.encode_float(4, command.move.x)
	frame.encode_float(8, command.move.y)
	frame.encode_float(12, wrapf(command.yaw, -PI, PI))
	frame.encode_float(16, command.pitch)
	frame.encode_float(20, command.neck_yaw)
	var flags := CogitoPlayerCommand.TOGGLE_CROUCH | CogitoPlayerCommand.SUPPRESSED
	var buttons := command.held & (WIRE_MASK | flags)
	if command.toggle_crouch:
		buttons |= CogitoPlayerCommand.TOGGLE_CROUCH
	if not command.has_control:
		buttons |= CogitoPlayerCommand.SUPPRESSED
	frame.encode_u32(24, buttons)
	var pos := CogitoPlayerCommand.HEADER_SIZE
	for edge in command.edges:
		if WIRE_MASK & (1 << (edge & ~CogitoPlayerCommand.RELEASE)):
			frame[pos] = edge
			pos += 1
			if pos == frame.size() - GENERATION_BYTES:
				break
	frame.encode_u32(pos, command.wield_generation)


## Rejects malformed packets atomically and limits wire input to movement and wield actions.
static func decode(data: PackedByteArray, driving := false) -> Array[CogitoPlayerCommand]:
	var result: Array[CogitoPlayerCommand] = []
	if not decode_into(data, driving, result, []):
		result.clear()
	return result


## The receiver publishes the scratch array only after the entire datagram validates.
static func decode_into(
	data: PackedByteArray,
	driving: bool,
	result: Array[CogitoPlayerCommand],
	pool: Array[CogitoPlayerCommand]
) -> bool:
	result.clear()
	if data.size() > REDUNDANCY * (MAX_FRAME + 1):
		return false
	var offset := 0
	while offset < data.size():
		var size := int(data[offset])
		offset += 1
		if size < CogitoPlayerCommand.HEADER_SIZE + GENERATION_BYTES or size > MAX_FRAME:
			return false
		if offset + size > data.size() or result.size() == REDUNDANCY:
			return false
		if driving:
			var axes := Vector2(data.decode_float(offset + 4), data.decode_float(offset + 8))
			if not axes.is_finite() or axes.length_squared() > 1.00001:
				return false
		var command := _available_command(pool)
		if not _read_frame(data, offset, size, command):
			return false
		result.append(command)
		offset += size
	return true


static func _available_command(pool: Array[CogitoPlayerCommand]) -> CogitoPlayerCommand:
	for candidate in pool:
		# Queued, consumed or externally retained commands have an additional reference.
		if candidate.get_reference_count() == 2:
			return candidate
	return CogitoPlayerCommand.new()


static func _read_frame(
	data: PackedByteArray, pos: int, size: int, command: CogitoPlayerCommand
) -> bool:
	var axes := Vector2(data.decode_float(pos + 4), data.decode_float(pos + 8))
	var angles := Vector3(
		data.decode_float(pos + 12), data.decode_float(pos + 16), data.decode_float(pos + 20)
	)
	if not axes.is_finite() or not angles.is_finite():
		return false
	var buttons := data.decode_u32(pos + 24)
	command.has_control = (buttons & CogitoPlayerCommand.SUPPRESSED) == 0
	command.toggle_crouch = (buttons & CogitoPlayerCommand.TOGGLE_CROUCH) != 0
	command.held = buttons & ~(CogitoPlayerCommand.SUPPRESSED | CogitoPlayerCommand.TOGGLE_CROUCH)
	var end := pos + size - GENERATION_BYTES
	if (
		not command.has_control
		and (command.held or axes or end != pos + CogitoPlayerCommand.HEADER_SIZE)
	):
		return false
	if command.held >> CogitoPlayerCommand.ACTIONS.size():
		return false
	command.edges = PackedByteArray()
	for i in range(pos + CogitoPlayerCommand.HEADER_SIZE, end):
		var action := data[i] & ~CogitoPlayerCommand.RELEASE
		if action >= CogitoPlayerCommand.ACTIONS.size():
			return false
		if WIRE_MASK & (1 << action):
			command.edges.append(data[i])
	command.sequence = data.decode_u32(pos)
	command.move = axes
	command.yaw = angles.x
	command.pitch = angles.y
	command.neck_yaw = angles.z
	command.wield_generation = data.decode_u32(end)
	if _invalid_wield_aim(command):
		return false
	command.yaw = wrapf(command.yaw, -PI, PI)
	command.pitch = clampf(command.pitch, -PI / 2, PI / 2)
	command.neck_yaw = clampf(command.neck_yaw, -PI, PI)
	command.held &= WIRE_MASK
	return true


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
