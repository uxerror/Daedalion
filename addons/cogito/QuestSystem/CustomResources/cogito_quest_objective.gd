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

## World Flag group that completes the objective. Multiple flag groups work as a "Group" OR "Group" relationship
@export var completion_flags: Array[CogitoFlagGroup] = []

## World Flag group needed in quest to fail the objective
@export var failure_flags:  Array[CogitoFlagGroup] = []

## World Flags group needed to reveal the objective
@export var reveal_flags:  Array[CogitoFlagGroup] = []
## If true, reveals the objective when the previous ones is completed
@export var reveal_on_completion_of_previous_objective: bool = false

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
	var numeric_descs = ""
	for flag in completion_flags:
		for num in flag.get_numeric_descriptions(flags):
			numeric_descs += "\n%s" % num if len(num) > 0 else ""
	return tr(objective_description) + " [%s]" % ObjectiveState.keys()[objective_state] + numeric_descs

func update(flags: Dictionary, previous_objective_completed: bool) -> ObjectiveState:
	## If objective state is hidden, check reveal flags
	if objective_state == ObjectiveState.Hidden:
		if reveal_on_completion_of_previous_objective and previous_objective_completed:
			objective_state = ObjectiveState.Active
		else:
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
