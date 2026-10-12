extends TestCase
## Проверка самого тестового раннера и проверок TestCase.


func test_passing_assertions_record_no_failures() -> void:
	var probe := TestCase.new()
	probe.assert_true(true)
	probe.assert_false(false)
	probe.assert_eq(2 + 2, 4)
	probe.assert_almost_eq(0.1 + 0.2, 0.3)
	assert_eq(probe.failures.size(), 0)


func test_failing_assertions_are_recorded() -> void:
	var probe := TestCase.new()
	probe.assert_true(false)
	probe.assert_eq(1, 2, "числа")
	assert_eq(probe.failures.size(), 2)
	assert_true(probe.failures[1].begins_with("числа"))


func test_eq_distinguishes_types() -> void:
	var probe := TestCase.new()
	probe.assert_eq(1, 1.0)
	assert_eq(probe.failures.size(), 1)
