@abstract class_name CogitoHud
extends Control
## What the rest of Cogito expects from a player's HUD. CogitoPlayerHudManager implements it for Cogito's first person
## player. A HUD for another kind of player extends this and implements every method, so nothing is silently missing.

## Emitted when the inventory interface opens.
signal show_inventory
## Emitted when the inventory interface closes.
signal hide_inventory


## Shows the hold progress for a hold interaction (HoldInteraction, DualInteraction, ExtendedPickupInteraction).
@abstract func start_hold(hold_interaction: HoldInteraction) -> void
## True while a hold interaction is in progress.
@abstract func is_holding() -> bool

## Opens the inventory interface, or closes it if it is open. Pass a container to show its inventory next to the player's.
@abstract func toggle_inventory_interface(external_inventory_owner = null)
## Opens or closes the inventory interface, optionally with a container's inventory.
@abstract func set_inventory_visibility(visible: bool, external_inventory: CogitoContainer = null) -> void
## True while the inventory interface is open.
@abstract func is_inventory_visible() -> bool

## The container whose inventory is shown in the inventory interface, or null.
@abstract func get_external_inventory()
## Shows this container's inventory in the open inventory interface.
@abstract func set_external_inventory(external_inventory_owner) -> void
## Stops showing a container's inventory in the inventory interface.
@abstract func clear_external_inventory() -> void
