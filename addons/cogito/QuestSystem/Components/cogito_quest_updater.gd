extends Node3D
class_name CogitoQuestUpdater

enum UpdateType {Start, Update, Complete, Fail }

const Quests := preload("../../Networking/net_quests.gd")

@export var quest_to_update : CogitoQuest
@export var update_type: UpdateType
## World flag(s) to optionally add if using Update
@export var world_flag: Array[WorldFlag] = []

var has_been_triggered : bool = false #Used to avoid double-triggering.


## Use the server actor when a personal quest is triggered. Legacy void signals are shared.
func update_quest(actor: CogitoPlayer = null) -> void:
	var endpoint := Quests.endpoint(self)
	if endpoint:
		var subject := String(actor.get_meta(&"net_player_id", "")) if actor else ""
		if subject.is_empty():
			subject = endpoint.signal_subject
		var receipt := ""
		if update_type == UpdateType.Update:
			var level_key: String = endpoint.get_parent().world.entities.level_key
			receipt = str([level_key, CogitoPersistentId.of(self)])
		endpoint.advance(quest_to_update, update_type, world_flag, subject, receipt, true)
		return
	if is_inside_tree() and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return
	CogitoGlobals.debug_log(true, "cogito_quest_updater.gd", "Attempting to update quest " + quest_to_update.quest_name)
	match update_type:
		UpdateType.Start:
			CogitoQuestManager.start_quest(quest_to_update)
		UpdateType.Complete:
			quest_to_update.update()
			CogitoQuestManager.complete_quest(quest_to_update)
		UpdateType.Fail:
			CogitoGlobals.debug_log(true, "cogito_quest_updater.gd", "Failing quest " + quest_to_update.quest_name)
			CogitoQuestManager.fail_quest(quest_to_update)
		UpdateType.Update:
			if has_been_triggered:
				return
			if !CogitoQuestManager.is_quest_active(quest_to_update):
				CogitoQuestManager.start_quest(quest_to_update)
			CogitoQuestManager.update_quest(quest_to_update, world_flag)
			has_been_triggered = true


func _on_body_entered(body: Node3D) -> void:
	if body is CogitoPlayer:
		update_quest(body)


func _on_pickup_component_was_interacted_with(_interaction_text: Variant, _input_map_action: Variant) -> void:
	update_quest()


func set_state():
	pass


func save():
	var state_dict = {
		"node_path" : self.get_path(),
		"has_been_triggered" : has_been_triggered,
		"pos_x" : position.x,
		"pos_y" : position.y,
		"pos_z" : position.z,
		"rot_x" : rotation.x,
		"rot_y" : rotation.y,
		"rot_z" : rotation.z,
		
	}
	return state_dict
