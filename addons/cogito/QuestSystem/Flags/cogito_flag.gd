## An abstract container for flags. Do NOT use this, instead use the subclasses
## BooleanFlag, NumericFlag or PlayerFlag
@abstract @tool
extends Resource
class_name CogitoFlag

@export var flag_name: String

@abstract
func check(flags: Dictionary) -> bool
