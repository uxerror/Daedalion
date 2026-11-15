extends Control
class_name CogitoQuickslotView

## Base class for UI that displays a CogitoQuickslotSet (a bar, a radial wheel...).
## Extend this class and override the _on_... methods to render the set.
## Views only display the set and call its API, they don't own the data.

## The set this view displays. Setting it reconnects the signals and refreshes the view.
var quickslot_set : CogitoQuickslotSet:
	set = set_quickslot_set


func set_quickslot_set(new_set: CogitoQuickslotSet) -> void:
	if quickslot_set:
		quickslot_set.slot_changed.disconnect(_on_slot_changed)
		quickslot_set.selection_changed.disconnect(_on_selection_changed)
		quickslot_set.slot_activated.disconnect(_on_slot_activated)
	quickslot_set = new_set
	if quickslot_set:
		quickslot_set.slot_changed.connect(_on_slot_changed)
		quickslot_set.selection_changed.connect(_on_selection_changed)
		quickslot_set.slot_activated.connect(_on_slot_activated)
	refresh()


## Redraws every slot and the selection.
func refresh() -> void:
	if !quickslot_set:
		return
	for i in quickslot_set.size():
		_on_slot_changed(i)
	_on_selection_changed(quickslot_set.selected_index)


## Virtual: the entry of a slot changed, redraw that slot.
func _on_slot_changed(_index: int) -> void:
	pass


## Virtual: the selected slot changed (-1 = no selection).
func _on_selection_changed(_index: int) -> void:
	pass


## Virtual: a slot was activated, for example to play feedback.
func _on_slot_activated(_index: int, _entry: CogitoQuickslotEntry) -> void:
	pass


## Virtual: CogitoQuickslots forwards the player's input to its views before handling quickslot actions.
## Return true to consume the event (for example to open a radial menu). Context is what CogitoQuickslots
## passes to CogitoQuickslotSet.activate() (usually the player).
func handle_quickslot_input(_event: InputEvent, _context: Object) -> bool:
	return false
