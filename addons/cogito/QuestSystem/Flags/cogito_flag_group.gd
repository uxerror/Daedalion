## A generic flag group. Do NOT use this when creating flag groups, instead use
## either SingleFlagGroup or MultiFlagGroup
@abstract @tool
extends Resource
class_name CogitoFlagGroup

@abstract
func get_flag_names() -> Array[String]

@abstract
func meets_criteria(quest_flags: Dictionary) -> bool
