extends CogitoFlag
class_name BooleanFlag

@export var expected: bool = true

## Check the flag matches the expected parameters
func check(flags: Dictionary) -> bool:
	return flags[flag_name] == expected
