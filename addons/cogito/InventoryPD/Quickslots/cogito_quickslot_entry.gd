extends Resource
class_name CogitoQuickslotEntry

## Base class for anything that can sit in a quickslot (an inventory item, a spell, an ability, an ammo type...).
## Extend this class and override the virtual methods below to put your own things into quickslots.
## Call emit_changed() whenever the displayed data changes (icon, count, availability...) so views refresh.
## This is a Resource so entries can also be authored in the inspector (e.g. a list of spells).


## Icon that views display for this entry.
func get_icon() -> Texture2D:
	return null


## Name of this entry, for example used for tooltips or radial menus.
func get_display_name() -> String:
	return ""


## Counter shown on the slot (stack size, ammo, charges...). Return -1 to show no counter.
func get_count() -> int:
	return -1


## If false, views show this entry as unavailable (for example greyed out).
func is_available() -> bool:
	return true


## If true, the quickslot set removes this entry the next time it emits changed (for example an empty item stack).
func is_expired() -> bool:
	return false


## Called when the quickslot holding this entry gets activated. Context is usually the player node.
## Returns true if the entry did something.
func activate(_context: Object) -> bool:
	return false
