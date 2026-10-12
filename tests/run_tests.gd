extends SceneTree
## Headless-раннер: находит tests/**/test_*.gd, вызывает их методы test_*.
## Запуск: make test. Переменная окружения TEST_FILTER оставляет файлы, в пути которых
## есть эта подстрока. Код выхода 1, если есть неудачные тесты или ошибки загрузки.
## Для каждого теста: before_each, тест-метод, after_each (вызывается и после неудач).
## Перед каждым тестом язык — английский: тесты не зависят от языка системы.
## Ошибка движка или скрипта (не предупреждение) во время загрузки файла или теста,
## включая before_each и after_each, — провал этого теста.

const TESTS_DIR := "res://tests"

var _errors := ErrorCollector.new()


func _initialize() -> void:
	OS.add_logger(_errors)
	var passed := 0
	var failed := 0
	var filter := OS.get_environment("TEST_FILTER")
	for path in _find_test_files(TESTS_DIR):
		if not filter.is_empty() and not path.contains(filter):
			continue
		_errors.take()
		var script := load(path) as GDScript
		var load_errors := _errors.take()
		if script == null or not script.can_instantiate() or not load_errors.is_empty():
			print("ОШИБКА  %s: не удалось загрузить" % path)
			_print_lines(load_errors)
			failed += 1
			continue
		for method in script.get_script_method_list():
			var test_name: String = method["name"]
			if not test_name.begins_with("test_"):
				continue
			var test_case := script.new() as TestCase
			if test_case == null:
				print("ОШИБКА  %s: класс должен наследовать TestCase" % path)
				failed += 1
				break
			TranslationServer.set_locale("en")
			test_case.before_each()
			test_case.call(test_name)
			test_case.after_each()
			var problems: Array[String] = test_case.failures.duplicate()
			problems.append_array(_errors.take())
			if problems.is_empty():
				passed += 1
			else:
				failed += 1
				print("ПРОВАЛ  %s::%s" % [path, test_name])
				_print_lines(problems)
	OS.remove_logger(_errors)
	print("Тестов пройдено: %d, провалено: %d" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _find_test_files(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	for sub_dir in DirAccess.get_directories_at(dir_path):
		result.append_array(_find_test_files(dir_path.path_join(sub_dir)))
	for file in DirAccess.get_files_at(dir_path):
		if file.begins_with("test_") and file.ends_with(".gd"):
			result.append(dir_path.path_join(file))
	result.sort()
	return result


func _print_lines(lines: Array[String]) -> void:
	for line in lines:
		print("        %s" % line)


## Собирает ошибки движка и скриптов: без него ошибка в тесте видна только в выводе,
## а сам тест засчитывается пройденным. Логгер вызывается из любого потока.
class ErrorCollector:
	extends Logger

	var _errors: Array[String] = []
	var _mutex := Mutex.new()

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := rationale if not rationale.is_empty() else code
		_mutex.lock()
		_errors.append("ошибка: %s (%s:%d, %s)" % [text, file, line, function])
		_mutex.unlock()

	## Возвращает накопленные ошибки и очищает список.
	func take() -> Array[String]:
		_mutex.lock()
		var result := _errors
		_errors = []
		_mutex.unlock()
		return result
