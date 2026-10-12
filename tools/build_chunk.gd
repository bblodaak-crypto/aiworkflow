extends SceneTree
## Собирает сцену куска локации из JSON-раскладки (tools/chunk_layout.gd) или пишет
## раскладку из готового куска. Раскладка `tools/chunks/<локация>/<кусок>.json` ↔ сцена
## `src/scenes/locations/<локация>/<кусок>.tscn`. Сцена куска при сборке перезаписывается:
## источник — JSON; правку в редакторе вернуть в JSON через --export.
## Нарушения раскладки печатаются, код выхода 1, сцена не пишется.
##
## Запуск:
##   Godot --headless --path . --script res://tools/build_chunk.gd -- <раскладка.json> …
##   … -- --export src/scenes/locations/<локация>/chunk_a.tscn …

const ChunkLayout := preload("res://tools/chunk_layout.gd")

const CHUNKS_DIR := "res://tools/chunks"
const LOCATIONS_DIR := "res://src/scenes/locations"


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var export := not args.is_empty() and args[0] == "--export"
	if export:
		args = args.slice(1)
	if args.is_empty():
		print("Нужны пути к раскладкам JSON или --export и пути к сценам кусков.")
		quit(1)
		return
	var failed := false
	for arg: String in args:
		var path := arg if arg.begins_with("res://") else "res://" + arg
		var problems := _export(path) if export else _build(path)
		for problem: String in problems:
			print("%s: %s" % [path, problem])
		failed = failed or not problems.is_empty()
	quit(1 if failed else 0)


func _build(json_path: String) -> Array[String]:
	if not json_path.begins_with(CHUNKS_DIR + "/"):
		return ["раскладка должна лежать в %s/<локация>/" % CHUNKS_DIR]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if not parsed is Dictionary:
		return ["не JSON-объект"]
	var layout: Dictionary = parsed
	var problems := ChunkLayout.validate(layout)
	if not problems.is_empty():
		return problems
	var scene_path := LOCATIONS_DIR.path_join(
		json_path.trim_prefix(CHUNKS_DIR + "/").get_basename() + ".tscn"
	)
	var root_name := scene_path.get_file().get_basename().to_pascal_case()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(scene_path.get_base_dir()))
	_write(scene_path, ChunkLayout.to_scene_text(layout, root_name))
	print("Собран %s" % scene_path)
	return []


func _export(scene_path: String) -> Array[String]:
	if not scene_path.begins_with(LOCATIONS_DIR + "/") or not ResourceLoader.exists(scene_path):
		return ["нет сцены куска в %s/<локация>/" % LOCATIONS_DIR]
	var chunk := (load(scene_path) as PackedScene).instantiate()
	var result := ChunkLayout.from_chunk(chunk)
	chunk.free()
	var problems: Array[String] = result["problems"]
	if not problems.is_empty():
		return problems
	var json_path := CHUNKS_DIR.path_join(
		scene_path.trim_prefix(LOCATIONS_DIR + "/").get_basename() + ".json"
	)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(json_path.get_base_dir()))
	var layout: Dictionary = result["layout"]
	_write(json_path, ChunkLayout.to_json_text(layout))
	print("Записана %s" % json_path)
	return []


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
