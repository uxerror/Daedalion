class_name CogitoNpcTargetPolicy
extends Resource
## Server-side selection among perceived players in this NPC's level.

## Score advantage required to abandon a visible current target.
@export_range(0.0, 1.0) var hysteresis := 0.15


## Override to exclude additional actors (for example, allies or disguised players).
func eligible(_npc: CogitoNPC, _actor: CogitoPlayerAdvanced) -> bool:
	return true


## Rows are keyed by durable player ID. Score, visible, distance and last_known are per actor.
## Return an empty ID to search. The caller validates the result against current candidates.
func choose(_npc: CogitoNPC, candidates: Dictionary, current: String) -> String:
	var best := ""
	var best_score := -INF
	var nearest := INF
	for id: String in candidates:
		var row: Dictionary = candidates[id]
		if not row.visible or row.score <= 0.0:
			continue
		var score := float(row.score) + (hysteresis if id == current else 0.0)
		var distance: float = row.distance
		if score > best_score or (score == best_score and distance < nearest):
			best = id
			best_score = score
			nearest = distance
		elif score == best_score and distance == nearest and id < best:
			best = id
	return best
