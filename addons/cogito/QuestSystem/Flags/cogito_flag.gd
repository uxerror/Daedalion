## An abstract container for flags. Used for BooleanFlag, NumericFlag and InventoryFlag
@abstract @tool
extends Resource
class_name CogitoFlag

@abstract
func check(flags: Dictionary) -> bool
