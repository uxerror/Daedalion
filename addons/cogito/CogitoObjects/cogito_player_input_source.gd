class_name CogitoPlayerInputSource
extends RefCounted
## Override sample() to drive one actor. The default is stationary and preserves the actor's aim.


## Called before the player's state chart processes physics. Return a fresh, numbered command.
func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
	return actor.neutral_command(sequence)
