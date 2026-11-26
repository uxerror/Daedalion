# Quests and objectives

Create a `CogitoQuest` resource and add its objectives in journal order. Each
`CogitoQuestObjective` has a description, an initial state and groups of reveal,
completion and failure conditions. Use a single flag for one condition or a
`MultiFlagGroup` for conditions that must all hold. Alternative completion groups
can each satisfy the objective. Use a numeric flag to show progress such as
`TargetsShot` in the Laboratory.

Attach a `CogitoQuestUpdater` to an area or an object and assign the quest. Connect
the gameplay signal to the updater. **Start** activates the quest. **Update** starts
it if needed, applies the authored flags and evaluates its objectives. Mark an
objective **Required to Complete** when its success or failure should decide the
quest outcome. In single-player the manager's groups and the world's flag
dictionary are restored with the player save.

## Multiplayer

**Scope** defaults to **Shared**. Either player can advance the Laboratory's target
practice or the Lobby laptop delivery. Choose **Personal** for a quest like the
Lobby archive, where each player can independently perform the same task. Pass the
server actor to a custom personal trigger. Connected recipients hear live cues and
see journal updates. Joining or reconnecting restores the current journal silently.
For the trigger API, inventory policy and replication protocol, see
[Quests and world flags](networking.md#quests-and-world-flags).
