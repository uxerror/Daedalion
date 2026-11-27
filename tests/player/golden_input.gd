extends CogitoPlayerInputSource
## Tick intervals are half-open. Axes are in actor space (negative Y is forward).

const ACTION := CogitoPlayerCommand.Action
const START := {
	"ground": Vector3.UP,
	"crouch": Vector3(3, 1, 0),
	"stairs": Vector3(-4, 1, 0),
	"slide": Vector3.UP,
	"ladder": Vector3(-10, 2, 0.2),
	"swim": Vector3(10, 11.3, 0),
	"ledge": Vector3(16, 1, 0),
	"roll": Vector3(0, 6, 0),
	"platform": Vector3(22, 1.8, 0),
	"seat": Vector3.UP,
	"toggle_roof": Vector3(3, 1, 0),
	"tired": Vector3.UP,
	"slide_expiry": Vector3.UP,
	"drop": Vector3(16, 2.57, -4.3),
	"high_jump": Vector3.UP,
	"sprint_wall": Vector3(16, 1, 0),
	"slide_late": Vector3.UP,
	"crouch_jump": Vector3.UP,
}
const LENGTH := {
	"ground": 220,
	"crouch": 245,
	"stairs": 165,
	"slide": 150,
	"ladder": 145,
	"swim": 245,
	"ledge": 150,
	"roll": 165,
	"platform": 135,
	"seat": 180,
	"toggle_roof": 130,
	"tired": 292,
	"slide_expiry": 230,
	"drop": 95,
	"high_jump": 165,
	"sprint_wall": 175,
	"slide_late": 175,
	"crouch_jump": 110,
}

var lane: String
var seat: CogitoSittable


func sample(actor: CogitoPlayer, sequence: int) -> CogitoPlayerCommand:
	var cmd := super.sample(actor, sequence)
	var t := sequence
	match lane:
		"ground":
			if t >= 20 and t < 110:
				cmd.move = Vector2.UP
			if t >= 65 and t < 110:
				cmd.held |= 1 << ACTION.SPRINT
			if t == 155:
				cmd.held |= 1 << ACTION.JUMP
		"crouch":
			cmd.toggle_crouch = t >= 198
			if t >= 20 and t < 80:
				cmd.held = 1 << ACTION.CROUCH
			if t >= 30 and t < 185:
				cmd.move = Vector2.UP
			if t in [200, 220]:
				cmd.add_edge(ACTION.CROUCH)
		"stairs":
			if t >= 20 and t < 82:
				cmd.move = Vector2.UP
			if t >= 82 and t < 155:
				cmd.move = Vector2.DOWN
		"slide":
			if t >= 20 and t < 88:
				cmd.move = Vector2.UP
				cmd.held = 1 << ACTION.SPRINT
			if t >= 60 and t < 85:
				cmd.held |= 1 << ACTION.CROUCH
			if t == 75:
				cmd.held |= 1 << ACTION.JUMP
		"ladder":
			if t >= 15 and t < 60:
				cmd.move = Vector2.UP
			if t >= 60 and t < 110:
				cmd.move = Vector2.DOWN
			if t == 80:
				cmd.held = 1 << ACTION.JUMP
		"swim":
			if t < 30 or (t >= 70 and t < 210):
				cmd.held = 1 << ACTION.JUMP
			if t >= 30 and t < 65:
				cmd.held = 1 << ACTION.CROUCH
			if t >= 70 and t < 220:
				cmd.move = Vector2.UP
		"ledge":
			if t >= 15 and t < 95:
				cmd.move = Vector2.UP
			if t >= 32 and t < 90:
				cmd.held = 1 << ACTION.JUMP
		"toggle_roof":
			cmd.toggle_crouch = true
			if t in [20, 70]:
				cmd.add_edge(ACTION.CROUCH)
			if t >= 30:
				cmd.move = Vector2.UP
		"tired":
			if t >= 20 and t < 156:
				cmd.move = Vector2.UP
				cmd.held = 1 << ACTION.SPRINT
			if t == 132:
				cmd.held |= 1 << ACTION.JUMP
		"slide_expiry", "slide_late":
			if t >= 20:
				cmd.move = Vector2.UP
				cmd.held = 1 << ACTION.SPRINT
			if t >= 60:
				cmd.held |= 1 << ACTION.CROUCH
			if t == (149 if lane == "slide_expiry" else 152):
				cmd.held |= 1 << ACTION.JUMP
		"sprint_wall":
			if t >= 20:
				cmd.move = Vector2.UP
				cmd.held = 1 << ACTION.SPRINT
			if t >= 42:
				cmd.held |= 1 << ACTION.JUMP
		"drop":
			if t >= 20:
				cmd.move = Vector2.UP
		"high_jump":
			if t == 25:
				cmd.held = 1 << ACTION.JUMP
			if t >= 28 and t < 88:
				cmd.move = Vector2.RIGHT
				cmd.yaw = 0.6
		"crouch_jump":
			if t >= 20 and t < 70:
				cmd.held = 1 << ACTION.CROUCH
			if t == 30:
				cmd.held |= 1 << ACTION.JUMP
		"seat":
			if t in [25, 65]:
				actor.player_interaction_component.targeting.interactable = seat
				cmd.add_edge(ACTION.INTERACT)
	return cmd
