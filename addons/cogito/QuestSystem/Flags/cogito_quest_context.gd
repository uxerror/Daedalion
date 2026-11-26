class_name CogitoQuestContext
extends RefCounted
## Inputs for one server evaluation. Party contains admitted identities with live server actors.

var scope: CogitoQuest.Scope
var subject_id: String
var party: Dictionary[String, CogitoPlayer] = {}
## Optional shared condition (items, context) -> bool. Personal conditions always use the subject.
var party_inventory_policy: Callable


## Check a single inventory flag with the same name comparison as offline.
func holds(item: InventoryItemPD) -> bool:
	return holds_all([item])


## The same eligible member must possess every required item in an AND group.
func holds_all(items: Array[InventoryItemPD]) -> bool:
	if scope == CogitoQuest.Scope.PERSONAL:
		return _holds(party.get(subject_id), items)
	if party_inventory_policy.is_valid():
		return party_inventory_policy.call(items, self)
	for actor in party.values():
		if _holds(actor, items):
			return true
	return false


func _holds(actor: CogitoPlayer, items: Array[InventoryItemPD]) -> bool:
	if not actor or not actor.inventory_data:
		return false
	for item in items:
		if not item or actor.inventory_data.find_slots(item.name).is_empty():
			return false
	return true
