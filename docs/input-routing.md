Based on the Cogito wiki page Input routing (https://codeberg.org/Phazorknight/Cogito/wiki/Input-routing) by Philip Drobar and contributors, MIT.

# Input routing

`InputRouter` is an autoload installed by Cogito for Godot. It receives input events even when the tree is paused. Of the callbacks registered with the router, only the top one receives the next event. This lets an inventory, a readable or a minigame take control and then return it to the previous screen. Godot GUI events and direct polling of input still have their usual behaviour.

Use `InputRouter.push()` when opening a screen. Pushing the same callback again brings it to the top. `InputRouter.pop()` removes the current top callback. Use `InputRouter.remove()` with your own callback when a screen can close out of order or leave the tree. `InputRouter.is_input_active()` checks whether a node owns the active callback.

```gdscript
extends Control

func open_panel() -> void:
    show()
    InputRouter.push(on_panel_input)

func on_panel_input(event: InputEvent) -> void:
    if event.is_action_pressed("menu"):
        InputRouter.remove(on_panel_input)
        hide()

func _exit_tree() -> void:
    InputRouter.remove(on_panel_input)
```

The player forwards interaction events to `PlayerInteractionComponent`. Use the router for an interface that owns gameplay input. `InputHelper` is a separate autoload from [addons/input_helper](../addons/input_helper). It tracks devices and supplies rebinding and input-icon data. Define action names in Project Settings' Input Map and list the rebindable actions in `rebind_entries` on the active settings resource. The [quickslot wheel](quickslots.md) uses the same routing stack.

## Turn a spinner

On a [spinner interaction](../addons/cogito/Components/Interactions/SpinnerInteraction.gd), turn the stick or move the mouse in a circle. Relative mouse motion drives a virtual stick. With `mouse_requires_hold` enabled, hold `action_primary` while moving the mouse. Rotation follows the change in input angle. Adjust `mouse_stick_radius` for sensitivity and `mouse_dead_zone` or `stick_dead_zone` for the neutral region. `show_input_indicator` displays the input direction on screen so you can see where rotation begins.
