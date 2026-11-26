@tool
## Allows multiple flags to be required as part of a group, forming an AND expression.
extends CogitoFlagGroup
class_name MultiFlagGroup

@export var flags: Array[CogitoFlag]

func get_flag_names() -> Array[String]:
	return flags.map(func(x): if x is NumericFlag or x is BooleanFlag: return x.flag_name)

## Returns all numeric flags to be used for an objective description
func get_numeric_descriptions(quest_flags: Dictionary) -> Array[String]:
	var descriptions: Array[String] = []
	for flag in flags:
		if flag is NumericFlag:
			var current_value = quest_flags.get(flag.flag_name, 0)
			var flag_data = flag as NumericFlag
			descriptions.append(flag.specific_objective_text + "(%s / %s)" % [current_value, flag_data.expected])
	return descriptions

## Test each flag in the group as an AND expression. If one expression fails, the entire group fails.
func meets_criteria(quest_flags: Dictionary) -> bool:
	for flag in flags:
		if not flag.check(quest_flags):
			return false
	return true


func meets_in_context(world_flags: Dictionary, context: CogitoQuestContext) -> bool:
	if not context:
		return meets_criteria(world_flags)
	var items: Array[InventoryItemPD] = []
	for flag in flags:
		if flag is InventoryFlag:
			items.append(flag.expected_item)
		elif not flag.check_in_context(world_flags, context):
			return false
	return items.is_empty() or context.holds_all(items)
