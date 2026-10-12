extends SceneTree
## Нарезает концепт-листы окружения (сетка объектов на белом фоне) на отдельные спрайты
## и создаёт сцену на каждый объект (design/SPRITE_SPEC.md, «Окружение»).
##
## Запуск:
##   Godot --headless --path . --script res://tools/slice_props.gd -- <конфиг> [превью.png]
## Превью — путь res://… (работает и на Windows, где путь из Git Bash Godot не понимает).
##
## Конфиг — JSON, образец — tools/props/example.json.sample. Объекты листа разделены
## пустым фоном: сначала ищутся ряды, затем объекты в ряду слева направо; `cell` — номер объекта
## в этом порядке (ряд · columns + место в ряду). Отдельные части одного объекта
## (жерди забора, колья, кости) собираются в один объект. Фон удаляется, картинка
## масштабируется на `scale` и обрезается по объекту с полем PAD. Точка опоры — середина
## нижнего края объекта. Сцена объекта пишется, только если её ещё нет: правки
## в редакторе не затираются. Превью — все объекты рядом с фигурой героя
## на цвете земли, для проверки масштаба; в проект его не класть.

const ImageMatte := preload("res://tools/image_matte.gd")

## Поле вокруг объекта в итоговой картинке, px.
const PAD := 8
const CROP_PAD := 10
const INK_THRESHOLD := 0.12
## Пятна меньше этого числа пикселей — шум генерации.
const MIN_BLOB := 30
## Масштаб вывода в игре: 4 px исходника = 1 игровая единица.
const SPRITE_SCALE := 0.25
## Радиус тени по умолчанию — доля ширины объекта.
const SHADOW_SHARE := 0.42
const SHADOW_SCRIPT := "res://src/scenes/common/ground_shadow.gd"
const PREVIEW_BG := Color("ead3a8")
## Картинка героя для сравнения роста (кадр 512 × 512, опора внизу); если её нет —
## серый силуэт ростом HERO_HEIGHT.
const PREVIEW_HERO := "res://design/reference/scale_figure.png"
const HERO_FRAME := Rect2i(0, 0, 512, 512)
const HERO_HEIGHT := 400
const PREVIEW_ROW := 2400


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args.size() > 2:
		push_error("Использование: -- <конфиг.json> [превью.png]")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not parsed is Dictionary:
		push_error("Не удалось прочитать конфиг %s" % args[0])
		quit(1)
		return
	var config: Dictionary = parsed
	var sprites: Array[Image] = []
	for sheet: Dictionary in config["sheets"]:
		var src := Image.load_from_file(ProjectSettings.globalize_path(sheet["source"]))
		src.convert(Image.FORMAT_RGBA8)
		var boxes := _object_boxes(src, int(sheet["columns"]), int(sheet["rows"]))
		if boxes.is_empty():
			push_error("%s: число объектов не совпадает с сеткой" % sheet["source"])
			quit(1)
			return
		for prop: Dictionary in sheet["props"]:
			var sprite := _cut(src, boxes[int(prop["cell"])], float(prop.get("scale", 1.0)))
			var png := "%s/%s/%s.png" % [config["asset_dir"], prop["folder"], prop["name"]]
			DirAccess.make_dir_recursive_absolute(
				ProjectSettings.globalize_path(png.get_base_dir())
			)
			sprite.save_png(ProjectSettings.globalize_path(png))
			_write_scene(config["scene_dir"], prop, png, sprite.get_size())
			sprites.append(sprite)
	if args.size() == 2:
		_write_preview(sprites, ProjectSettings.globalize_path(args[1]))
	print("Готово: объектов %d" % sprites.size())
	quit()


## Рамки объектов в порядке рядов; пустой массив, если раскладка не columns × rows.
## Пятна раскладываются по рядам по самым большим промежуткам между их центрами,
## внутри ряда — по самым большим промежуткам по горизонтали: ряды на листах стоят
## плотно, а части одного объекта (жерди, колья) разделены пустым фоном.
func _object_boxes(src: Image, columns: int, rows: int) -> Array[Rect2i]:
	var boxes: Array[Rect2i] = []
	var blobs := _blobs(src)
	if blobs.size() < columns * rows:
		push_error("Пятен %d, меньше объектов %d" % [blobs.size(), columns * rows])
		return boxes
	blobs.sort_custom(
		func(a: Rect2i, b: Rect2i) -> bool: return a.get_center().y < b.get_center().y
	)
	var center_gaps: Array[float] = [0.0]
	for i: int in range(1, blobs.size()):
		center_gaps.append(blobs[i].get_center().y - blobs[i - 1].get_center().y)
	for row: Array[Rect2i] in _split(blobs, center_gaps, rows):
		row.sort_custom(func(a: Rect2i, b: Rect2i) -> bool: return a.position.x < b.position.x)
		# Промежуток перед пятном — от правого края всех пятен левее него.
		var gaps: Array[float] = [0.0]
		var right := row[0].end.x
		for i: int in range(1, row.size()):
			gaps.append(row[i].position.x - right)
			right = maxi(right, row[i].end.x)
		var groups := _split(row, gaps, columns)
		if groups.size() != columns:
			push_error("В ряду меньше объектов, чем %d" % columns)
			return []
		for group: Array[Rect2i] in groups:
			var box: Rect2i = group[0]
			for blob: Rect2i in group:
				box = box.merge(blob)
			boxes.append(box)
	return boxes


## Делит упорядоченные элементы на `parts` групп по самым большим значениям `gaps`:
## `gaps[i]` — промежуток перед элементом i.
func _split(items: Array[Rect2i], gaps: Array[float], parts: int) -> Array[Array]:
	var order: Array[int] = []
	for i: int in range(1, items.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return gaps[a] > gaps[b])
	var cuts := order.slice(0, parts - 1)
	cuts.sort()
	var groups: Array[Array] = []
	var start := 0
	for cut: int in cuts + [items.size()]:
		var group: Array[Rect2i] = []
		group.assign(items.slice(start, cut))
		if not group.is_empty():
			groups.append(group)
		start = cut
	return groups


## Рамки связных пятен фигуры; пятна меньше MIN_BLOB пикселей — шум.
func _blobs(src: Image) -> Array[Rect2i]:
	var w := src.get_width()
	var h := src.get_height()
	var ink := PackedByteArray()
	ink.resize(w * h)
	for y: int in h:
		for x: int in w:
			ink[y * w + x] = 1 if ImageMatte.ink(src.get_pixel(x, y)) > INK_THRESHOLD else 0
	var blobs: Array[Rect2i] = []
	var queue := PackedInt32Array()
	for start: int in w * h:
		if ink[start] == 0:
			continue
		ink[start] = 0
		queue.clear()
		queue.append(start)
		var head := 0
		var min_p := Vector2i(start % w, start / w)
		var max_p := min_p
		while head < queue.size():
			var i := queue[head]
			head += 1
			var p := Vector2i(i % w, i / w)
			min_p = min_p.min(p)
			max_p = max_p.max(p)
			for n: int in [i - 1, i + 1, i - w, i + w]:
				if n < 0 or n >= w * h or ink[n] == 0:
					continue
				if (n == i - 1 and p.x == 0) or (n == i + 1 and p.x == w - 1):
					continue
				ink[n] = 0
				queue.append(n)
		if queue.size() >= MIN_BLOB:
			blobs.append(Rect2i(min_p, max_p - min_p + Vector2i.ONE))
	return blobs


## Объект с прозрачным фоном, в масштабе `scale`, обрезанный по альфе с полем PAD.
func _cut(src: Image, box: Rect2i, scale: float) -> Image:
	var crop_rect := box.grow(CROP_PAD).intersection(Rect2i(Vector2i.ZERO, src.get_size()))
	var cutout := ImageMatte.flood_cutout(src.get_region(crop_rect))
	var scaled := Vector2i((Vector2(crop_rect.size) * scale).round())
	cutout.resize(scaled.x, scaled.y, Image.INTERPOLATE_LANCZOS)
	var used := cutout.get_used_rect()
	var out := Image.create_empty(
		used.size.x + PAD * 2, used.size.y + PAD * 2, false, Image.FORMAT_RGBA8
	)
	out.blit_rect(cutout, used, Vector2i(PAD, PAD))
	return out


## Сцена объекта: тень под ним и спрайт, опора — середина нижнего края объекта.
## `lift` поднимает картинку над опорой (жерди забора висят на столбах).
func _write_scene(scene_dir: String, prop: Dictionary, png: String, size: Vector2i) -> void:
	var path := "%s/%s.tscn" % [scene_dir, prop["name"]]
	if FileAccess.file_exists(path):
		print("%s уже есть, не перезаписывается" % path)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(scene_dir))
	var width_units := (size.x - PAD * 2) * SPRITE_SCALE
	var shadow := float(prop.get("shadow", width_units * SHADOW_SHARE))
	var lift := float(prop.get("lift", 0.0))
	var lines := PackedStringArray(
		[
			"[gd_scene format=3]",
			"",
			'[ext_resource type="Script" path="%s" id="1"]' % SHADOW_SCRIPT,
			'[ext_resource type="Texture2D" path="%s" id="2"]' % png,
			"",
			'[node name="%s" type="Node2D"]' % String(prop["name"]).to_pascal_case(),
			"",
			'[node name="Shadow" type="Node2D" parent="."]',
			"z_index = -1",
			'script = ExtResource("1")',
			"radius = %.1f" % shadow,
			"",
			'[node name="Sprite" type="Sprite2D" parent="."]',
		]
	)
	if lift != 0.0:
		lines.append("position = Vector2(0, %.1f)" % -lift)
	(
		lines
		. append_array(
			[
				"scale = Vector2(%s, %s)" % [SPRITE_SCALE, SPRITE_SCALE],
				'texture = ExtResource("2")',
				"centered = false",
				"offset = Vector2(%d, %d)" % [-size.x / 2, -(size.y - PAD)],
				"",
			]
		)
	)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines))


## Все объекты в ряд по опоре, слева — кадр героя для сравнения роста.
func _write_preview(sprites: Array[Image], path: String) -> void:
	var items: Array[Image] = [_hero_figure()]
	items.append_array(sprites)
	var rows: Array[Array] = [[]]
	var width := 0
	for item: Image in items:
		if width + item.get_width() > PREVIEW_ROW and not rows[-1].is_empty():
			rows.append([])
			width = 0
		rows[-1].append(item)
		width += item.get_width()
	var row_height := 620
	var canvas := Image.create_empty(
		PREVIEW_ROW, row_height * rows.size(), false, Image.FORMAT_RGBA8
	)
	canvas.fill(PREVIEW_BG)
	for r: int in rows.size():
		var x := 0
		var ground := row_height * (r + 1) - 40
		for item: Image in rows[r]:
			canvas.blend_rect(
				item,
				Rect2i(Vector2i.ZERO, item.get_size()),
				Vector2i(x, ground - item.get_height())
			)
			x += item.get_width()
	canvas.save_png(path)


func _hero_figure() -> Image:
	var path := ProjectSettings.globalize_path(PREVIEW_HERO)
	if FileAccess.file_exists(path):
		var hero := Image.load_from_file(path)
		hero.convert(Image.FORMAT_RGBA8)
		return hero.get_region(HERO_FRAME)
	var figure := Image.create_empty(
		HERO_FRAME.size.x, HERO_FRAME.size.y, false, Image.FORMAT_RGBA8
	)
	var width := HERO_HEIGHT / 3
	var body := Rect2i(
		(HERO_FRAME.size.x - width) / 2, HERO_FRAME.size.y - 32 - HERO_HEIGHT, width, HERO_HEIGHT
	)
	figure.fill_rect(body, Color(0.35, 0.38, 0.4, 0.85))
	return figure
