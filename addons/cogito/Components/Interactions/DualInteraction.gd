class_name DualInteraction
extends HoldInteraction

signal on_quick_press(player_interaction_component:PlayerInteractionComponent)
signal on_hold_complete(player_interaction_component:PlayerInteractionComponent)
signal interaction_complete(player_interaction_component: PlayerInteractionComponent)

##Text that joins Press and Hold interaction text, for example:   " | (HOLD) " in  "Open | (HOLD) Unlock"
@export var interaction_text_joiner: String = "INTERACT_hold_joiner"
##Hold node location, used for "start_hold_check" function which must return true if a hold can start. Used to prevent hold interaction without Key
@export var hold_node : Node

var press_interaction_text: String
var hold_interaction_text: String


func _ready() -> void:
	if parent_node.has_signal("object_state_updated"):
		parent_node.object_state_updated.connect(_on_object_state_change)
	if parent_node.has_signal("lock_state_updated"):
		parent_node.lock_state_updated.connect(_lock_state_updated)


func interact(_player_interaction_component):
	was_interacted_with.emit(interaction_text,input_map_action)
	player_interaction_component = _player_interaction_component
	check_before_hold_start(_player_interaction_component)


#Runs check before allowing hold to start, currently used to stop lock/unlock hold interaction if key not present.
func check_before_hold_start(_player_interaction_component):
	var hud: CogitoHud = _player_interaction_component.get_hud()
	
	if hold_node and hold_node.has_method("start_hold_check"):
		if hold_node.start_hold_check(_player_interaction_component):
			hud.start_hold(self)
		else:
			parent_node.interact(_player_interaction_component) 
	else:
		hud.start_hold(self)


func perform_quick_action(_player_interaction_component: PlayerInteractionComponent) -> void:
	on_quick_press.emit(_player_interaction_component)


func perform_hold_action(_player_interaction_component: PlayerInteractionComponent) -> void:
	on_hold_complete.emit(_player_interaction_component)


## The press action and the hold action. The hold action is disabled when hold_node says it can't start,
## for example a lock without its key.
func get_actions(_player_interaction_component: PlayerInteractionComponent) -> Array[CogitoInteractionAction]:
	var can_hold := true
	if hold_node and hold_node.has_method("can_start_hold"):
		can_hold = hold_node.can_start_hold(_player_interaction_component)
	var press_text := press_interaction_text if press_interaction_text else interaction_text
	var hold_text := hold_interaction_text if hold_interaction_text else interaction_text
	return [
		CogitoInteractionAction.new(press_text, self, perform_quick_action, !is_disabled, &"press"),
		CogitoInteractionAction.new(
			hold_text, self, perform_hold_action, !is_disabled and can_hold, &"hold"
		),
	]


func _on_object_state_change(_interaction_text: String):
	press_interaction_text = _interaction_text
	update_interaction_text()

func _lock_state_updated(lock_interaction_text: String):
	hold_interaction_text = lock_interaction_text
	update_interaction_text()

func update_interaction_text():
	interaction_text = tr(press_interaction_text) + tr(interaction_text_joiner) + tr(hold_interaction_text)
	interaction_complete.emit(player_interaction_component) #Signal to rebuild interaction prompt after text updated
