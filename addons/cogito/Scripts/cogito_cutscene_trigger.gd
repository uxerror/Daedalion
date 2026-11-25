extends Area3D
class_name CogitoCutsceneTrigger

## Publishes consumed trigger state. Camera playback is a separate private event.
signal net_changed(event: StringName)

## The animation player containing the cutscene to play
@export var cutscene_animation_player : AnimationPlayer
## Name of the cutscene to play
@export var cutscene_animation_name : String
## If true, the player can cancel the cutscene by pressing the UI_cancel input map action.
@export var allow_cancel : bool = false
## If true, this cutscene allows repeat triggering
@export var allow_repeat : bool = false
## If true, the player HUD will be hidden while playing the cutscene.
@export var hide_hud : bool = true

var player_reference : CogitoPlayer
var has_been_triggered : bool = false #Used to avoid double-triggering.
var cutscene_timer : Timer = Timer.new()
var _net_monitoring := false
var _hud_was_visible := false

func _ready() -> void:
	add_to_group("save_object_state")
	cutscene_timer.one_shot = true
	cutscene_timer.timeout.connect(finish_cutscene)
	self.add_child(cutscene_timer)
	
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func on_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and allow_cancel:
		if has_meta(&"cogito_net_world"):
			player_reference.player_interaction_component.network_interactions.devices.dismiss()
		else:
			finish_cutscene()


func _on_body_entered(body: Node3D):
	if body is not CogitoPlayer:
		return
	if body.network_movement_only:
		if has_meta(&"cogito_net_world") and multiplayer.is_server():
			var api: Node = body.player_interaction_component.network_interactions
			if api:
				api.devices.enter_cutscene(self, body)
		return
	if not body.is_local_presentation:
		return
	
	player_reference = body
	play_cutscene()


func _on_body_exited(body: Node3D):
	if body is not CogitoPlayer:
		return


## Authority decides eligibility, including once-only triggers restored from a save.
func net_available() -> bool:
	return (
		(allow_repeat or not has_been_triggered) and cutscene_animation_player
		and cutscene_animation_player.has_animation(cutscene_animation_name)
	)


## Consume a validated entry immediately and time it on the authority clock.
func net_consume() -> float:
	has_been_triggered = true
	net_changed.emit(&"")
	var clip := cutscene_animation_player.get_animation(cutscene_animation_name)
	return clip.length / maxf(absf(cutscene_animation_player.speed_scale), 0.001)


## Only the authority monitors network avatars in this area.
func net_bind_replica() -> void:
	_net_monitoring = monitoring
	monitoring = false


## Restore the authored area if the level remains open after a session.
func net_unbind() -> void:
	if _net_monitoring:
		monitoring = true
		_net_monitoring = false


## Baselines carry only the consumed bit.
func net_state() -> Dictionary:
	return {"triggered": has_been_triggered}


## Restore eligibility without taking over a camera.
func apply_net_state(state: Dictionary, _silent: bool) -> void:
	has_been_triggered = state.triggered


## Start this peer's private camera and animation.
func net_play(actor: CogitoPlayer) -> void:
	player_reference = actor
	InputRouter.push(on_input)
	if hide_hud:
		_hud_was_visible = actor.player_hud.visible
		actor.player_hud.hide()
	cutscene_animation_player.play(cutscene_animation_name)


## Return the owner's input context and camera.
func net_stop() -> void:
	cutscene_animation_player.stop()
	if hide_hud:
		player_reference.player_hud.visible = _hud_was_visible
	player_reference.camera.make_current()
	InputRouter.remove(on_input)
	player_reference = null


func play_cutscene() -> void:
	if has_been_triggered and !allow_repeat:
		return
	if !cutscene_animation_player or !cutscene_animation_name:
		return
	
	print("Cutscene started.")
	InputRouter.push(on_input)
	
	if hide_hud:
		player_reference.player_hud.set_visible(false)
	

	cutscene_animation_player.play(cutscene_animation_name)
	cutscene_timer.wait_time = cutscene_animation_player.current_animation_length
	cutscene_timer.start()


func finish_cutscene() -> void:
	print("Cutscene finished.")
	cutscene_timer.stop()
	cutscene_animation_player.stop()
	has_been_triggered = true
	if hide_hud:
		player_reference.player_hud.set_visible(true)
	player_reference.camera.make_current()
	InputRouter.pop()



func set_state() -> void:
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
