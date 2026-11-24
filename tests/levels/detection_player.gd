extends CogitoPlayer
## Stationary sight target with the same body and head contract as a playable controller.


func create_new_state() -> CogitoPlayerState:
	return CogitoPlayerAdvancedState.new()
