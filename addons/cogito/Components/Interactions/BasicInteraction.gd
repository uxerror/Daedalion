extends InteractionComponent

signal basic_signal

var player_interaction_component : PlayerInteractionComponent

@onready var parent_node = get_parent() #Grabbing reference to parent

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if parent_node.has_signal("object_state_updated"):
		parent_node.object_state_updated.connect(_on_object_state_change)

func interact(_player_interaction_component: PlayerInteractionComponent):
	player_interaction_component = _player_interaction_component
	if !attribute_check != AttributeCheck.NONE:
		if parent_node.has_method("interact"):
			parent_node.interact(_player_interaction_component)

		was_interacted_with.emit(interaction_text,input_map_action)
		basic_signal.emit()
		
	else:
		if check_attribute(_player_interaction_component):
			if parent_node.has_method("interact"):
				parent_node.interact(_player_interaction_component)

			was_interacted_with.emit(interaction_text,input_map_action)


func _on_object_state_change(_interaction_text: String):
	interaction_text = _interaction_text
	if player_interaction_component:
		player_interaction_component.targeting.rebuild_interaction_prompts()


## A keypad has a second, explicit action available through its local UI.
func get_actions(actor: PlayerInteractionComponent) -> Array[CogitoInteractionAction]:
	var actions := super.get_actions(actor)
	if parent_node is CogitoKeypad and actor and actor.network_interactions:
		var submit := CogitoInteractionAction.new(
			interaction_text, self, interact, not is_disabled, &"submit_code"
		)
		actions.append(submit)
	return actions


## Only the code submission action accepts wire data.
func net_payload_schema(action: StringName) -> StringName:
	return &"digits" if parent_node is CogitoKeypad and action == &"submit_code" else &""
