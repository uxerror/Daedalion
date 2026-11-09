@tool
# Main class for managing quests in the Cogito system
extends Resource
class_name CogitoQuest

enum QuestState {
	NotStarted,
	Active,
	Completed,
	Failed
}

# Unique quest identifier (for internal reference)
#@export var id: int

## Internal quest name (used for game logic)
@export var quest_name: String

## Displayed quest title (for user interface)
@export var quest_title: String

## All objectives associated with the quest
@export var quest_objectives: Array[CogitoQuestObjective] = []

## Current quest state (Not Started, Active, Completed, Failed)
@export var quest_state: QuestState = QuestState.NotStarted

## Quest description when it's in progress
@export_multiline var quest_description_active: String

# Quest description when it has been completed
@export_multiline var quest_description_completed: String = "You completed this quest."

# Quest description when it has been failed
@export_multiline var quest_description_failed: String = "You failed this quest."

# Current quest description (dynamically updated based on state)
@export var quest_description: String

# Editor group to organize audio settings
@export_group("Quest Audio")

# Audio played when the quest starts
@export var audio_on_start: AudioStream

# Audio played when the quest is completed
@export var audio_on_complete: AudioStream

# Audio played when the quest fails
@export var audio_on_fail: AudioStream

# Starts the quest
# Parameter _mute: if true, doesn't play start audio
func start(_mute: bool = false) -> void:
	# Play start audio if available and not muted
	if audio_on_start and not _mute:
		CogitoAudio.play_sound(audio_on_start)
	
	# Set description to active state
	quest_description = quest_description_active
	
	# Set the quest state to Active, wipe the flags
	quest_state = QuestState.Active



# Updates the quest by updating each associated objective against the world state
func update() -> QuestState:
	var world_state = CogitoSceneManager._current_world_dict
	# Do not update the quest if the state is completed or inactive
	if quest_state == QuestState.Completed or quest_state == QuestState.NotStarted:
		return quest_state
	
	# Shorthand enum (please godot allow aliases)
	var cq = CogitoQuestObjective.ObjectiveState
	
	# Assume quest will complete on update
	var set_quest_state = QuestState.Completed
	
	# Update all quest objectives based on new world flags
	var previous_objective_state: CogitoQuestObjective.ObjectiveState = CogitoQuestObjective.ObjectiveState.Active
	for objective in quest_objectives:
		var objective_state = objective.update(world_state, previous_objective_state == CogitoQuestObjective.ObjectiveState.Completed)
		
		# Fail the quest if the objective fails and is required
		if objective.required_to_complete and objective_state == cq.Failed:
			set_quest_state = QuestState.Failed
			break
		elif objective.required_to_complete and objective_state != cq.Completed:
			set_quest_state = QuestState.Active
			
		# Store objective state for use in unhiding the next objective if boolean is set
		previous_objective_state = objective_state
	
	quest_state = set_quest_state
	return quest_state

# Completes the quest
# Parameter _mute: if true, doesn't play completion audio
func complete(_mute: bool = false) -> void:
	# Play completion audio if available and not muted
	if audio_on_complete and not _mute:
		CogitoAudio.play_sound(audio_on_complete)
	
	# Update description to completed state
	quest_description = quest_description_completed

# Marks the quest as failed
# Parameter _mute: if true, doesn't play failure audio
func failed(_mute: bool = false) -> void:
	# Play failure audio if available and not muted
	if audio_on_fail and not _mute:
		CogitoAudio.play_sound(audio_on_fail)
	
	# Update description to failed state
	quest_description = quest_description_failed
	
func get_all_flag_names() -> Array[String]:
	var flag_names: Array[String] = []
	for objective in quest_objectives:
		flag_names.append_array(objective.get_all_flag_names())
	return flag_names
