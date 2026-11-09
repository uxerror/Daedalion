extends Node

# Signals for sending UI hints to the player
signal quest_activated(quest: CogitoQuest) #Emitted when a quest gets added to the active quests group
signal quest_updated(quest: CogitoQuest) #Emitted when a quests gets updated (used for the quest counter)
signal quest_completed(quest: CogitoQuest) #Emitted when a quest gets completed / moved to the completed quests group.
signal quest_failed(quest: CogitoQuest) #Emitted when a quest gets moved to the failed quests group.

const AvailableQuests = preload("./QuestGroups/available_quests_group.gd")
const ActiveQuests = preload("./QuestGroups/active_quests_group.gd")
const CompletedQuests = preload("./QuestGroups/completed_quests_group.gd")
const FailedQuests = preload("./QuestGroups/failed_quests_group.gd")

var available: AvailableQuests = AvailableQuests.new("Available")
var active: ActiveQuests = ActiveQuests.new("Active")
var completed: CompletedQuests = CompletedQuests.new("Completed")
var failed: FailedQuests = FailedQuests.new("Failed")

var quest_audio_volume_db : float = -9

func _init() -> void:
	# Adding quest groups
	add_child(available)
	add_child(active)
	add_child(completed)
	add_child(failed)


## Starts a given quest by calling its start() method and moving it to the active group
func start_quest(quest: CogitoQuest) -> CogitoQuest:
	assert(quest != null)

	if active.is_quest_inside(quest):
		CogitoGlobals.debug_log(true, "QuestManager.gd", quest.quest_name + " is already active.")
		return quest
	if completed.is_quest_inside(quest):
		CogitoGlobals.debug_log(true, "QuestManager.gd", quest.quest_name + " is already completed.")
		return quest
	if failed.is_quest_inside(quest):
		CogitoGlobals.debug_log(true, "QuestManager.gd", quest.quest_name + " was already failed.")
		return quest	
	

	#Add the quest to the actives quests group
	available.remove_quest(quest)
	active.add_quest(quest)
	quest_activated.emit(quest)

	quest.start()
	CogitoAudio.play_sound(CogitoGlobals.cogito_settings.quest_start_sound, quest_audio_volume_db)
	CogitoGlobals.debug_log(true, "QuestManager.gd", "Quest " + quest.quest_name + " has been started.")
	return quest


## Moves a quest to the completed group. Quest needs to be active to be completed.
func complete_quest(quest: CogitoQuest) -> CogitoQuest:
	if not active.is_quest_inside(quest):
		return quest

	if quest.quest_state != CogitoQuest.QuestState.Completed:
		return quest

	quest.complete()

	active.remove_quest(quest)
	completed.add_quest(quest)

	quest_completed.emit(quest)
	CogitoAudio.play_sound(CogitoGlobals.cogito_settings.quest_complete_sound, quest_audio_volume_db)
	return quest


## Moves a quest to the failed group. Quest needs to be active to be completed.
func fail_quest(quest: CogitoQuest) -> CogitoQuest:
	if not active.is_quest_inside(quest):
		return quest

	quest.failed()

	active.remove_quest(quest)
	failed.add_quest(quest)

	quest_failed.emit(quest)
	CogitoAudio.play_sound(CogitoGlobals.cogito_settings.quest_failed_sound, quest_audio_volume_db)
	return quest


## Updates the quest state with an optional world flag added to the world state. Quest needs to be active.
func update_quest(quest: CogitoQuest, flags: Array[WorldFlag]) -> CogitoQuest:
	if not active.is_quest_inside(quest):
		return quest
	
	var world_state = CogitoSceneManager._current_world_dict
	for flag in flags:
		if not world_state.has(flag.flag_name):
			world_state.set(flag.flag_name, flag.value)
		else:
			# If the value is numeric, combine the existing value
			var value = flag.value
			var set_value = value if value is bool else world_state[flag.flag_name] as int + value as int
			world_state.set(flag.flag_name, set_value)
	
	var quest_state = quest.update()
	if quest_state == CogitoQuest.QuestState.Completed:
		complete_quest(quest)
	elif quest_state == CogitoQuest.QuestState.Failed:
		fail_quest(quest)
	else:
		quest_updated.emit(quest)

	return quest


## Functions to get a list of quests from each group
func get_available_quests() -> Array[CogitoQuest]:
	return available.quests


func get_active_quests() -> Array[CogitoQuest]:
	return active.quests


func get_completed_quests() -> Array[CogitoQuest]:
	return completed.quests


func get_failed_quests() -> Array[CogitoQuest]:
	return failed.quests


## Gets a quest that's neither in the active, completed or failed groups
func is_quest_available(quest: CogitoQuest) -> bool:
	if not (active.is_quest_inside(quest) or completed.is_quest_inside(quest) or failed.is_quest_inside(quest)):
		return true
	return false


## Checks if a quest is currently in the active group.
func is_quest_active(quest: CogitoQuest) -> bool:
	if active.is_quest_inside(quest):
		return true
	return false


## Checks if a quest is currently in the completed group.
func is_quest_completed(quest: CogitoQuest) -> bool:
	if completed.is_quest_inside(quest):
		return true
	return false


## Checks if a quest is in a given group. Given group name string needs to match child node name (as added in _ready)
func is_quest_in_group(quest: CogitoQuest, group_name: String) -> bool:
	if group_name.is_empty():
		for group in get_children():
			if group.is_quest_inside(quest): return true
		return false

	var group := get_node(group_name)
	if group.is_quest_inside(quest): return true
	return false


## Force moves a quest to a group.
func move_quest_to_group(quest: CogitoQuest, old_group: String, new_group: String) -> CogitoQuest:
	if old_group == new_group: return

	var old_group_instance: CogitoQuestGroup = get_node_or_null(old_group)
	var new_group_instance: CogitoQuestGroup = get_node_or_null(new_group)

	assert(old_group_instance != null or new_group_instance != null)

	old_group_instance.quests.erase(quest)
	new_group_instance.quests.append(quest)

	return quest


## Clears a group. Given group name string needs to match child node name (as added in _ready)
func reset_group(group_name: String) -> void:
	if group_name.is_empty():
		for group in get_children():
			group.reset()
		return

	var group := get_node(group_name)
	group.clear_group()
	return


## Extra QuestManager methods that are currently not really needed.
#func quests_as_dict() -> Dictionary:
	#var quest_dict: Dictionary = {}
#
	#for group in get_children():
		#quest_dict[group.name.to_lower()] = group.get_ids_from_quests()
#
	#return quest_dict
#
#
#func dict_to_quests(dict: Dictionary, quests: Array[CogitoQuest]) -> void:
	#for group in get_children():
#
		## Make sure to iterate only for available pools
		#if !dict.has(group.name.to_lower()): continue
#
		## Match quest with their ids and insert them into the quest pool
		#var quest_with_id: Dictionary = {}
		#var group_ids: Array[int]
		#group_ids.append_array(dict[group.name.to_lower()])
		#for quest in quests:
			#if quest.id in group_ids:
				#group.add_quest(quest)
				#quests.erase(quest)
#
#
#func serialize_quests(group: String) -> Dictionary:
	#var group_node: CogitoQuestGroup = get_node_or_null(group)
#
	#if group_node == null: return {}
#
	#var quest_dictionary: Dictionary = {}
	#for quests in group_node.quests:
		#var quest_data: Dictionary
		#for name in quests.get_script().get_script_property_list():
#
			## Filter only defined properties
			#if name.usage & PROPERTY_USAGE_STORAGE or name.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				#quest_data[name["name"]] = quests.get(name["name"])
#
		#quest_data.erase("id")
		#quest_dictionary[quests.id] = quest_data
#
	#return quest_dictionary
