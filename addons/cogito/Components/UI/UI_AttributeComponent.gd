class_name CogitoAttributeUi
extends Control

var _restored_value := 0.0

@onready var attribute_icon: TextureRect = $HBoxContainer/AttributeIcon
@onready var attribute_bar: CogitoDynamicBar = $HBoxContainer/AttributeBar
@onready var attribute_label: Label = $HBoxContainer/AttributeLabel

@export var bar_stylebox: StyleBoxFlat

var assigned_player_attribute : CogitoAttribute


func initiate_attribute_ui(_player_attribute: CogitoAttribute):
	assigned_player_attribute = _player_attribute
	
	#Setting up icon, bar and label
	attribute_icon.texture = assigned_player_attribute.attribute_icon
	attribute_label.text = str(int(assigned_player_attribute.value_current))
	bar_stylebox.bg_color = assigned_player_attribute.attribute_color
	attribute_bar.add_theme_stylebox_override("fill",bar_stylebox)

	#Setting bar to correct values
	#attribute_bar.max_value = assigned_player_attribute.value_max
	#attribute_bar.value = assigned_player_attribute.value_current
	
	attribute_bar.init_values(assigned_player_attribute.value_current, assigned_player_attribute.value_max)
	
	_player_attribute.attribute_changed.connect(on_attribute_changed)
	_player_attribute.attribute_restored.connect(_on_attribute_restored)
	_restored_value = _player_attribute.value_current


## Network replicas only receive values. Infer the direction there so bars shown on a
## decrease (stamina) appear online; offline restores keep their "increased" meaning.
func _on_attribute_restored(_attribute_name: String, _value_current: float, _value_max: float):
	var increased := true
	if assigned_player_attribute.network_frozen:
		increased = _value_current >= _restored_value
	_restored_value = _value_current
	on_attribute_changed(_attribute_name, _value_current, _value_max, increased)


	
	
func on_attribute_changed(_attribute_name:String,_value_current:float,_value_max:float,_has_increased:bool):
	attribute_bar.update_value(_value_current, _value_max)
	#attribute_bar.max_value = _value_max
	#attribute_bar.value = _value_current
	attribute_label.text = str(int(_value_current))
