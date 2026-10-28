extends Node
## Plays one-shot sounds and layered music. Registered as the CogitoAudio autoload.
##
## One-shot players free themselves when they finish. For a sound that is played
## repeatedly (e.g. a looping slide sound), use a regular AudioStreamPlayer node instead.
##
## Music is defined by CogitoMusicState resources. The scene's state (see CogitoScene)
## plays unless something requests another state with push_music_state().

const SILENT_DB := -80.0

#region One-shot sounds

## Plays a non-positional sound (UI, 2D or player-centric sounds).
## These keep playing across scene changes and while the game is paused.
func play_sound(stream: AudioStream, volume_db := 0.0, pitch_scale := 1.0, bus: String = OptionsConstants.sfx_bus_name) -> AudioStreamPlayer:
	if not stream:
		return null
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.bus = bus
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()
	return player


## Plays a sound at a fixed global position in the current scene.
func play_sound_3d(stream: AudioStream, position: Vector3, volume_db := 0.0, pitch_scale := 1.0, bus: String = OptionsConstants.sfx_bus_name) -> AudioStreamPlayer3D:
	if not stream:
		return null
	var scene := get_tree().current_scene
	if not scene:
		CogitoGlobals.debug_log(true, "cogito_audio.gd", "No current scene to play " + stream.resource_path + " in.")
		return null
	var player := _create_player_3d(stream, volume_db, pitch_scale, bus)
	scene.add_child(player)
	player.global_position = position
	player.play()
	return player


## Plays a sound attached to a node, so it follows the node while playing.
## The sound stops if the node is freed.
func play_sound_3d_attached(stream: AudioStream, node: Node3D, volume_db := 0.0, pitch_scale := 1.0, bus: String = OptionsConstants.sfx_bus_name) -> AudioStreamPlayer3D:
	if not stream or not is_instance_valid(node):
		return null
	var player := _create_player_3d(stream, volume_db, pitch_scale, bus)
	node.add_child(player)
	player.play()
	return player


func _create_player_3d(stream: AudioStream, volume_db: float, pitch_scale: float, bus: String) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.bus = bus
	player.finished.connect(player.queue_free)
	return player

#endregion


#region Music

var _scene_music_state: CogitoMusicState
var _scene_combat_music_state: CogitoMusicState
## Requested states, oldest first. Each entry: { source: Object, state: CogitoMusicState, on_exit: Callable }
var _music_requests: Array[Dictionary] = []
var _active_music_state: CogitoMusicState
var _resolve_queued := false

## Players of the active state's layers, by stream.
var _layer_players: Dictionary[AudioStream, AudioStreamPlayer] = {}
## Players of layers that are fading out, by stream. Freed once the fade is done.
var _fading_out_players: Dictionary[AudioStream, AudioStreamPlayer] = {}
var _fade_tweens: Dictionary[AudioStreamPlayer, Tween] = {}


func _init() -> void:
	# Music and non-positional one-shots keep playing while the game is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Sets the music states of the current scene. Called by CogitoScene when it enters the tree.
## state plays while nothing else is requested; pass null for silence.
## combat_state is what NPCs request in combat unless they have their own.
func set_scene_music_state(state: CogitoMusicState, combat_state: CogitoMusicState = null) -> void:
	_scene_music_state = state
	_scene_combat_music_state = combat_state
	_queue_music_resolve()


## Combat music state of the current scene, or null.
func get_scene_combat_music_state() -> CogitoMusicState:
	return _scene_combat_music_state


## Requests a music state on behalf of source (e.g. an NPC requesting combat music).
## Each source holds at most one request; pushing a different state replaces it.
## The request with the highest priority plays, or the scene's state if there are none.
## On equal priority the oldest request keeps playing.
## If source is a Node, its request is released when it leaves the tree.
func push_music_state(state: CogitoMusicState, source: Object) -> void:
	# Pushing the same state again keeps the request's place, so it doesn't win ties it didn't win before.
	if _music_requests.any(func(request): return request.source == source and request.state == state):
		return
	_remove_music_request(source)
	var request := { "source": source, "state": state, "on_exit": Callable() }
	if source is Node:
		request.on_exit = release_music_state.bind(source)
		source.tree_exiting.connect(request.on_exit)
	_music_requests.append(request)
	_queue_music_resolve()


## Releases the request made by source, if any.
func release_music_state(source: Object) -> void:
	_remove_music_request(source)
	_queue_music_resolve()


func get_active_music_state() -> CogitoMusicState:
	return _active_music_state


func _remove_music_request(source: Object) -> void:
	for i in range(_music_requests.size() - 1, -1, -1):
		var request := _music_requests[i]
		if request.source != source:
			continue
		if is_instance_valid(source) and request.on_exit.is_valid() and source.tree_exiting.is_connected(request.on_exit):
			source.tree_exiting.disconnect(request.on_exit)
		_music_requests.remove_at(i)


# The state is resolved once at the end of the frame, so a release followed by a push in
# the same frame (e.g. an NPC going from chasing to attacking) doesn't restart any fades.
func _queue_music_resolve() -> void:
	if _resolve_queued:
		return
	_resolve_queued = true
	_resolve_music_state.call_deferred()


func _resolve_music_state() -> void:
	_resolve_queued = false
	_music_requests = _music_requests.filter(func(request): return is_instance_valid(request.source))

	var target_state: CogitoMusicState = null
	for request in _music_requests:
		# > so the oldest request wins ties.
		if request.state and (target_state == null or request.state.priority > target_state.priority):
			target_state = request.state
	if target_state == null:
		target_state = _scene_music_state

	if target_state != _active_music_state:
		_apply_music_state(target_state)


func _apply_music_state(state: CogitoMusicState) -> void:
	var previous_state := _active_music_state
	_active_music_state = state
	CogitoGlobals.debug_log(true, "cogito_audio.gd", "Music state: " + (state.resource_path if state else "<none>"))

	var fade_in_time := state.fade_in_time if state else 0.0
	var fade_out_time := previous_state.fade_out_time if previous_state else 0.0

	var wanted_layers: Dictionary[AudioStream, CogitoMusicLayer] = {}
	if state:
		for layer in state.layers:
			if layer and layer.stream:
				wanted_layers[layer.stream] = layer

	for stream in _layer_players.keys():
		if not wanted_layers.has(stream):
			var player := _layer_players[stream]
			_layer_players.erase(stream)
			_fading_out_players[stream] = player
			_fade_music_player(player, SILENT_DB, fade_out_time, true)

	for stream in wanted_layers:
		var layer := wanted_layers[stream]
		var player: AudioStreamPlayer = _layer_players.get(stream)
		if not player and _fading_out_players.has(stream):
			# Layer was on its way out, bring it back from where it is.
			player = _fading_out_players[stream]
			_fading_out_players.erase(stream)
		if not player:
			player = _create_music_player(layer)
			player.play(_get_layer_sync_position(layer))
		player.bus = layer.bus
		_layer_players[stream] = player
		_fade_music_player(player, layer.volume_db, fade_in_time, false)


func _create_music_player(layer: CogitoMusicLayer) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = layer.stream
	player.bus = layer.bus
	player.volume_db = SILENT_DB
	# Keeps layers going if a stream isn't imported with loop enabled.
	player.finished.connect(player.play)
	add_child(player)
	return player


## Where a new layer should start so it stays in sync with an already playing layer of the same length.
func _get_layer_sync_position(layer: CogitoMusicLayer) -> float:
	if not layer.sync_playback:
		return 0.0
	var length := layer.stream.get_length()
	if length <= 0.0:
		return 0.0
	for player in _layer_players.values() + _fading_out_players.values():
		if player.playing and is_equal_approx(player.stream.get_length(), length):
			return fmod(player.get_playback_position() + AudioServer.get_time_since_last_mix(), length)
	return 0.0


# Fades in linear amplitude, which sounds more even than fading in dB.
func _fade_music_player(player: AudioStreamPlayer, target_db: float, duration: float, free_when_done: bool) -> void:
	if _fade_tweens.has(player):
		_fade_tweens[player].kill()
		_fade_tweens.erase(player)

	var tween := create_tween()
	_fade_tweens[player] = tween
	tween.tween_method(func(amplitude: float): player.volume_db = linear_to_db(amplitude),
		db_to_linear(player.volume_db), db_to_linear(target_db), maxf(duration, 0.0))
	tween.tween_callback(func(): _on_music_fade_finished(player, free_when_done))


func _on_music_fade_finished(player: AudioStreamPlayer, free_when_done: bool) -> void:
	_fade_tweens.erase(player)
	if not free_when_done:
		return
	_fading_out_players.erase(player.stream)
	player.queue_free()

#endregion
