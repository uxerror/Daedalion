@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoSwitch.svg")
class_name CogitoSwitch
extends Node3D

## Authoritative change observed by the bound level's replication endpoint.
signal net_changed(event: StringName)
signal object_state_updated(interaction_text: String) #used to display correct interaction prompts
signal switched(is_on: bool)
signal damage_received(damage_value:float)

#region Variables
@export var audio_stream_player_3d: AudioStreamPlayer3D

## Name that will displayed when interacting. Leave blank to hide
@export var display_name : String

enum PromptPositionMode{
	ORIGIN, ## at the objects origin point. Recommended for smaller objects.
	MARKER, ## at the position of an assigned Marker3D node. Will throw an error if no marker is assigned. Recommended for big objects/doors.
	AABB_CENTER, ## at the center of the calculated AABoundingBox. Works well but has a slight performance impact. 
}
## This sets where interaction prompt gets displayed on the object.
@export var prompt_pos_mode : PromptPositionMode = PromptPositionMode.ORIGIN
@export var prompt_marker : Marker3D

## Sets if object starts as on or off.
@export var is_on : bool = false
## Toggle if switchable can be interacted with repeatedly or not.
@export var allows_repeated_interaction : bool = true
## Hint that displays after this has been used.
@export var has_been_used_hint : String
@export var interaction_text_when_on : String = "SWITCH_off"
@export var interaction_text_when_off : String = "SWITCH_on"
## Sound that plays when switched.
@export var switch_sound : AudioStream
## Check this if player needs to have an item in the inventory to switch.
@export var needs_item_to_operate : bool
## The item that the player needs to have in their inventory.
@export var required_item_slot : InventorySlotPD
## Hint that gets displayed if the switch requires an item that the player currently doesn't have.
@export var item_hint : String
## Nodes that will become visible when switch is ON. These will hide again when switch is OFF.
@export var nodes_to_show_when_on : Array[Node]
## Nodes that will become hidden when switch is ON. These will show again when switch is OFF.
@export var nodes_to_hide_when_on : Array[Node]
## Nodes that will have their interact function called when this switch is used.
@export var objects_call_interact : Array[NodePath]
@export var objects_call_delay : float = 0.0


@export_group("Animation Settings")
## Node reference to the animation player. If no reference has been set, animations will be ignored.
@export var animation_player : AnimationPlayer
@export var anim_when_switched_on : String
@export var anim_when_switched_off : String
## You can use this to play a reverse animation (setting it to -1.0)
@export var animation_speed : float = 1.0


var interaction_text : String 
var player_interaction_component : PlayerInteractionComponent
var interaction_nodes : Array[Node]
var cogito_properties : CogitoProperties = null

var is_holding_item : bool

#endregion


func _ready():
	self.add_to_group("interactable")
	add_to_group("save_object_state")
	interaction_nodes = find_children("","InteractionComponent",true) #Grabs all attached interaction components
	
	if !audio_stream_player_3d:
		var players = find_children("", "AudioStreamPlayer3D")
		if len(players) > 0: audio_stream_player_3d = players[0]
	
	if audio_stream_player_3d:
		audio_stream_player_3d.stream = switch_sound
	
	if is_on:
		switch_on()
	else:
		switch_off()
		
	find_cogito_properties()
	
	
func find_cogito_properties():
	var property_nodes = find_children("","CogitoProperties",true) #Grabs all attached property components
	if property_nodes:
		cogito_properties = property_nodes[0]


func interact(_player_interaction_component):
	if is_inside_tree() and not multiplayer.is_server():
		return
	player_interaction_component = _player_interaction_component
	if !allows_repeated_interaction and is_on:
		player_interaction_component.send_hint(null, has_been_used_hint)
		return
		
	if !needs_item_to_operate:
		switch()
	else:
		if is_holding_item:
			# Logic to for the player to pick up the required item
			var inventory = player_interaction_component.get_inventory()
			inventory.pick_up_slot_data(required_item_slot)
			
			CogitoGlobals.debug_log(true,"cogito_switch.gd","Item " + required_item_slot.inventory_item.name + " added to player inventory")
			is_holding_item = false
			
			if is_on: switch_off()
			else: switch_on()
			call_interact_on_objects()
			
		else:
			if check_for_item():
				CogitoAudio.play_sound_3d_in(self, switch_sound, global_position)
				is_holding_item = true
				if is_on: switch_off()
				else: switch_on()
				call_interact_on_objects()


func switch():
	if is_inside_tree() and not multiplayer.is_server():
		return
	if audio_stream_player_3d: audio_stream_player_3d.play()
	if needs_item_to_operate and !is_holding_item:
		if !check_for_item():
			return
	
	if !is_on:
		switch_on()
	else:
		switch_off()
	
	call_interact_on_objects()


func call_interact_on_objects():
	if !objects_call_interact:
		return
	var instigator := player_interaction_component
	var needs_actor := is_instance_valid(instigator)
	var online := has_meta(&"cogito_net_world")
	var world: Node = get_meta(&"cogito_net_world") if online else null
	for nodepath in objects_call_interact:
		await get_tree().create_timer(objects_call_delay).timeout
		if nodepath != null:
			var object = get_node(nodepath)
			if not online:
				object.interact(player_interaction_component)
			elif is_instance_valid(world) and (not needs_actor or is_instance_valid(instigator)):
				world.activate_link(object, instigator)


func switch_on():
	if is_inside_tree() and not multiplayer.is_server():
		return
	for node in nodes_to_show_when_on:
		node.show()
		
	for node in nodes_to_hide_when_on:
		node.hide()
	
	if animation_player:
		animation_player.play(anim_when_switched_on,-1,animation_speed)
	
	is_on = true
	interaction_text = interaction_text_when_on
	object_state_updated.emit(interaction_text)
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"switch")
	switched.emit(is_on)


func switch_off():
	if is_inside_tree() and not multiplayer.is_server():
		return
	for node in nodes_to_show_when_on:
		node.hide()
		
	for node in nodes_to_hide_when_on:
		node.show()
		
	if animation_player:
		var clip := anim_when_switched_on
		if has_meta(&"cogito_net_world") and not anim_when_switched_off.is_empty():
			clip = anim_when_switched_off
		animation_player.play(clip, -1, animation_speed)
	
	is_on = false
	interaction_text = interaction_text_when_off
	object_state_updated.emit(interaction_text)
	if has_meta(&"cogito_net_world"):
		net_changed.emit(&"switch")
	switched.emit(is_on)


func check_for_item() -> bool:
	var inventory = player_interaction_component.get_inventory()
	for slot_data in inventory.inventory_slots:
		if slot_data and player_interaction_component.matches_item(
			slot_data.inventory_item, required_item_slot.inventory_item
		):
			player_interaction_component.send_hint(null, tr(required_item_slot.inventory_item.name) + " " + tr("HINT_SWITCH_item_used") ) # Sends a hint with the key item name.
			inventory.remove_item_from_stack(slot_data)
			return true
	
	if item_hint != "":
		player_interaction_component.send_hint(null,item_hint) # Sends the key hint with the default hint icon.
	return false


# Accepts every form of damage_received: (amount), (amount, source) and (amount, source, hit direction, hit position).
func _on_damage_received(_damage, source = null, _hit_direction := Vector3.ZERO, _hit_position := Vector3.ZERO):
	if has_meta(&"cogito_net_world"):
		if multiplayer.is_server() and source is CogitoPlayer:
			interact(source.player_interaction_component)
		return
	if source == self:
		return # Damage ticks of its own burning don't press it.
	interact(CogitoSceneManager.get_player().player_interaction_component)

func set_state():
	if is_on:
		for node in nodes_to_show_when_on:
			node.show()
		
		for node in nodes_to_hide_when_on:
			node.hide()
			
		interaction_text = interaction_text_when_on
	else:
		for node in nodes_to_show_when_on:
			node.hide()
		
		for node in nodes_to_hide_when_on:
			node.show()
			
		interaction_text = interaction_text_when_off
	
	object_state_updated.emit(interaction_text)

func save():
	var state_dict = {
		"node_path" : self.get_path(),
		"is_on" : is_on,
		"is_holding_item" : is_holding_item,
		"pos_x" : position.x,
		"pos_y" : position.y,
		"pos_z" : position.z,
		"rot_x" : rotation.x,
		"rot_y" : rotation.y,
		"rot_z" : rotation.z,
		
	}
	return state_dict

## Switch position and item latch replicated to interested observers.
func net_state() -> Dictionary:
	return {"on": is_on, "holding": is_holding_item}


## Apply local presentation without calling interact on linked objects.
func apply_net_state(state: Dictionary, silent: bool) -> void:
	is_on = state.on
	is_holding_item = state.holding
	interaction_text = interaction_text_when_on if is_on else interaction_text_when_off
	for node in nodes_to_show_when_on:
		node.visible = is_on
	for node in nodes_to_hide_when_on:
		node.visible = not is_on
	for component: InteractionComponent in interaction_nodes:
		component.interaction_text = interaction_text
	var clip := anim_when_switched_on
	if not is_on and not anim_when_switched_off.is_empty():
		clip = anim_when_switched_off
	if clip and animation_player:
		animation_player.play(clip, -1, animation_speed)
		if silent:
			animation_player.seek(animation_player.current_animation_length, true, true)
			animation_player.pause()


## One spatial switch sound for each live change.
func present_net_event(_event: StringName) -> void:
	if audio_stream_player_3d:
		audio_stream_player_3d.play()
