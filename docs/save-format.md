# Save format v2

A named slot or the working slot `temp` has one `player_state.v2.json` and one
`scene_<level root name>.v2.json` for each visited level. A slot can also contain
`screenshot.png`. The history index remains in `user://saves/saves.data`.

Each JSON document has the following top-level fields.

| Field | Value |
| --- | --- |
| `format` | `"daedalion-save"` |
| `version` | `2` |
| `kind` | `"player"` or `"scene"` |
| `engine` | `"4.7"` |
| `root` | A local reference, normally `{"$local": 0}` |
| `resources` | The file's table of resources saved by value |

## References and values

An external resource has the form `{"$res": "uid://…", "path": "res://…"}`.
The reader tries the current registered path for the UID, then the saved path.
An empty UID denotes an asset for which Godot supplied only a path. Project
filenames such as the saved level use the same reference inside `$file`, so the
path can be resolved before requesting the level on the loading thread.

A resource created at runtime or embedded inside another resource has an entry
in `resources`. The entry holds its native `class`, optional project `script`
reference, and storage `properties` in Godot setter order. Each occurrence of
that instance points to the same local ID within the document. For example,
a six-cell rifle can occupy six grid entries and a quickslot with one stack,
one quantity and one mutable item instance.

Strings, booleans, nulls, arrays and string-key dictionaries use JSON directly.
`$variant` holds Godot's native JSON representation for numbers, transforms,
vectors, colors, node paths and packed arrays. This preserves Variant types,
including integers outside the exact range of JSON doubles. `$pairs` preserves
non-string keys and keys starting with the reserved `$` prefix. `$array` and
`$dict` carry Godot collection type information. Live nodes, signals, callables
and RIDs are skipped with a warning. The JSON contains no serialized Objects.

## Loading and upgrades

The player and scene Resource classes remain the runtime models. A missing
asset produces a report entry with `path`, `uid` and `field`. A lost stack
leaves its inventory cells and quickslots empty. Applying the slot logs the
details and sends one hint through the player's interaction component.

Each state reader prefers its v2 file. If that file is absent, the reader opens
the configured legacy `.res` name with Godot's binary resource loader. On the
next save, the transaction writes the current player and scene in v2, converts
previously visited legacy scenes in staging, then publishes the generation.
An error during conversion aborts publication. Old binary files depend on the
historical paths that the original writer stored.

A newer header version fails preparation with `Save from a newer version.`.
Future data migrations can register one document-to-document callable per
source version in `MIGRATIONS`. Both formats validate the destination level
during preparation. The loading screen obtains and instantiates the PackedScene
before the manager replaces working files or frees the current scene.

## Starting a playthrough

New Game publishes an empty working generation and restores the configured initial
world and quest state before the first level enters the tree. It leaves named saves
and manual save history available. The active slot stays empty until the first
successful manual save or named load. Autosaves always use the configured
`auto_save_name` and do not select a manual slot.

The scene manager rejects overlapping loads and saves with `ERR_BUSY`. A transition
zone acquires the guard before saving the outgoing level and starting its fade.
Menus receive the load result while the previous scene can still release input.
The guard stays held until the new level has applied deferred state and positioned
the player at the connector. Levels with `save_temp_on_enter` then capture that state.

## Restart after death

Reload checks manual slots across the profile and the configured autosave, including
slots absent from the index. It skips empty or broken slots and the working `temp`
directory. The largest player save timestamp wins. A legacy save without a timestamp
uses its player file's modification time. Ties follow the most recent manual history
entry, then alphabetical manual directory order, then autosave. A missing screenshot
uses the placeholder.

With no loadable save, Reload starts a fresh playthrough at the current level's
entry with the configured initial world and starter items. A level without a file
path uses the configured first level. A failure to open or copy the selected save
keeps the death screen paused so the player can retry.
