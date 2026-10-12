extends SceneTree
## Собирает docs/ASSET_CATALOG.md — справочник объектов окружения и врагов, из которого
## выбирают ассеты для локации, не открывая PNG. Объекты — по наборам `tools/props/*.json`
## (сцены из `scene_dir`), персонажи — листы кадров по `tools/sheets/*.json`.
##
## Запуск: make catalog (записать) / make catalog-check (код 1, если файл устарел)
##   Godot --headless --path . --script res://tools/asset_catalog.gd [-- --check]

const PROPS_CONFIG_DIR := "res://tools/props"
const SHEETS_CONFIG_DIR := "res://tools/sheets"
const CATALOG := "res://docs/ASSET_CATALOG.md"
## Поле вокруг объекта окружения, px (tools/slice_props.gd).
const PAD := 8
## Масштаб: 4 px картинки = 1 игровая единица.
const PX_PER_UNIT := 4.0


func _init() -> void:
	var text := build()
	var path := ProjectSettings.globalize_path(CATALOG)
	if "--check" in OS.get_cmdline_user_args():
		var current := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
		if current != text:
			print("docs/ASSET_CATALOG.md устарел. Запустите make catalog.")
			quit(1)
			return
		quit(0)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	print("Записан docs/ASSET_CATALOG.md")
	quit(0)


func build() -> String:
	var lines: Array[String] = [
		"# Каталог ассетов",
		"",
		(
			"Собирается `make catalog` (`tools/asset_catalog.gd`), вручную не править;"
			+ " `make check` падает, если файл устарел. Размеры — в игровых единицах"
			+ " (4 px картинки = 1 ед.; рост героя — 100 ед.), по картинке без прозрачного поля."
		),
		"",
		(
			"Вид объекта: **стоящий** — в общем слое с персонажами, сортируется по y;"
			+ " **наземный** — под персонажами (SPRITE_SPEC, «Окружение»). `lift` — подъём картинки"
			+ " над опорой, ед. (жерди забора висят на столбах)."
		),
		"",
		"## Объекты окружения",
	]
	for config_path: String in _files(PROPS_CONFIG_DIR, "json"):
		lines.append_array(_props_section(config_path))
	lines.append_array(_enemies_section())
	return "\n".join(lines) + "\n"


func _props_section(config_path: String) -> Array[String]:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	var scene_dir: String = config["scene_dir"]
	var lines: Array[String] = [
		"",
		"### %s" % config_path.get_file().get_basename(),
		"",
		(
			"Конфиг нарезки — `%s`, сцены — `%s/<объект>.tscn`."
			% [_short(config_path), _short(scene_dir)]
		),
		"",
		"| Объект | Вид | Ширина × высота | lift |",
		"| --- | --- | --- | --- |",
	]
	for sheet: Dictionary in config["sheets"]:
		for prop: Dictionary in sheet["props"]:
			var name: String = prop["name"]
			lines.append(_prop_row(name, scene_dir.path_join(name + ".tscn")))
	return lines


func _prop_row(name: String, scene_path: String) -> String:
	if not ResourceLoader.exists(scene_path):
		return "| %s | нет сцены | — | — |" % name
	var node := (load(scene_path) as PackedScene).instantiate()
	var sprite := node.get_node("Sprite") as Sprite2D
	var size := (sprite.texture.get_size() - Vector2.ONE * PAD * 2) * sprite.scale
	var kind := "наземный" if sprite.z_index < 0 else "стоящий"
	var lift := -sprite.position.y
	node.free()
	return (
		"| %s | %s | %d × %d | %s |" % [name, kind, roundi(size.x), roundi(size.y), _number(lift)]
	)


func _enemies_section() -> Array[String]:
	var lines: Array[String] = [
		"",
		"## Персонажи и враги",
		"",
		"Листы кадров по конфигам `tools/sheets/`; рост — `target_height` листа в единицах.",
		"Числа врагов и где они появляются — решения пользователя.",
		"",
		"| Конфиг | Листы | Рост | Анимации (кадры) |",
		"| --- | --- | --- | --- |",
	]
	for config_path: String in _files(SHEETS_CONFIG_DIR, "json"):
		var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		var anims: Array[String] = []
		for anim: Dictionary in config["anims"]:
			anims.append("%s %d" % [anim["name"], int(anim["frames"])])
		var target: float = config["target_height"]
		(
			lines
			. append(
				(
					"| `%s` | `%s` | %d | %s |"
					% [
						_short(config_path),
						_short(String(config.get("sheet_dir", "—"))),
						roundi(target / PX_PER_UNIT),
						", ".join(anims),
					]
				)
			)
		)
	return lines


func _files(dir_path: String, extension: String) -> Array[String]:
	var result: Array[String] = []
	for file: String in DirAccess.get_files_at(dir_path):
		if file.get_extension() == extension:
			result.append(dir_path.path_join(file))
	result.sort()
	return result


func _short(path: String) -> String:
	return path.trim_prefix("res://")


func _number(value: float) -> String:
	return "—" if is_zero_approx(value) else str(roundi(value))
