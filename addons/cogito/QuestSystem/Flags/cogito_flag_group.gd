extends Resource
class_name CogitoFlagGroup

@export var flags: Array[CogitoFlag]

## Returns all numeric flags to be used for an objective description
func get_numeric_descriptions(quest_flags: Dictionary) -> Array[String]:
	var descriptions: Array[String] = []
	for flag in flags:
		if flag is NumericFlag:
			var current_value = quest_flags.get(flag, 0)
			var flag_data = flag as NumericFlag
			descriptions.append(flag.specific_objective_text + "(%s / %s)" % [quest_flags.get(flag, 0), flag_data.expected])
	return descriptions

## Test each flag in the group as an AND expression. If one expression fails, the entire group fails.
func meets_criteria(quest_flags: Dictionary) -> bool:
	for flag in flags:
		if not flag.check(quest_flags):
			return false
	return true
