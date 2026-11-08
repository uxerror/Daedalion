@tool
## A boolean flag
extends CogitoFlag
class_name BooleanFlag

@export var expected: bool = true

## Test that the quest flags contains the boolean flag with the expected value
func check(flags: Dictionary) -> bool:
	return flags[flag_name] == expected
