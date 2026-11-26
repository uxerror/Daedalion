extends Node
## Session-wide authority and recipient journal. Reliable channel 0 orders admission and baselines.

## Server gameplay transition. Baselines and replica application never emit this signal.
signal committed(event: StringName, definition: CogitoQuest, owner_id: String)
## Fires only on the recipient of a live journal event, including the listen player.
signal notified(event: StringName, definition: CogitoQuest)
## Refresh an open journal, including silent restore and flag-only changes.
signal journal_changed
## Shared flags changed on authority or on a replica.
signal world_flags_changed

const Ledger := preload("net_quest_ledger.gd")
const STATE := CogitoQuest.QuestState
const OP := CogitoQuestUpdater.UpdateType

## Replace the shared inventory predicate (items, context) -> bool on the server.
var party_inventory_policy: Callable
## Optional server predicate (entry, quests) -> bool for a public quest drop.
var world_drop_policy: Callable
## Instigator of a synchronous validated interaction or hit (empty for world events).
var signal_subject := ""
var world := Ledger.new()
var personal: Dictionary[String, Ledger] = {}
var _shared_view := Ledger.new()
var _owner_view := Ledger.new()
var _hud: Callable
var _pending_hints: Array[Array] = []
var _pending: Array[Callable] = []
var _committing := false


## Locate the branch that owns a trigger, even with several level hosts in one process.
static func endpoint(node: Node) -> Node:
	var root := CogitoLevel.hosted_root(node)
	if root and root.has_meta(&"cogito_net_players"):
		return root.get_meta(&"cogito_net_players").quests
	if (
		CogitoNet.player_world
		and (not node.is_inside_tree() or node.multiplayer == CogitoNet.multiplayer)
	):
		return CogitoNet.player_world.quests
	return null


## Build the evaluation party from current admissions. Never consult client representations.
func evaluation_context(scope: CogitoQuest.Scope, subject_id: String) -> CogitoQuestContext:
	var context := CogitoQuestContext.new()
	context.scope = scope
	context.subject_id = subject_id
	context.party_inventory_policy = party_inventory_policy
	if multiplayer.is_server():
		var players := get_parent()
		for member in players.get_parent().records():
			var avatar: Variant = players.avatar_for(member.player_id)
			if avatar:
				context.party[member.player_id] = avatar.actor
	return context


## Write absolute shared world properties atomically. An unchanged setter is a no-op.
func set_world_flags(properties: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var changes := {}
	for key in properties:
		if not world.flags.has(key) or world.flags[key] != properties[key]:
			changes[key] = properties[key]
	if not changes.is_empty():
		_publish("", world, {}, changes, &"")


## Look up authoritative progress for gameplay. A missing personal subject has no progress.
func state_of(quest: CogitoQuest, subject_id := "") -> CogitoQuest.QuestState:
	var ledger := world
	if quest.scope == CogitoQuest.Scope.PERSONAL:
		ledger = personal.get(subject_id)
	if not ledger or not multiplayer.is_server():
		return STATE.NotStarted
	return ledger.quests.get(quest.resource_path, {}).get("state", STATE.NotStarted)


## World loot uses active shared quests. Override the predicate for game-specific drop rules.
func allows_world_drop(entry: LootDropEntry) -> bool:
	if world_drop_policy.is_valid():
		return world_drop_policy.call(entry, self)
	if entry.quest_definition:
		return state_of(entry.quest_definition) == STATE.Active
	for path: String in world.quests:
		if world.quests[path].state == STATE.Active:
			var quest := load(path) as CogitoQuest
			if "id" in quest and quest.get("id") == entry.quest_id:
				return true
	return false


## Run a server trigger for its durable instigator. A receipt makes an update one-shot.
func advance(
	quest: CogitoQuest,
	op: CogitoQuestUpdater.UpdateType,
	additions: Array[WorldFlag] = [],
	subject_id := "",
	receipt := "",
	start_if_available := false
) -> void:
	if not multiplayer.is_server():
		return
	if subject_id.is_empty():
		subject_id = signal_subject
	# A reward or listen HUD can synchronously start another quest during the start/update pair.
	_pending.append(_advance.bind(quest, op, additions, subject_id, receipt, start_if_available))
	if _committing:
		return
	_committing = true
	while not _pending.is_empty():
		var next: Callable = _pending.pop_front()
		next.call()
	_committing = false


func _advance(
	quest: CogitoQuest,
	op: CogitoQuestUpdater.UpdateType,
	additions: Array[WorldFlag],
	subject_id: String,
	receipt: String,
	start_if_available: bool
) -> void:
	if not quest:
		return
	if quest.resource_path.is_empty() or quest.resource_path.contains("::"):
		push_error("Online quests require a standalone authored Resource")
		return
	var owner_id := subject_id if quest.scope == CogitoQuest.Scope.PERSONAL else ""
	if quest.scope == CogitoQuest.Scope.PERSONAL and not _admitted(owner_id):
		return
	var ledger := world
	if not owner_id.is_empty():
		if not personal.has(owner_id):
			personal[owner_id] = Ledger.new()
		ledger = personal[owner_id]
	if not receipt.is_empty() and ledger.triggers.has(receipt):
		return
	var path := quest.resource_path
	var row: Dictionary = ledger.quests.get(path, {})
	var state: int = row.get("state", STATE.NotStarted)
	if state in [STATE.Completed, STATE.Failed] or (op == OP.Start and state == STATE.Active):
		return
	var working := Ledger.instance(quest, row)
	if state == STATE.NotStarted:
		if op != OP.Start and not (op == OP.Update and start_if_available):
			return
		_publish(owner_id, ledger, {path: Ledger.record(quest, working)}, {}, &"start")
	if op != OP.Start:
		if not receipt.is_empty():
			ledger.triggers[receipt] = true
		_update(quest, working, op, additions, owner_id, ledger, subject_id)


func _admitted(id: String) -> bool:
	return not get_parent().get_parent().for_id(id).is_empty()


func _update(
	definition: CogitoQuest,
	working: CogitoQuest,
	op: CogitoQuestUpdater.UpdateType,
	additions: Array[WorldFlag],
	owner_id: String,
	ledger: Ledger,
	subject_id: String
) -> void:
	var changes := {}
	var flags := world.flags.duplicate()
	flags.merge(ledger.flags, true)
	if op == OP.Fail:
		working.quest_state = STATE.Failed
	else:
		for flag in additions:
			var value: Variant = flag.value
			if flags.has(flag.flag_name) and not value is bool:
				value = int(flags[flag.flag_name]) + int(value)
			flags[flag.flag_name] = value
			changes[flag.flag_name] = value
		working.evaluate(flags, evaluation_context(definition.scope, subject_id))
	var path := definition.resource_path
	var row := Ledger.record(definition, working)
	if op == OP.Complete and row == ledger.quests[path]:
		return
	var event := &"update"
	if working.quest_state == STATE.Completed:
		event = &"complete"
	elif working.quest_state == STATE.Failed:
		event = &"fail"
	_publish(owner_id, ledger, {path: row}, changes, event)


func _publish(
	owner_id: String, ledger: Ledger, rows: Dictionary, changes: Dictionary, event: StringName
) -> void:
	var data := {"revision": ledger.revision + 1, "quests": rows, "flags": changes}
	ledger.apply(data, false)
	get_parent().mark_world_dirty()
	var session := get_parent().get_parent()
	# Finish remote sends before a synchronous listen HUD can start another event.
	for member in session.records():
		if member.peer_id != 1 and (owner_id.is_empty() or owner_id == member.player_id):
			_receive.rpc_id(member.peer_id, not owner_id.is_empty(), data, false, event)
	if not session.local_id.is_empty() and (owner_id.is_empty() or owner_id == session.local_id):
		_receive(not owner_id.is_empty(), data, false, event)
	if not event.is_empty():
		committed.emit(event, load(rows.keys()[0]), owner_id)
	if owner_id.is_empty() and not changes.is_empty():
		world_flags_changed.emit()


## Install current world and owner rows on admission or level re-entry, including remote levels.
func baseline(peer: int) -> void:
	var record: Dictionary = get_parent().get_parent().for_peer(peer)
	if record.is_empty() or not multiplayer.is_server():
		return
	var own: Ledger = personal.get(record.player_id)
	var private_data := own.snapshot() if own else {"revision": 0, "quests": {}, "flags": {}}
	if peer == 1:
		_receive(false, world.snapshot(), true, &"")
		_receive(true, private_data, true, &"")
	else:
		_receive.rpc_id(peer, false, world.snapshot(), true, &"")
		_receive.rpc_id(peer, true, private_data, true, &"")


@rpc("authority", "call_remote", "reliable", 0)
func _receive(private_scope: bool, data: Dictionary, full: bool, event: StringName) -> void:
	var view := _owner_view if private_scope else _shared_view
	if not view.apply(data, full):
		return
	journal_changed.emit()
	if not multiplayer.is_server() and not private_scope and (full or not data.flags.is_empty()):
		world_flags_changed.emit()
	if not full and not event.is_empty():
		var definition := load(data.quests.keys()[0]) as CogitoQuest
		notified.emit(event, definition)
		_play_audio(event, definition)
		if _hud.is_valid():
			_hud.call(event, definition)
		else:
			_pending_hints.append([event, definition])


## Deliver live hints received while the local avatar or level was loading.
func bind_hud(display: Callable) -> void:
	_hud = display
	for hint in _pending_hints:
		display.callv(hint)
	_pending_hints.clear()


## Retain incoming hints between local HUD instances.
func unbind_hud(display: Callable) -> void:
	if _hud == display:
		_hud = Callable()


func _play_audio(event: StringName, quest: CogitoQuest) -> void:
	var settings := CogitoGlobals.cogito_settings
	var cue: AudioStream
	var authored: AudioStream
	match event:
		&"start":
			cue = settings.quest_start_sound
			authored = quest.audio_on_start
		&"update":
			authored = quest.audio_on_update
		&"complete":
			cue = settings.quest_complete_sound
			authored = quest.audio_on_complete
		&"fail":
			cue = settings.quest_failed_sound
			authored = quest.audio_on_fail
	if authored:
		CogitoAudio.play_sound(authored)
	if cue:
		CogitoAudio.play_sound(cue, CogitoQuestManager.quest_audio_volume_db)


## Read a detached snapshot of the local journal. Dedicated has no local journal.
func journal(private_scope := false) -> Dictionary:
	return (_owner_view if private_scope else _shared_view).snapshot()


## Presentation only. Numeric descriptions of personal quests overlay their owner's flags.
func journal_flags(scope: CogitoQuest.Scope) -> Dictionary:
	var flags := _shared_view.flags.duplicate()
	if scope == CogitoQuest.Scope.PERSONAL:
		flags.merge(_owner_view.flags, true)
	return flags


## Build private display resources without invoking gameplay, rewards or audio.
func entries(state: CogitoQuest.QuestState) -> Array[CogitoQuest]:
	return _entries(state, [_shared_view, _owner_view])


## Server-side listing for legacy manager callers and game scripts with an explicit subject.
func authority_entries(state: CogitoQuest.QuestState, subject_id: String) -> Array[CogitoQuest]:
	if not multiplayer.is_server():
		return []
	var ledgers: Array[Ledger] = [world]
	if personal.has(subject_id):
		ledgers.append(personal[subject_id])
	return _entries(state, ledgers)


func _entries(state: CogitoQuest.QuestState, ledgers: Array[Ledger]) -> Array[CogitoQuest]:
	var result: Array[CogitoQuest] = []
	for view in ledgers:
		for path: String in view.quests:
			var row: Dictionary = view.quests[path]
			if row.state == state:
				result.append(Ledger.instance(load(path), row))
	return result
