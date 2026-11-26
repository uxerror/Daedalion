## An abstract container for flags. Used for BooleanFlag, NumericFlag and InventoryFlag
@abstract @tool
extends Resource
class_name CogitoFlag

@abstract
func check(flags: Dictionary) -> bool


## Override for conditions that depend on the party or subject. Pure flag predicates can use check.
func check_in_context(flags: Dictionary, _context: CogitoQuestContext) -> bool:
	return check(flags)
