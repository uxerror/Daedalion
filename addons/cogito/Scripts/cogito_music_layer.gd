@icon("res://addons/cogito/Assets/Graphics/Editor/CogitoNodeIcon.svg")
class_name CogitoMusicLayer
extends Resource
## One track of a CogitoMusicState: a music stem or an ambience loop.
## Layers are identified by their stream: if the next state contains a layer with the same
## stream, that layer keeps playing and only fades to its new volume.

## The track to play. Import it with loop enabled for gapless looping.
@export var stream: AudioStream
## Volume of this layer when its state is fully faded in.
@export_range(-80.0, 24.0) var volume_db: float = 0.0
## Audio bus this layer plays on.
@export var bus: String = OptionsConstants.music_bus_name
## If checked, the layer starts at the playback position of an already playing layer of the same length,
## so stems of one composition stay in sync. Uncheck for independent loops like ambience.
@export var sync_playback: bool = true
