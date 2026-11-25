class_name CogitoRespawnPoint
extends Marker3D
## An authored respawn transform in the player's current level.

## Disabled points are excluded from selection.
@export var enabled := true
## Optional game-defined category, for example a checkpoint or team.
@export var tag: StringName
