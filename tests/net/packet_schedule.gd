extends RefCounted
## Receiver-side packet deadlines. Clock units are physics ticks or monotonic microseconds.

var unit_ms: float
var destination: int
var defaults: Dictionary
var rules := {}
var _streams := {}
var _pending: Array[Dictionary] = []
var _serial := 0


func _init(receiver: int, milliseconds_per_unit: float, options := {}) -> void:
	destination = receiver
	unit_ms = milliseconds_per_unit
	defaults = options


static func profile(rtt_ms: int) -> Dictionary:
	return {"delay_ms": rtt_ms * 0.5, "jitter_ms": 10 if rtt_ms >= 100 else 0, "seed": 140}


func configure(source: int, channel: int, options: Dictionary) -> void:
	rules[Vector2i(source, channel)] = defaults.merged(options, true)


func enqueue(packet: Array, now: int, ready: Array) -> void:
	var source: int = packet[0]
	var channel: int = packet[1]
	var mode: int = packet[2]
	var key := Vector3i(source, channel, mode)
	var options: Dictionary = rules.get(Vector2i(source, channel), defaults)
	if options.is_empty() and not _streams.has(key):
		ready.append(packet)
		return
	if not _streams.has(key):
		_streams[key] = {
			"rng": RandomNumberGenerator.new(),
			"seed": null,
			"due": 0,
			"latest": -1,
			"stats": {"sum_ms": 0.0, "count": 0},
		}
	var stream: Dictionary = _streams[key]
	var rng: RandomNumberGenerator = stream.rng
	var stream_seed := int(options.get("seed", 1))
	if stream.seed != stream_seed:
		rng.seed = hash([stream_seed, source, destination, channel, mode])
		stream.seed = stream_seed
	var reliable := mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
	var loss := float(options.get("loss", 0))
	if not reliable and (loss >= 1.0 or rng.randf() < loss):
		return
	_serial += 1
	var dup := float(options.get("dup", 0))
	var duplicate := not reliable and (dup >= 1.0 or rng.randf() < dup)
	for copy in 2 if duplicate else 1:
		var jitter: float = options.get("jitter_ms", 0.0)
		var ms := float(options.get("delay_ms", 0.0)) + rng.randf_range(-jitter, jitter)
		var due := now + ceili(maxf(0.0, ms) / unit_ms)
		if reliable:
			due = maxi(stream.due, due)
			stream.due = due
		var entry := {"key": key, "seq": _serial, "start": now, "due": due, "packet": packet}
		entry.stats = stream.stats
		_pending.append(entry)


func poll(now: int, ready: Array) -> void:
	if _pending.is_empty():
		return
	# Break tied deadlines by submission order, including reliable packets behind a delayed one.
	_pending.sort_custom(_earlier)
	while not _pending.is_empty() and int(_pending[0].due) <= now:
		var item: Dictionary = _pending.pop_front()
		var stream: Dictionary = _streams[item.key]
		if item.key.z == MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
			if item.seq <= stream.latest:
				continue
			stream.latest = item.seq
		item.stats.sum_ms += (now - int(item.start)) * unit_ms
		item.stats.count += 1
		ready.append(item.packet)


func _earlier(a: Dictionary, b: Dictionary) -> bool:
	return a.seq < b.seq if a.due == b.due else a.due < b.due


func mean_delay_ms(source: int, channel: int, mode: int) -> float:
	var stream: Dictionary = _streams.get(Vector3i(source, channel, mode), {})
	var stats: Dictionary = stream.get("stats", {})
	return float(stats.sum_ms) / stats.count if stats.get("count", 0) > 0 else 0.0


func forget(source: int) -> void:
	_pending = _pending.filter(func(item: Dictionary): return item.key.x != source)
	for key: Vector3i in _streams.keys():
		if key.x == source:
			_streams.erase(key)


func reset_stats() -> void:
	for stream: Dictionary in _streams.values():
		stream.stats = {"sum_ms": 0.0, "count": 0}
