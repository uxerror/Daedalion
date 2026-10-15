@icon("res://addons/cogito/Assets/Graphics/Editor/CogitoNodeIcon.svg")
class_name CogitoMusicState
extends Resource
## A set of music and ambience layers that play together, e.g. "Exploration" or "Combat".
## Set a scene's state on its CogitoScene node. Game code can request other states with
## CogitoAudio.push_music_state() and CogitoAudio.release_music_state().

## Layers that play while this state is active.
@export var layers: Array[CogitoMusicLayer] = []
## When several states are requested, the one with the highest priority plays.
@export var priority: int = 0
## Seconds for this state's layers to fade in when it becomes active.
@export var fade_in_time: float = 2.0
## Seconds for this state's layers to fade out when another state takes over.
@export var fade_out_time: float = 2.0
