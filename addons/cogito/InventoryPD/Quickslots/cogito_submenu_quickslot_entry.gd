extends CogitoQuickslotEntry
class_name CogitoSubmenuQuickslotEntry

## Quickslot entry that opens another CogitoQuickslotSet as a submenu in the quickslot wheel.
## Any set can contain submenu entries, and submenus can contain submenu entries again,
## so games can build nested menus (for example Spells > Fire > ...) without code changes.
## The wheel enters the submenu on confirm (or after hovering it, see CogitoQuickslotWheel.submenu_hover_time)
## and shows a Back segment inside it.
## Outside the wheel (for example a quickslot key bound to this entry) activating it does nothing.

## The set this entry opens.
@export var submenu : CogitoQuickslotSet
## Icon of this entry. If empty, the submenu's icon is used.
@export var icon : Texture2D
## Name of this entry. If empty, the submenu's display_name is used.
@export var display_name : String = ""


func _init(passed_submenu: CogitoQuickslotSet = null) -> void:
	submenu = passed_submenu


func get_icon() -> Texture2D:
	if icon:
		return icon
	return submenu.icon if submenu else null


func get_display_name() -> String:
	if display_name != "":
		return display_name
	return submenu.display_name if submenu else ""


## A submenu without slots can't be entered.
func is_available() -> bool:
	return submenu != null and submenu.size() > 0


## Submenus are only navigated by the quickslot wheel, activating them does nothing. Returns false.
func activate(_context: Object) -> bool:
	return false
