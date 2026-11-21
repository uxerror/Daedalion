extends Resource
class_name CogitoQuickslotSet

## A set of quickslots: N slots that each hold a CogitoQuickslotEntry (or null if empty), plus a selected slot.
## This is only data, views (CogitoQuickslotView) display it and input code calls bind/select/activate on it.

## Emitted when the entry of a slot got bound, unbound or its data changed (for example its stack amount).
signal slot_changed(index: int)
## Emitted when the selected slot changes. -1 means nothing is selected.
signal selection_changed(index: int)
## Emitted after the entry of a slot got activated successfully.
signal slot_activated(index: int, entry: CogitoQuickslotEntry)

## Name of this set, views can show it as a title (the quickslot wheel shows it while nothing is hovered).
@export var display_name : String = ""
## Icon of this set, for example on the quickslot wheel segment that opens it (see CogitoSubmenuQuickslotEntry).
@export var icon : Texture2D
## The entries of this set, one per slot. Empty slots are null.
@export var entries : Array[CogitoQuickslotEntry] = []:
	set(value):
		var old_entries := entries
		entries = value
		for entry in old_entries:
			_disconnect_entry(entry)
		for entry in entries:
			_connect_entry(entry)
		for i in entries.size():
			slot_changed.emit(i)
		if selected_index >= entries.size():
			select(-1)

## Index of the selected slot, -1 if nothing is selected.
var selected_index : int = -1


## Returns the number of slots.
func size() -> int:
	return entries.size()


## Changes the number of slots. New slots are empty, entries of removed slots get unbound.
func resize(new_size: int) -> void:
	var old_size := entries.size()
	if new_size == old_size:
		return
	for i in range(new_size, old_size):
		var entry := entries[i]
		entries[i] = null
		_disconnect_entry(entry)
	entries.resize(new_size)
	for i in range(old_size, new_size):
		slot_changed.emit(i)
	if selected_index >= new_size:
		select(-1)


## Returns the entry of a slot, or null if the slot is empty or doesn't exist.
func get_entry(index: int) -> CogitoQuickslotEntry:
	if index < 0 or index >= entries.size():
		return null
	return entries[index]


## Puts an entry into a slot (replacing what was in it). Binding null empties the slot.
func bind(index: int, entry: CogitoQuickslotEntry) -> void:
	if index < 0 or index >= entries.size():
		CogitoGlobals.debug_log(true, "cogito_quickslot_set.gd", "bind(): index " + str(index) + " is out of range.")
		return
	var old_entry := entries[index]
	entries[index] = entry
	if old_entry != entry:
		_disconnect_entry(old_entry)
		_connect_entry(entry)
	slot_changed.emit(index)


## Empties a slot.
func unbind(index: int) -> void:
	bind(index, null)


## Empties all slots.
func clear() -> void:
	for i in entries.size():
		if entries[i]:
			unbind(i)


## Returns the indexes of all non-empty slots whose entry passes the filter.
## The filter is an optional Callable(entry: CogitoQuickslotEntry) -> bool.
func find_indexes(filter: Callable = Callable()) -> Array[int]:
	var result : Array[int] = []
	for i in entries.size():
		if _matches(i, filter):
			result.append(i)
	return result


## Selects a slot, -1 to clear the selection.
func select(index: int) -> void:
	if index < -1 or index >= entries.size():
		index = -1
	if index == selected_index:
		return
	selected_index = index
	selection_changed.emit(selected_index)


## Selects the next non-empty slot after the selected one that passes the filter (see find_indexes()).
## If nothing is selected, the search starts at the first slot.
## If wrap is false and the end is reached, or no slot passes the filter, the selection gets cleared.
## Returns the new selected index, or -1.
func select_next(filter: Callable = Callable(), wrap: bool = true) -> int:
	return _select_step(1, filter, wrap)


## Same as select_next() but going backwards. If nothing is selected, the search starts at the last slot.
func select_previous(filter: Callable = Callable(), wrap: bool = true) -> int:
	return _select_step(-1, filter, wrap)


## Activates the entry of a slot. Returns true if the entry did something.
func activate(index: int, context: Object = null) -> bool:
	var entry := get_entry(index)
	if !entry:
		return false
	if !entry.activate(context):
		return false
	slot_activated.emit(index, entry)
	return true


## Activates the entry of the selected slot.
func activate_selected(context: Object = null) -> bool:
	return activate(selected_index, context)


func _select_step(direction: int, filter: Callable, wrap: bool) -> int:
	var slot_count := entries.size()
	var start := selected_index
	if start == -1:
		start = -1 if direction > 0 else slot_count
	for step in range(1, slot_count + 1):
		var index := start + direction * step
		if index < 0 or index >= slot_count:
			if !wrap:
				break
			index = posmod(index, slot_count)
		if _matches(index, filter):
			select(index)
			return index
	select(-1)
	return -1


func _matches(index: int, filter: Callable) -> bool:
	var entry := entries[index]
	if !entry:
		return false
	return !filter.is_valid() or filter.call(entry)


func _connect_entry(entry: CogitoQuickslotEntry) -> void:
	if entry and !_is_entry_connected(entry):
		entry.changed.connect(_on_entry_changed.bind(entry))


func _is_entry_connected(entry: CogitoQuickslotEntry) -> bool:
	for connection in entry.changed.get_connections():
		if connection.callable.get_object() == self:
			return true
	return false


func _disconnect_entry(entry: CogitoQuickslotEntry) -> void:
	# The same entry can sit in several slots, only disconnect once it's gone from all of them.
	if !entry or entries.has(entry):
		return
	for connection in entry.changed.get_connections():
		if connection.callable.get_object() == self:
			entry.changed.disconnect(connection.callable)


func _on_entry_changed(entry: CogitoQuickslotEntry) -> void:
	for i in entries.size():
		if entries[i] != entry:
			continue
		if entry.is_expired():
			CogitoGlobals.debug_log(true, "cogito_quickslot_set.gd", "Entry in slot " + str(i) + " expired, unbinding it.")
			unbind(i)
		else:
			slot_changed.emit(i)
