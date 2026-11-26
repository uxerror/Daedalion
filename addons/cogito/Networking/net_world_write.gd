extends RefCounted
## One isolated publication. The owner reaps it on the main thread before starting another.

const Files := preload("../SceneManagement/cogito_world_files.gd")

var batch: Dictionary
var move: PackedStringArray
var result := OK
var elapsed_usec := 0
var _files: Files
var _task := -1
var _retired := false
var _callback_ran := false


func _init(files: Files, snapshot: Dictionary, rebind: PackedStringArray) -> void:
	_files = files
	batch = snapshot
	move = rebind


## Run the encoder, disk staging and verification on a worker. No live nodes cross threads.
func start() -> void:
	_task = WorkerThreadPool.add_task(_write)


func _write() -> void:
	var started := Time.get_ticks_usec()
	result = _files.publish(batch, not move.is_empty())
	elapsed_usec = Time.get_ticks_usec() - started
	# Keep the claim and job alive if a timed-out shutdown released its session.
	_release_if_retired.call_deferred(self)


func _release_if_retired(_keep_alive: RefCounted) -> void:
	_callback_ran = true
	if _retired and _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_files.close()


## Poll without blocking gameplay. Shutdown can supply an absolute monotonic deadline.
func join(deadline := 0) -> bool:
	while not WorkerThreadPool.is_task_completed(_task):
		if Time.get_ticks_msec() >= deadline:
			return false
		OS.delay_msec(1)
	WorkerThreadPool.wait_for_task_completion(_task)
	return true


## The worker keeps its claim until it finishes, even when orderly shutdown timed out.
func retire() -> void:
	_retired = true
	if _callback_ran or WorkerThreadPool.is_task_completed(_task):
		_release_if_retired(self)
