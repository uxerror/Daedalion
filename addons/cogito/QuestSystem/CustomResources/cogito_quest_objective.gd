@tool
extends Resource
class_name CogitoQuestObjective

enum ObjectiveState {
	Completed,
	Failed,
	Active,
	Hidden
}

@export var objective_id: int

## If set to true, this objective is required to complete the quest. At least one of these objectives must be set to true,
## if this objective fails when set to true it will fail the quest.
@export var required_to_complete: bool = true

@export_multiline("monospace") var objective_description: String

## Current state of the objective
@export var objective_state: ObjectiveState = ObjectiveState.Active

## Flag group that completes the objective. Multiple flag groups work as a "Group" OR "Group" relationship
@export var completion_flags: Array[CogitoFlagGroup] = []

## Flags needed in quest to fail the objective
@export var failure_flags:  Array[CogitoFlagGroup] = []

## Flags needed to reveal the objective
@export var reveal_flags:  Array[CogitoFlagGroup] = []

func get_all_flag_names() -> Array[String]:
	var names: Array[String] = []
	for group in completion_flags:
		names.append_array(group.get_flag_names())
	for group in failure_flags:
		names.append_array(group.get_flag_names())
	for group in reveal_flags:
		names.append_array(group.get_flag_names())
	return names

func get_description(flags: Dictionary) -> String:
	var description = objective_description
	for flag in completion_flags:
		for num in flag.get_numeric_descriptions(flags):
			description.append("\n%s" % num)
	return description + " [%s]" % ObjectiveState.keys()[objective_state]

func update(flags: Dictionary) -> ObjectiveState:
	## If objective state is hidden, check reveal flags
	if objective_state == ObjectiveState.Hidden:
		for group in reveal_flags:
			if group.meets_criteria(flags):
				objective_state = ObjectiveState.Active
	
	for group in completion_flags:
		if group.meets_criteria(flags):
			objective_state = ObjectiveState.Completed
			
	for group in failure_flags:
		if group.meets_criteria(flags):
			objective_state = ObjectiveState.Failed

	return objective_state
