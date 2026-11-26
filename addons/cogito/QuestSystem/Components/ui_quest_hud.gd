extends Node

## If checked, the player will receive notifications when a quest status has changed.
@export var send_quest_notifications : bool
## Reference to how a single quest is displayed in the QuestHUD
@export var quest_entry : PackedScene

var _quests: Node

@onready var quest_display: PanelContainer = $QuestDisplay

# Quest groups:
@onready var active_group: VBoxContainer = $QuestDisplay/VBoxContainer/TabContainer/QUESTS_active
@onready var completed_group: VBoxContainer = $QuestDisplay/VBoxContainer/TabContainer/QUESTS_completed
@onready var failed_group: VBoxContainer = $QuestDisplay/VBoxContainer/TabContainer/QUESTS_failed

#Reference of main Player HUD.
@export var player_hud  : CogitoPlayerHudManager

func _ready():
	_quests = preload("../../Networking/net_quests.gd").endpoint(self)
	if _quests:
		_quests.journal_changed.connect(_refresh_visible)
		if player_hud.is_node_ready():
			_quests.bind_hud(_network_notification)
		else:
			player_hud.ready.connect(_quests.bind_hud.bind(_network_notification), CONNECT_ONE_SHOT)
	else:
		CogitoQuestManager.quest_activated.connect(_on_quest_activated)
		CogitoQuestManager.quest_completed.connect(_on_quest_completed)
		CogitoQuestManager.quest_failed.connect(_on_quest_failed)
		CogitoQuestManager.quest_updated.connect(_on_quest_updated)
	#player_hud = get_parent()
	
	#Hooking up quest display to player inventory toggle.
	player_hud.show_inventory.connect(_show_quest_display)
	player_hud.hide_inventory.connect(_hide_quest_display)
	
	quest_display.hide()


func _exit_tree() -> void:
	if is_instance_valid(_quests):
		_quests.unbind_hud(_network_notification)


func _show_quest_display():
	update_active_quests()
	update_completed_quests()
	update_failed_quests()
	quest_display.show()
	
func _hide_quest_display():
	quest_display.hide()


func _network_notification(event: StringName, definition: CogitoQuest) -> void:
	_on_set_quest_notification(null, tr("QUEST_" + String(event)) + ": " + tr(definition.quest_title))


func _refresh_visible() -> void:
	if quest_display.visible:
		_show_quest_display()


func update_active_quests():
	_fill(active_group, CogitoQuest.QuestState.Active, CogitoQuestManager.active)


func update_completed_quests():
	_fill(completed_group, CogitoQuest.QuestState.Completed, CogitoQuestManager.completed)


func update_failed_quests():
	_fill(failed_group, CogitoQuest.QuestState.Failed, CogitoQuestManager.failed)


func _fill(group: VBoxContainer, state: CogitoQuest.QuestState, offline: CogitoQuestGroup) -> void:
	for node in group.get_children():
		group.remove_child(node)
		node.queue_free()
	var entries: Array[CogitoQuest] = _quests.entries(state) if _quests else offline.quests
	for quest in entries:
		var entry := quest_entry.instantiate() as QuestEntry
		group.add_child(entry)
		var flags: Dictionary = (
			_quests.journal_flags(quest.scope) if _quests else CogitoSceneManager._current_world_dict
		)
		entry.set_quest_info(quest, flags)


# Called when the node enters the scene tree for the first time.
func _on_set_quest_notification(passed_quest_icon, passed_quest_text):
	if send_quest_notifications:
		player_hud._on_set_hint_prompt(passed_quest_icon,passed_quest_text)


func _on_quest_activated(_passed_quest:CogitoQuest):
	_on_set_quest_notification(null, str( tr("QUEST_start") + ": " + tr(_passed_quest.quest_title) ))

func _on_quest_completed(_passed_quest:CogitoQuest):
	_on_set_quest_notification(null, str( tr("QUEST_complete") + ": " + tr(_passed_quest.quest_title) ))

func _on_quest_failed(_passed_quest:CogitoQuest):
	_on_set_quest_notification(null, str( tr("QUEST_fail") + ": " + tr(_passed_quest.quest_title) ))

func _on_quest_updated(_passed_quest:CogitoQuest):
	_on_set_quest_notification(null, str( tr("QUEST_update") + ": " + tr(_passed_quest.quest_title) ))
