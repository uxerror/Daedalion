extends Control
class_name QuestEntry

@onready var quest_name_label: Label = $VBoxContainer/QuestName
@onready var quest_description_label: Label = $VBoxContainer/QuestDescription
@onready var quest_objectives_label: Label = $VBoxContainer/QuestObjectives

func set_quest_info(_passed_quest: CogitoQuest):
	quest_name_label.text = _passed_quest.quest_title
	quest_description_label.text = _passed_quest.quest_description
	
	quest_objectives_label.text = ""
	for objective in _passed_quest.quest_objectives:
		if objective.objective_state != CogitoQuestObjective.ObjectiveState.Hidden:
			quest_objectives_label.text += "\n- %s" % objective.get_description(CogitoSceneManager._current_world_dict)
