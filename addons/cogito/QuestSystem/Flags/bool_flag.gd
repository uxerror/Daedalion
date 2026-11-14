@tool
## A flag with a name and expected boolean value
extends CogitoFlag
class_name BooleanFlag

@export var flag_name: String
@export var expected: bool = true

## Test that the quest flags contains the boolean flag with the expected value
func check(flags: Dictionary) -> bool:
	return flags.has(flag_name) and flags[flag_name] == expected
