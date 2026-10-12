extends SceneTree
## Проверяет готовые ассеты по design/SPRITE_SPEC.md (tools/asset_rules.gd): объекты
## окружения в assets/environment/, плитки земли в assets/ground/ (без шва) и листы
## кадров в папках assets/enemies/<враг>/.
## Сырые листы генерации в самой assets/enemies/ не проверяются. Печатает нарушения,
## код выхода 1, если они есть.
##
## Запуск: make assets-check
##   Godot --headless --path . --script res://tools/check_assets.gd
##   … -- --tile <png>…  — проверить только эти плитки земли (кандидаты генерации)

const AssetRules := preload("res://tools/asset_rules.gd")

const ENVIRONMENT_DIR := "res://assets/environment"
const ENEMIES_DIR := "res://assets/enemies"
const GROUND_DIR := "res://assets/ground"
## Известные нарушения старых ассетов: путь → причина (то же — в docs/KNOWN_ISSUES.md).
const EXCEPTIONS := {}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "--tile":
		_check_tiles(args.slice(1))
		return
	var problems: Array[String] = []
	var checked := 0
	for path: String in _pngs(ENVIRONMENT_DIR, true):
		problems.append_array(_report(path, AssetRules.check_prop(_load(path))))
		checked += 1
	if DirAccess.dir_exists_absolute(GROUND_DIR):
		for path: String in _pngs(GROUND_DIR, false):
			problems.append_array(_report(path, AssetRules.check_tile(_load(path))))
			checked += 1
	var enemy_dirs := (
		DirAccess.get_directories_at(ENEMIES_DIR)
		if DirAccess.dir_exists_absolute(ENEMIES_DIR)
		else PackedStringArray()
	)
	for folder: String in enemy_dirs:
		for path: String in _pngs(ENEMIES_DIR.path_join(folder), false):
			var meta: Variant = null
			var json := path.get_basename() + ".json"
			if FileAccess.file_exists(json):
				meta = JSON.parse_string(FileAccess.get_file_as_string(json))
			problems.append_array(_report(path, AssetRules.check_sheet(_load(path), meta)))
			checked += 1
	for line: String in problems:
		print(line)
	print("Проверено ассетов: %d, нарушений: %d" % [checked, problems.size()])
	quit(1 if not problems.is_empty() else 0)


func _check_tiles(paths: PackedStringArray) -> void:
	var problems: Array[String] = []
	for path: String in paths:
		var image := _load(path)
		print("%s: шов %.3f" % [path, AssetRules.seam_error(image)])
		problems.append_array(_report(path, AssetRules.check_tile(image)))
	for line: String in problems:
		print(line)
	quit(1 if not problems.is_empty() or paths.is_empty() else 0)


func _report(path: String, found: Array[String]) -> Array[String]:
	var lines: Array[String] = []
	if found.is_empty():
		return lines
	if EXCEPTIONS.has(path):
		print("%s: исключение (%s)" % [path, EXCEPTIONS[path]])
		return lines
	for problem: String in found:
		lines.append("%s: %s" % [path, problem])
	return lines


func _load(path: String) -> Image:
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	image.convert(Image.FORMAT_RGBA8)
	return image


func _pngs(dir_path: String, recursive: bool) -> Array[String]:
	var result: Array[String] = []
	if not DirAccess.dir_exists_absolute(dir_path):
		return result
	if recursive:
		for sub_dir: String in DirAccess.get_directories_at(dir_path):
			result.append_array(_pngs(dir_path.path_join(sub_dir), true))
	for file: String in DirAccess.get_files_at(dir_path):
		if file.get_extension() == "png":
			result.append(dir_path.path_join(file))
	return result
