## An abstract flag group. Used for SingleFlagGroup and MultiFlagGroup
@abstract @tool
extends Resource
class_name CogitoFlagGroup

@abstract
func get_flag_names() -> Array[String]

@abstract
func get_numeric_descriptions(quest_flags: Dictionary) -> Array[String]

@abstract
func meets_criteria(quest_flags: Dictionary) -> bool
