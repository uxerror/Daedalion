@tool
## A flag with a name and expected numeric value of either >=, ==, or <=
extends CogitoFlag
class_name NumericFlag

## Numeric operations, didn't include greater or less equality exclusive because its probably too niche
enum Op {
	GREATER_OR_EQL,
	EQUAL,
	LESS_OR_EQL,
}

## If using multiple numeric flags for a single objective, this allows you to make each one distinct in your objective description
@export var specific_objective_text: String = ""

@export var flag_name: String
@export var should_be: Op = Op.GREATER_OR_EQL
@export var expected: int

## Check the flag matches the expected parameters
func check(flags: Dictionary) -> bool:
	if not flags.has(flag_name):
		return false
	match should_be:
		Op.GREATER_OR_EQL:
			return flags[flag_name] >= expected
		Op.EQUAL:
			return flags[flag_name] == expected
		Op.LESS_OR_EQL:
			return flags[flag_name] <= expected
		_:
			return true
