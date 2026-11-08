@tool
extends EditorProperty

# Flag Fetcher utility script ref
var flag_fetcher

# The main control for editing the property.
var _property_control:LineEdit = LineEdit.new()
# drop down button for the popup menu
var _dropdown_button:Button = Button.new()
# popup menu with event names
var _popup_menu:PopupMenu = PopupMenu.new()


func _init(fetcher) -> void:	
	# Assign the const instance from the plugin script
	flag_fetcher = fetcher
		
	# setup the ui
	_popup_menu.index_pressed.connect(_on_flag_selected)
	
	_dropdown_button.tooltip_text = "Show list of known CogitoFlag names"
	_dropdown_button.icon = get_theme_icon("arrow", "OptionButton")
	_dropdown_button.flat = true
	_dropdown_button.pressed.connect(_show_popup)
	
	# build the actual editor
	var hbox := HBoxContainer.new()
	hbox.add_child(_property_control)
	hbox.add_child(_dropdown_button)
	_property_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Add the control as a direct child of EditorProperty node.
	add_child(hbox)
	add_child(_popup_menu)
	
	# Make sure the control is able to retain the focus.
	add_focusable(_property_control)
	_property_control.text_changed.connect(_on_text_changed)


## Shows the popup when the user clicks the button.
func _show_popup() -> void:
	# always show up-to-date information in selector
	var known_flags = flag_fetcher.fetch_all_flags(get_tree())
	
	_popup_menu.clear()
	
	if known_flags.size() > 0:
		_popup_menu.add_separator()
	
	for flag in known_flags:
		_popup_menu.add_item(flag)
	
	# and show it relative to the dropdown button
	var gt := _dropdown_button.get_global_rect()
	_popup_menu.reset_size()
	var ms := _popup_menu.get_contents_minimum_size().x
	var popup_pos := gt.end - Vector2(ms, 0) + Vector2(DisplayServer.window_get_position())
	_popup_menu.set_position(popup_pos)
	_popup_menu.popup()


func _on_flag_selected(index:int) -> void:
	# replace content with selection from popup
	var flag := _popup_menu.get_item_text(index) if index > 0 else ""
	_property_control.text = flag
	_on_text_changed(flag)
	_property_control.grab_focus()


func _on_text_changed(new_text:String) -> void:
	emit_changed(get_edited_property(), new_text)


func _update_property() -> void:
	# Read the current value from the property.
	var new_value = get_edited_object()[get_edited_property()]
	
	# if the text is already correct, don't change it.	
	if new_value == _property_control.text:
		return

	_property_control.text = new_value
