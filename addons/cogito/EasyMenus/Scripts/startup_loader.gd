extends Node
#Loads options like volume and graphic options on game startup


func _ready():
	if CogitoNet.dedicated_boot:
		return
	CogitoGameConfig.load_options()
