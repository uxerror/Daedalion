extends RefCounted
## Preserve transform/visual tracks but leave method, audio and nested playback on authority.

var _player: AnimationPlayer
var _libraries := {}
var _blocked := false


## Install private presentation copies without changing an authored Animation resource.
func bind(player: AnimationPlayer) -> void:
	_player = player
	_blocked = player.is_blocking_signals()
	player.set_block_signals(true)
	player.stop(true)
	for library_name in player.get_animation_library_list():
		var library := player.get_animation_library(library_name)
		_libraries[library_name] = library
		var presentation := AnimationLibrary.new()
		for clip in library.get_animation_list():
			var anim := library.get_animation(clip).duplicate() as Animation
			for track in range(anim.get_track_count() - 1, -1, -1):
				if (
					anim.track_get_type(track)
					in [Animation.TYPE_AUDIO, Animation.TYPE_METHOD, Animation.TYPE_ANIMATION]
				):
					anim.remove_track(track)
			presentation.add_animation(clip, anim)
		player.remove_animation_library(library_name)
		player.add_animation_library(library_name, presentation)


## Restore the animation libraries when a session ends with the scene still loaded.
func restore() -> void:
	if is_instance_valid(_player):
		_player.stop(true)
		for library_name: StringName in _libraries:
			_player.remove_animation_library(library_name)
			_player.add_animation_library(library_name, _libraries[library_name])
		_player.set_block_signals(_blocked)
	_libraries.clear()
