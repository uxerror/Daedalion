extends GdUnitTestSuite

const Schedule := preload("packet_schedule.gd")
const RELIABLE := MultiplayerPeer.TRANSFER_MODE_RELIABLE
const ORDERED := MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
const UNORDERED := MultiplayerPeer.TRANSFER_MODE_UNRELIABLE


func test_direction_channel_loss_dup_and_poll_clock() -> void:
	var schedule := Schedule.new(2, 1000.0 / 60)
	schedule.configure(1, 1, {"delay_ms": 8, "dup": 1.0})
	schedule.configure(3, 1, {"loss": 1.0})
	var queue := []
	for packet: Array in [[1, 1, UNORDERED, 7], [1, 1, ORDERED, 8], [3, 1, UNORDERED, 9]]:
		schedule.enqueue(packet, 15, queue)
	schedule.enqueue([1, 2, RELIABLE, 10], 15, queue)
	for repeat_poll in 12:
		schedule.poll(15, queue)
	assert_array(queue).contains_exactly([[1, 2, RELIABLE, 10]])
	schedule.poll(16, queue)
	assert_array(queue.slice(1)).contains_exactly(
		[[1, 1, UNORDERED, 7], [1, 1, UNORDERED, 7], [1, 1, ORDERED, 8]]
	)
	assert_float(schedule.mean_delay_ms(1, 1, ORDERED)).is_equal_approx(16.667, 0.001)


func _burst(mode: int) -> Array:
	var options := {"delay_ms": 50, "jitter_ms": 10, "loss": 0.2, "dup": 0.5, "seed": 140}
	var schedule := Schedule.new(2, 1.0, options)
	var queue := []
	for index in 60:
		schedule.enqueue([1, 0, mode, index], 0, queue)
	schedule.poll(39, queue)
	assert_array(queue).is_empty()
	for now in range(40, 61):
		schedule.poll(now, queue)
	return queue.map(func(packet: Array): return packet[3])


func test_seeded_jitter_and_transfer_modes() -> void:
	var reliable := _burst(RELIABLE)
	assert_array(reliable).is_equal(range(60))
	var ordered := _burst(ORDERED)
	assert_array(ordered).is_not_empty()
	for index in range(1, ordered.size()):
		assert_int(ordered[index]).is_greater(ordered[index - 1])
	var unordered := _burst(UNORDERED)
	assert_array(unordered).is_equal(_burst(UNORDERED))
	assert_array(unordered).is_not_equal(reliable)
