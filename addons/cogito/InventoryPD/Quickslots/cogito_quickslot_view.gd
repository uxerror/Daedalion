extends Control
class_name CogitoQuickslotView

## Base class for UI that displays a CogitoQuickslotSet (a bar, a radial wheel...).
## Extend this class and override the _on_... methods to render the set.
## Views only display the set and call its API, they don't own the data.

## If true, CogitoQuickslots gives this view the equipped wieldable's own set (CogitoWieldable.get_quickslot_set(), for example
## its ammo types) as context_set while the wieldable offers one. quickslot_set stays the inventory set.
## The default quickslot wheel uses this. The quickslot bar (CogitoQuickslots itself) only shows the inventory set.
@export var shows_wieldable_set : bool = false

## The set this view displays. Setting it reconnects the signals and refreshes the view.
var quickslot_set : CogitoQuickslotSet:
	set = set_quickslot_set
## An additional set that belongs to the current situation (the equipped wieldable's set, see shows_wieldable_set), or null.
## Views decide how to offer it, the quickslot wheel shows it as a submenu. Views that don't support it ignore it.
var context_set : CogitoQuickslotSet:
	set = set_context_set
## Slot of quickslot_set that owns context_set (for example the quickslotted wieldable that offers it), -1 if none.
## The quickslot wheel enters context_set through that slot. Set by CogitoQuickslots (see get_view_context_slot()).
var context_slot_index : int = -1:
	set = set_context_slot_index


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


## Virtual: override to react to a new context_set (call super).
func set_context_set(new_set: CogitoQuickslotSet) -> void:
	context_set = new_set


## Virtual: override to react to a new context_slot_index (call super).
func set_context_slot_index(new_index: int) -> void:
	context_slot_index = new_index


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
