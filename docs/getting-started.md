Based on the Cogito wiki page Getting Started (https://codeberg.org/Phazorknight/Cogito/wiki/Getting-Started) by Philip Drobar and contributors, MIT.

# Getting started

Start with the whole Daedalion project if you can. It includes the input map, autoloads, translations and collision layers used by the demo. Open [project.godot](../project.godot) in Godot 4.7.2. Let the first import finish, then press **F5**. Choose New Game in the main menu to enter the Lobby. Open the [Laboratory](../addons/cogito/DemoScenes/COGITO_4_Laboratory.tscn) and press **F6** to try its examples directly.

## Make a level

1. Create a 3D scene and give its root a unique level name. Attach [cogito_scene.gd](../addons/cogito/SceneManagement/cogito_scene.gd) to the root. It registers the level as the parent for dropped items and stamps persistent objects when the level is ready.
2. Add a floor with collision. Instance [cogito_player_advanced.tscn](../addons/cogito/PackedScenes/cogito_player_advanced.tscn) above it. The scene already has a camera, attributes, interaction component and HUD.
3. Save the level and run it with **F6**. To enter from another level, add a marker to the destination's `connectors` array. Use its exact node name as the destination connector.
4. To start here from the menu, assign the level to `new_game_start_scene` on your active `CogitoSettings` resource. Use `new_game_world_state` and `new_game_starter_items` to set the initial flags and inventory.

Try adding a door before building a whole room. Look at the door's collision body, mesh and interaction component. The body owns the door behaviour. The component supplies the input action and text that appear when the player faces it. [Build an interactive object](interactions.md).

## Bring the addon into another project

In **Project > Project Settings > Plugins**, enable the bundled Input Helper, Godot State Charts and Cogito for Godot plugins. The latter installs the gameplay autoloads, including `CogitoAudio` and `InputRouter`. gdUnit4 runs the [tests](testing.md). Compare your project's input actions, 3D physics layers and audio buses with the template.

Set `cogito/settings/settings_file` to your own copy of [CogitoSettings.tres](../addons/cogito/CogitoSettings.tres). The addon can run without the demo directory. The supplied project selects [DemoCogitoSettings.tres](../addons/cogito/DemoScenes/DemoCogitoSettings.tres) and boots [COGITO_0_MainMenu.tscn](../addons/cogito/DemoScenes/COGITO_0_MainMenu.tscn). Set your project's main scene and starting level before removing the demo.

For a fresh input map, select the settings resource in the Inspector. **Danger Zone > Reset Project Input Map** overwrites bindings for template actions. Keep a copy of custom bindings first and restart the project afterwards. Enable `is_logging` on the active settings resource to see gameplay diagnostics in Output.

If the UI displays translation keys, open **Project Settings > Localization > Translations** and add [cogito_en.po](../addons/cogito/Localization/po_files/cogito_en.po) and [cogito_de.po](../addons/cogito/Localization/po_files/cogito_de.po).
