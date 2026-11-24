class_name CogitoInteractionAction
extends RefCounted
## One thing a player can do with an interactable, as listed by InteractionComponent.get_actions().
## Lets other controllers offer an object's actions directly, for example in a context menu, instead of through
## input actions and hold timing. Run it with PlayerInteractionComponent.perform_action().

## Stable key within the component, independent of translation and UI order.
var action_id: StringName
## Text to show for the action, like the interaction prompt.
var text : String
## The component the action belongs to.
var component : InteractionComponent
## False if the action can't be done right now, for example unlocking a door without its key.
var enabled : bool

# Called with the PlayerInteractionComponent.
var _perform : Callable


func _init(
	action_text: String, action_component: InteractionComponent, perform_callable: Callable,
	is_enabled: bool = true, key: StringName = &""
) -> void:
	action_id = key
	if action_id.is_empty() and action_component:
		action_id = StringName(action_component.input_map_action)
		if action_id.is_empty():
			action_id = &"interact"
	text = action_text
	component = action_component
	_perform = perform_callable
	enabled = is_enabled


func perform(player_interaction_component: PlayerInteractionComponent) -> void:
	await _perform.call(player_interaction_component)
