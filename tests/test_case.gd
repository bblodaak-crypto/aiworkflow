class_name TestCase
extends RefCounted
## Базовый класс тестов. Методы `test_*` наследника вызывает tests/run_tests.gd.
## Проверка не прерывает тест: все неудачи собираются и выводятся раннером.

var failures: Array[String] = []


## Вызывается перед каждым тест-методом.
func before_each() -> void:
	pass


## Вызывается после каждого тест-метода, даже если в нём были неудачи. Освобождает то,
## что создал before_each (окна, ноды). Ошибки в нём — провал этого же теста.
func after_each() -> void:
	pass


func assert_true(value: bool, message := "") -> void:
	if not value:
		_fail("ожидалось true", message)


func assert_false(value: bool, message := "") -> void:
	if value:
		_fail("ожидалось false", message)


func assert_eq(actual: Variant, expected: Variant, message := "") -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		_fail("ожидалось %s, получено %s" % [var_to_str(expected), var_to_str(actual)], message)


func assert_almost_eq(actual: float, expected: float, tolerance := 0.0001, message := "") -> void:
	if absf(actual - expected) > tolerance:
		_fail("ожидалось %s ± %s, получено %s" % [expected, tolerance, actual], message)


func _fail(reason: String, message: String) -> void:
	failures.append(reason if message.is_empty() else "%s: %s" % [message, reason])
