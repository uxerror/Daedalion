extends RefCounted
## Creates the fade panel on the manager and runs its fade tweens.

const Manager := preload("cogito_scene_manager.gd")

var _manager: Manager


func _init(manager: Manager) -> void:
	_manager = manager


func instantiate_fade_panel() -> void:
	var panel := Panel.new()
	_manager.fade_panel = panel

	var black_stylebox := StyleBoxFlat.new()
	black_stylebox.bg_color = Color.BLACK

	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.focus_mode = Control.FOCUS_NONE
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_modulate(Color.TRANSPARENT)
	panel.add_theme_stylebox_override("panel", black_stylebox)

	_manager.add_child(panel)


func fade_in(fade_duration: float) -> void:
	_manager.fade_panel.set_modulate(Color.BLACK)
	var fade_tween := _manager.get_tree().create_tween()

	var step := fade_tween.tween_property(
		_manager.fade_panel, "modulate", Color.TRANSPARENT, fade_duration
	)
	step.set_trans(Tween.TRANS_CUBIC)
	await fade_tween.finished


func fade_out(fade_duration: float) -> void:
	_manager.fade_panel.set_modulate(Color.TRANSPARENT)
	var fade_tween := _manager.get_tree().create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)

	var step := fade_tween.tween_property(
		_manager.fade_panel, "modulate", Color.BLACK, fade_duration
	)
	step.set_trans(Tween.TRANS_CUBIC)
	await fade_tween.finished
