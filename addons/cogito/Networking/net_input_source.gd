extends CogitoPlayerInputSource
## Server-side receive window for one admitted connection and avatar lifetime.

const CHANNEL := preload("net_command_channel.gd")
const JITTER_TICKS := 2
const STALE_TICKS := 12
const WINDOW := 24
const HALF_RANGE := 1 << 31

const DISPOSITION := NetOwnerState.Disposition

var disposition := DISPOSITION.NEUTRAL
var last_fresh_sequence := -1
var last_fresh_tick := -1
var next_server_tick := 1
var sample_tick := -1
var discontinuities := 0

var _pending: Dictionary[int, CogitoPlayerCommand] = {}
var _tick := 0
var _packets := 0
var _last_arrival := -STALE_TICKS
var _play_at := 0
var _latest_received := -1
var _ack := -1
var _last: CogitoPlayerCommand
var _decoded: Array[CogitoPlayerCommand] = []
var _command_pool: Array[CogitoPlayerCommand] = []


func _init() -> void:
	for slot in WINDOW + CHANNEL.REDUNDANCY + 1:
		_command_pool.append(CogitoPlayerCommand.new())


## Unwrap a wire sequence to the closest signed distance from the next expected tick.
static func unwrap(sequence: int, expected: int) -> int:
	return expected + wrapi(sequence - expected, -HALF_RANGE, HALF_RANGE)


## At most four bounded packets per simulation tick, including malformed packets.
func receive(data: PackedByteArray, driving := false) -> void:
	if _packets >= 4:
		return
	_packets += 1
	if not CHANNEL.decode_into(data, driving, _decoded, _command_pool):
		return
	for command in _decoded:
		var seq := unwrap(command.sequence, _ack + 1)
		if seq <= _ack or _pending.has(seq):
			continue
		# Allow the sender clock to drift. After a stall, start a fresh jitter window
		# while preserving the replay watermark and the one-command-per-tick limit.
		var elapsed := _tick - _last_arrival
		if elapsed < STALE_TICKS and seq > _latest_received + elapsed + WINDOW:
			continue
		if _pending.size() == WINDOW:
			break
		if _pending.is_empty() and _tick - _last_arrival >= STALE_TICKS:
			_play_at = _tick + JITTER_TICKS
		command.sequence = seq
		_pending[seq] = command
		_latest_received = maxi(_latest_received, seq)
		_last_arrival = _tick


## Drop queued movement after an authority-forced change of pose.
func clear() -> void:
	_pending.clear()
	_last = null
	_last_arrival = _tick - STALE_TICKS
	# A revision between samples does not rewrite the disposition of the completed tick.


## Keep the unwrap watermark across in-place respawn, isolate this life's alignment.
func renew_life() -> void:
	clear()
	disposition = DISPOSITION.NEUTRAL
	last_fresh_sequence = -1
	last_fresh_tick = -1
	discontinuities = 0


func _observe(next: NetOwnerState.Disposition) -> void:
	if (
		next == DISPOSITION.GAP
		or (next != disposition and next in [DISPOSITION.HELD, DISPOSITION.NEUTRAL])
	):
		discontinuities += 1
	disposition = next


## Suspended samplers have no fresh input on this authority tick.
func finish_tick(server_tick: int) -> void:
	next_server_tick = server_tick + 1
	if sample_tick != server_tick:
		_observe(DISPOSITION.NEUTRAL)


func _reuse() -> CogitoPlayerCommand:
	_observe(DISPOSITION.HELD if _last else DISPOSITION.NEUTRAL)
	return _last


## One command per server tick. Reuse held state across short gaps, never replay an edge.
## A null sample releases input without inventing an acknowledgement.
func sample(_actor: CogitoPlayer, _sequence: int) -> CogitoPlayerCommand:
	_tick += 1
	sample_tick = next_server_tick
	next_server_tick += 1
	_packets = 0
	if _tick - _last_arrival >= STALE_TICKS:
		_pending.clear()
		_last = null
	if _pending.is_empty() or _tick < _play_at:
		return _reuse()
	var seq := _ack + 1
	if not _pending.has(seq):
		if _pending.size() < JITTER_TICKS and _tick - _last_arrival < JITTER_TICKS:
			return _reuse()
		seq = _pending.keys().min()
	_last = _pending[seq]
	_pending.erase(seq)
	_observe(DISPOSITION.GAP if last_fresh_sequence >= 0 and seq != _ack + 1 else DISPOSITION.FRESH)
	last_fresh_sequence = seq
	last_fresh_tick = sample_tick
	_ack = seq
	return _last
