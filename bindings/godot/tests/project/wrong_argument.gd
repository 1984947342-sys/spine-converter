extends SceneTree
## A wrong argument type fails the call with a script error instead of crashing


func _init() -> void:
	call_wrong()
	print("after the wrong argument")
	quit(0)


func call_wrong() -> void:
	var value = 42
	SpineConverter.convert(value)
