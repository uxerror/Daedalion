extends CogitoPlayerInputSource
## Server-side receive window for one admitted connection and avatar lifetime.

const CHANNEL := preload("net_command_channel.gd")
const JITTER_TICKS := 2
const STALE_TICKS := 12
const WINDOW := 24
const HALF_RANGE := 1 << 31

var _pending: Dictionary[int, CogitoPlayerCommand] = {}
var _tick := 0
var _packets := 0
var _last_arrival := -STALE_TICKS
var _play_at := 0
var _latest_received := -1
var _ack := -1
var _last: CogitoPlayerCommand


## Unwrap a wire sequence to the closest signed distance from the next expected tick.
static func unwrap(sequence: int, expected: int) -> int:
	return expected + wrapi(sequence - expected, -HALF_RANGE, HALF_RANGE)


## At most four bounded packets per simulation tick, including malformed packets.
func receive(data: PackedByteArray, driving := false) -> void:
	if _packets >= 4:
		return
	_packets += 1
	for command in CHANNEL.decode(data, driving):
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


## One command per server tick. Reuse held state across short gaps, never replay an edge.
## A null sample releases input without inventing an acknowledgement.
func sample(_actor: CogitoPlayer, _sequence: int) -> CogitoPlayerCommand:
	_tick += 1
	_packets = 0
	if _tick - _last_arrival >= STALE_TICKS:
		_pending.clear()
		_last = null
	if _pending.is_empty() or _tick < _play_at:
		return _last
	var seq := _ack + 1
	if not _pending.has(seq):
		if _pending.size() < JITTER_TICKS and _tick - _last_arrival < JITTER_TICKS:
			return _last
		seq = _pending.keys().min()
	_last = _pending[seq]
	_pending.erase(seq)
	_ack = seq
	return _last
