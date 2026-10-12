## Раскладка куска локации (`LocationChunk`) в JSON: проверка, текст сцены и обратный
## перевод из готового куска. Формат:
##   {"size": 1200, "props": [{"scene": "barrel", "x": 890, "y": 565, "flip": true}, …]}
## `scene` — имя сцены объекта в `PROPS_DIR` или полный путь `res://…tscn`; `x`, `y` —
## опора объекта в куске; `flip` (необязательно) — отражение по горизонтали.
## Узел объекта зовётся по сцене: `fence_post_tall` → FencePostTall1, FencePostTall2…

const PROPS_DIR := "res://src/scenes/locations/props"
const CHUNK_SCRIPT := "res://src/scenes/locations/location_chunk.gd"
## Сторона куска по умолчанию (`LocationChunk.size`); в сцену пишется, только если другая.
const DEFAULT_SIZE := 1200.0
## Опоры двух объектов не ближе этого, ед. Столб и секция забора стоят через ~64
## (SPRITE_SPEC, «Окружение», «Стыковка забора»). Рабочее значение — docs/TUNABLES.md.
const MIN_GAP := 40.0


## Нарушения раскладки; пустой список — кусок можно собирать.
static func validate(layout: Dictionary) -> Array[String]:
	var size: float = layout["size"] if _is_number(layout.get("size")) else 0.0
	if size <= 0.0:
		return ["size: нужно положительное число"]
	if not layout.get("props") is Array:
		return ["props: нужен массив объектов"]
	var props: Array = layout["props"]
	var problems: Array[String] = []
	var names := node_names(layout)
	var anchors: Array[Vector2] = []
	for i: int in props.size():
		anchors.append(Vector2.INF)
		if not props[i] is Dictionary or not (props[i] as Dictionary).get("scene") is String:
			problems.append("props[%d]: нужен объект с полем scene" % i)
			continue
		var prop: Dictionary = props[i]
		var scene: String = prop["scene"]
		var label := "%s (%s)" % [names[i], scene]
		if not ResourceLoader.exists(scene_path(scene)):
			problems.append("%s: нет сцены %s" % [label, scene_path(scene)])
		if not _is_number(prop.get("x")) or not _is_number(prop.get("y")):
			problems.append("%s: x и y — числа" % label)
			continue
		if prop.has("flip") and not prop["flip"] is bool:
			problems.append("%s: flip — true или false" % label)
		var anchor := Vector2(prop["x"], prop["y"])
		if not Rect2(0, 0, size, size).has_point(anchor):
			problems.append("%s: опора %s вне куска %s" % [label, anchor, _num(size)])
		for j: int in i:
			if anchors[j].distance_to(anchor) < MIN_GAP:
				problems.append("%s: ближе %s ед. к %s" % [label, _num(MIN_GAP), names[j]])
		anchors[i] = anchor
	return problems


## Полный путь сцены объекта по полю `scene`.
static func scene_path(scene: String) -> String:
	return scene if scene.begins_with("res://") else PROPS_DIR.path_join(scene + ".tscn")


## Имена узлов объектов по порядку: имя сцены в PascalCase и номер среди одинаковых.
static func node_names(layout: Dictionary) -> Array[String]:
	var names: Array[String] = []
	var counts := {}
	for prop: Variant in layout.get("props", []):
		var base := "Prop"
		if prop is Dictionary and prop.get("scene") is String:
			base = scene_path(prop["scene"]).get_file().get_basename().to_pascal_case()
		counts[base] = counts.get(base, 0) + 1
		names.append("%s%d" % [base, counts[base]])
	return names


## Текст сцены куска; раскладка должна пройти `validate`.
static func to_scene_text(layout: Dictionary, root_name: String) -> String:
	var lines: Array[String] = [
		"[gd_scene format=3]",
		"",
		'[ext_resource type="Script" path="%s" id="chunk"]' % CHUNK_SCRIPT,
	]
	var ids: Array[String] = []
	for prop: Dictionary in layout["props"]:
		var path := scene_path(prop["scene"])
		var id := path.get_file().get_basename()
		if id not in ids:
			ids.append(id)
			lines.append('[ext_resource type="PackedScene" path="%s" id="%s"]' % [path, id])
	lines.append_array(["", '[node name="%s" type="Node2D"]' % root_name, "y_sort_enabled = true"])
	lines.append('script = ExtResource("chunk")')
	if float(layout["size"]) != DEFAULT_SIZE:
		lines.append("size = %s" % _float(layout["size"]))
	var names := node_names(layout)
	for i: int in names.size():
		var prop: Dictionary = layout["props"][i]
		var id := scene_path(prop["scene"]).get_file().get_basename()
		(
			lines
			. append_array(
				[
					"",
					'[node name="%s" parent="." instance=ExtResource("%s")]' % [names[i], id],
					"position = Vector2(%s, %s)" % [_num(prop["x"]), _num(prop["y"])],
				]
			)
		)
		if prop.get("flip", false):
			lines.append("scale = Vector2(-1, 1)")
	return "\n".join(lines) + "\n"


## Раскладка из готового куска. Ошибка, если узел не объект из сцены, повёрнут,
## масштабирован или назван не по правилу `node_names` — такой кусок JSON не передаст.
static func from_chunk(chunk: Node) -> Dictionary:
	var props: Array = []
	var problems: Array[String] = []
	for child: Node in chunk.get_children():
		var node := child as Node2D
		if node == null or node.scene_file_path.is_empty():
			problems.append("%s: не объект из сцены" % child.name)
			continue
		var path := node.scene_file_path
		var prop := {
			"scene": path.get_file().get_basename() if path.get_base_dir() == PROPS_DIR else path,
			"x": node.position.x,
			"y": node.position.y,
		}
		if node.scale == Vector2(-1, 1):
			prop["flip"] = true
		elif node.scale != Vector2.ONE or node.rotation != 0.0:
			problems.append("%s: поворот или масштаб, кроме flip" % node.name)
		props.append(prop)
	var layout := {"size": chunk.get("size"), "props": props}
	var names := node_names(layout)
	for i: int in mini(names.size(), chunk.get_child_count()):
		if problems.is_empty() and names[i] != chunk.get_child(i).name:
			problems.append("%s: имя не по сцене, ждём %s" % [chunk.get_child(i).name, names[i]])
	return {"layout": layout, "problems": problems}


## JSON раскладки: объект — одна строка, чтобы раскладку было легко читать и править.
static func to_json_text(layout: Dictionary) -> String:
	var rows: Array[String] = []
	for prop: Dictionary in layout["props"]:
		var row := (
			'{"scene": "%s", "x": %s, "y": %s' % [prop["scene"], _num(prop["x"]), _num(prop["y"])]
		)
		if prop.get("flip", false):
			row += ', "flip": true'
		rows.append("\t\t" + row + "}")
	return '{\n\t"size": %s,\n\t"props": [\n%s\n\t]\n}\n' % [_num(layout["size"]), ",\n".join(rows)]


static func _is_number(value: Variant) -> bool:
	return value is float or value is int


## Число как в сцене Godot: целое без дробной части.
static func _num(value: float) -> String:
	return str(int(value)) if value == floorf(value) else str(value)


## Свойство float в сцене Godot: целое с «.0».
static func _float(value: float) -> String:
	return _num(value) + (".0" if value == floorf(value) else "")
