extends RefCounted
## One progression scope. All stored keys and values are independent of live nodes and Resources.

const STATE := CogitoQuest.QuestState

var revision := 0
var quests := {}
var flags := {}
var triggers := {}


## MP9 capture includes one-shot trigger receipts, which only the authority needs.
func capture() -> Dictionary:
	var data := snapshot()
	data.triggers = triggers.duplicate(true)
	return data


## Install an authority snapshot once, including private one-shot receipts.
func restore(data: Dictionary) -> void:
	apply(data, true)
	triggers = data.triggers.duplicate(true)


## Full journal and numeric/boolean flag state at one revision.
func snapshot() -> Dictionary:
	return {"revision": revision, "quests": quests.duplicate(true), "flags": flags.duplicate(true)}


## Merge one ordered delta, or silently replace the complete scope at a baseline.
func apply(data: Dictionary, full: bool) -> bool:
	if data.revision < revision or (not full and data.revision != revision + 1):
		return false
	if full:
		quests.clear()
		flags.clear()
	revision = data.revision
	quests.merge(data.quests, true)
	flags.merge(data.flags, true)
	return true


## Objective assets use their path. Built-ins use authored ID and occurrence within this quest.
static func objective_keys(definition: CogitoQuest) -> Array[String]:
	var keys: Array[String] = []
	var counts := {}
	for obj in definition.quest_objectives:
		if not obj.is_built_in():
			keys.append(obj.resource_path)
		else:
			var occurrence: int = counts.get(obj.objective_id, 0)
			keys.append("%d/%d" % [obj.objective_id, occurrence])
			counts[obj.objective_id] = occurrence + 1
	return keys


## Rebuild a private working or HUD instance. Shallow-copy each objective, sharing read-only flags.
static func instance(definition: CogitoQuest, row: Dictionary) -> CogitoQuest:
	var quest := definition.duplicate() as CogitoQuest
	quest.quest_objectives = definition.quest_objectives.duplicate()
	var keys := objective_keys(definition)
	for i in keys.size():
		var objective := definition.quest_objectives[i].duplicate() as CogitoQuestObjective
		objective.objective_state = row.get("objectives", {}).get(
			keys[i], CogitoQuestManager.initial_objective_state(definition.quest_objectives[i])
		)
		quest.quest_objectives[i] = objective
	quest.quest_state = row.get("state", STATE.Active)
	match quest.quest_state:
		STATE.Active:
			quest.quest_description = quest.quest_description_active
		STATE.Completed:
			quest.quest_description = quest.quest_description_completed
		STATE.Failed:
			quest.quest_description = quest.quest_description_failed
	return quest


## Encode state without descriptions, localized strings, streams or Resource references.
static func record(definition: CogitoQuest, quest: CogitoQuest) -> Dictionary:
	var objectives := {}
	var keys := objective_keys(definition)
	for i in keys.size():
		objectives[keys[i]] = quest.quest_objectives[i].objective_state
	return {"state": quest.quest_state, "objectives": objectives}
