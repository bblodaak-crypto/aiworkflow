extends SceneTree
## Нарезает сгенерированный спрайтшит (сетка на белом или прозрачном фоне) на листы для игры.
##
## Запуск:
##   Godot --headless --path . --script res://tools/slice_sheet.gd --
##       <исходник> <папка_вывода> <конфиг>
##
## Конфиг — JSON, образец — tools/sheets/example_enemy.json.sample. Ожидает по строке
## на анимацию, фигуры разделены пустым фоном. Кадры масштабируются так, чтобы первый
## кадр первой анимации был `target_height` px ростом, и ставятся на холст FRAME × FRAME
## с точкой опоры PIVOT (design/SPRITE_SPEC.md, «Листы кадров»); `pivot_x` в конфиге
## сдвигает опору влево, чтобы оружие в атаке не выходило за холст (AssetRules.MIN_PIVOT_X).
## С `"normalize_height": true` рост каждого кадра анимации приводится к медиане её кадров,
## а `target_height` — медиана первой анимации.
## Для каждой анимации печатается отчёт: рост и x опоры (центр нижней трети силуэта)
## кадров на холсте и их разброс в % медианного роста; у зацикленных анимаций выше
## порогов AssetRules — предупреждение. Рядом с листами пишутся превью на бежевом и тёмном фоне:
## их нужно удалить после проверки.

const AssetRules := preload("res://tools/asset_rules.gd")
const ImageMatte := preload("res://tools/image_matte.gd")

const FRAME := 512
const PIVOT := Vector2(256, 480)
## Насколько пиксель должен отличаться от белого, чтобы считаться фигурой.
const INK_THRESHOLD := 0.12
## Мягкий край альфы: ниже — прозрачно, выше — непрозрачно.
const ALPHA_LOW := 0.03
const ALPHA_HIGH := 0.16
## Минимум пикселей фигуры в строке/столбце и допустимый разрыв внутри фигуры.
const MIN_INK := 3
const MAX_GAP := 6
## Доля высоты сверху, по которой ищется центр капюшона.
const HOOD_SHARE := 0.15
const PREVIEW_BG := Color("ead3a8")
const PREVIEW_DARK_BG := Color("2b2622")

const CROP_PAD := 10

## Поля конфига. matte: threshold — альфа по отличию от белого (исходный способ для героя),
## flood — фон заливкой от края кадра с восстановлением цвета края.
## align: hood — центр капюшона на опоре (тело не «ездит»), center — центр рамки,
## centroid — центр масс фигуры, feet — нижний край силуэта на опоре, x — центр масс
## нижней трети (каждый кадр стоит на своих ногах, без общей линии земли).

var _config: Dictionary
var _pivot := PIVOT


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		push_error("Использование: -- <исходник> <папка_вывода> <конфиг.json>")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[2]))
	if not parsed is Dictionary:
		push_error("Не удалось прочитать конфиг %s" % args[2])
		quit(1)
		return
	_config = parsed
	var anims: Array = _config["anims"]

	var src := Image.load_from_file(ProjectSettings.globalize_path(args[0]))
	src.convert(Image.FORMAT_RGBA8)
	if src.detect_alpha() != Image.ALPHA_NONE:
		src = _over_white(src)
	var out_dir := ProjectSettings.globalize_path(args[1])
	DirAccess.make_dir_recursive_absolute(out_dir)

	var bands := _runs(_row_counts(src, Rect2i(Vector2i.ZERO, src.get_size())))
	if bands.size() != anims.size():
		push_error("Ожидалось строк: %d, найдено: %d" % [anims.size(), bands.size()])
		quit(1)
		return

	var rows: Array[Array] = []
	for i: int in bands.size():
		var band := Rect2i(0, bands[i].x, src.get_width(), bands[i].y - bands[i].x)
		var boxes := _frame_boxes(src, band)
		if boxes.size() != anims[i]["frames"]:
			push_error(
				(
					"%s: ожидалось кадров %d, найдено %d"
					% [anims[i]["name"], anims[i]["frames"], boxes.size()]
				)
			)
			quit(1)
			return
		rows.append(boxes)

	_pivot.x = _config.get("pivot_x", PIVOT.x)
	var base_height: float = rows[0][0].size.y
	if _config.get("normalize_height", false):
		base_height = AssetRules.median(_heights(rows[0]))
	var scale := float(_config["target_height"]) / base_height
	for i: int in rows.size():
		_write_anim(src, rows[i], anims[i], scale, out_dir)
	print("Готово: масштаб %.4f, вывод в %s" % [scale, out_dir])
	quit()


func _write_anim(src: Image, boxes: Array, anim: Dictionary, scale: float, out_dir: String) -> void:
	var count := boxes.size()
	var sheet := Image.create_empty(FRAME * count, FRAME, false, Image.FORMAT_RGBA8)
	var preview := Image.create_empty(FRAME * count, FRAME, false, Image.FORMAT_RGBA8)
	preview.fill(PREVIEW_BG)
	# Общая линия земли строки сохраняет покачивание тела между кадрами.
	var ground := 0
	for box: Rect2i in boxes:
		ground = maxi(ground, box.end.y)
	var heights := _heights(boxes)
	var median_height := AssetRules.median(heights)
	var normalize: bool = _config.get("normalize_height", false)
	var placed_heights := PackedFloat32Array()
	var feet_xs := PackedFloat32Array()
	var bounds := Rect2i(Vector2i.ZERO, src.get_size())

	for i: int in count:
		var box: Rect2i = boxes[i]
		var frame_scale := scale * (median_height / heights[i] if normalize else 1.0)
		var flood: bool = _config["matte"] == "flood"
		var crop_rect := box.grow(CROP_PAD if flood else 3).intersection(bounds)
		var crop := src.get_region(crop_rect)
		var cutout := ImageMatte.flood_cutout(crop) if flood else _ink_alpha(crop)
		var feet := AssetRules.feet_anchor(cutout) + Vector2(crop_rect.position)
		var anchor_x := box.get_center().x as float
		match anim["align"]:
			"hood":
				anchor_x = _hood_center_x(src, box)
			"centroid":
				anchor_x = _centroid_x(src, box)
			"feet":
				anchor_x = feet.x
		var anchor := Vector2(anchor_x, feet.y if anim["align"] == "feet" else float(ground))
		var origin := Vector2i(
			(_pivot + (Vector2(crop_rect.position) - anchor) * frame_scale).round()
		)
		origin.x += FRAME * i
		var clipped := false
		if flood:
			clipped = _place_flood(cutout, crop_rect.size, origin, frame_scale, sheet, i)
		else:
			var scaled_size := Vector2i((Vector2(crop_rect.size) * frame_scale).round())
			crop.resize(scaled_size.x, scaled_size.y, Image.INTERPOLATE_LANCZOS)
			clipped = _blit_cutout(crop, sheet, origin, i)
		if clipped:
			push_warning("%s кадр %d выходит за холст" % [anim["name"], i])
		placed_heights.append(heights[i] * frame_scale)
		feet_xs.append(_pivot.x + (feet.x - anchor.x) * frame_scale)
	_report(anim["name"], placed_heights, feet_xs, anim["loop"])

	var name: String = _config["prefix"] + anim["name"]
	sheet.save_png(out_dir.path_join("%s.png" % name))
	preview.blend_rect(sheet, Rect2i(Vector2i.ZERO, sheet.get_size()), Vector2i.ZERO)
	preview.save_png(out_dir.path_join("%s_preview.png" % name))
	var dark := Image.create_empty(FRAME * count, FRAME, false, Image.FORMAT_RGBA8)
	dark.fill(PREVIEW_DARK_BG)
	dark.blend_rect(sheet, Rect2i(Vector2i.ZERO, sheet.get_size()), Vector2i.ZERO)
	dark.save_png(out_dir.path_join("%s_preview_dark.png" % name))
	var meta := {
		"frame_size": [FRAME, FRAME],
		"frame_count": count,
		"fps": anim["fps"],
		"loop": anim["loop"],
		"pivot": [_pivot.x, _pivot.y],
	}
	var file := FileAccess.open(out_dir.path_join("%s.json" % name), FileAccess.WRITE)
	file.store_string(JSON.stringify(meta, "  ") + "\n")


## Отчёт о кадрах анимации на холсте: рост, x опоры и их разброс.
## Пороги — только для зацикленных анимаций: атака и смерть меняют позу намеренно.
func _report(
	anim_name: String, heights: PackedFloat32Array, feet_xs: PackedFloat32Array, looped: bool
) -> void:
	var base := AssetRules.median(heights)
	var height_spread := AssetRules.spread(heights, base)
	var feet_spread := AssetRules.spread(feet_xs, base)
	print(
		(
			"%s: рост %s, x опоры %s; разброс роста %d %%, опоры %d %%"
			% [
				anim_name,
				_rounded(heights),
				_rounded(feet_xs),
				roundi(height_spread * 100),
				roundi(feet_spread * 100),
			]
		)
	)
	if not looped:
		return
	if height_spread > AssetRules.HEIGHT_SPREAD_MAX or feet_spread > AssetRules.FEET_SPREAD_MAX:
		push_warning(
			(
				"%s: разброс выше порога (рост до %d %%, опора до %d %%)"
				% [
					anim_name,
					roundi(AssetRules.HEIGHT_SPREAD_MAX * 100),
					roundi(AssetRules.FEET_SPREAD_MAX * 100),
				]
			)
		)


func _heights(boxes: Array) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	for box: Rect2i in boxes:
		heights.append(box.size.y)
	return heights


func _rounded(values: PackedFloat32Array) -> String:
	var parts := PackedStringArray()
	for value: float in values:
		parts.append(str(roundi(value)))
	return " ".join(parts)


## Альфа по отличию от белого, как в _blit_cutout: нужна только для поиска опоры.
func _ink_alpha(crop: Image) -> Image:
	var shape := Image.create_empty(crop.get_width(), crop.get_height(), false, Image.FORMAT_RGBA8)
	for y: int in crop.get_height():
		for x: int in crop.get_width():
			var alpha := clampf(
				(ImageMatte.ink(crop.get_pixel(x, y)) - ALPHA_LOW) / (ALPHA_HIGH - ALPHA_LOW),
				0.0,
				1.0
			)
			shape.set_pixel(x, y, Color(0, 0, 0, alpha))
	return shape


## Исходник с прозрачным фоном приводится к белому, чтобы дальше работал один путь обработки.
func _over_white(src: Image) -> Image:
	var flat := Image.create_empty(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	flat.fill(Color.WHITE)
	flat.blend_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), Vector2i.ZERO)
	return flat


## Переносит фигуру с белого фона на прозрачный: альфа по отличию от белого,
## цвет края очищается от примеси белого. Возвращает true, если фигура обрезана.
func _blit_cutout(crop: Image, dest: Image, origin: Vector2i, frame: int) -> bool:
	var clipped := false
	var cell := Rect2i(FRAME * frame, 0, FRAME, FRAME)
	for y: int in crop.get_height():
		for x: int in crop.get_width():
			var c := crop.get_pixel(x, y)
			var alpha := clampf(
				(ImageMatte.ink(c) - ALPHA_LOW) / (ALPHA_HIGH - ALPHA_LOW), 0.0, 1.0
			)
			if alpha <= 0.0:
				continue
			var p := origin + Vector2i(x, y)
			if not cell.has_point(p):
				clipped = true
				continue
			var fg := Color(
				clampf((c.r - (1.0 - alpha)) / alpha, 0.0, 1.0),
				clampf((c.g - (1.0 - alpha)) / alpha, 0.0, 1.0),
				clampf((c.b - (1.0 - alpha)) / alpha, 0.0, 1.0),
				alpha
			)
			dest.set_pixelv(p, dest.get_pixelv(p).blend(fg))
	return clipped


## Матирование flood: кадр, вырезанный с прозрачным фоном в исходном размере,
## масштабируется и ставится на холст. Возвращает true, если фигура обрезана.
func _place_flood(
	cutout: Image, crop_size: Vector2i, origin: Vector2i, scale: float, dest: Image, frame: int
) -> bool:
	var scaled_size := Vector2i((Vector2(crop_size) * scale).round())
	cutout.resize(scaled_size.x, scaled_size.y, Image.INTERPOLATE_LANCZOS)
	var cell := Rect2i(FRAME * frame, 0, FRAME, FRAME)
	var clipped := false
	for y: int in cutout.get_height():
		for x: int in cutout.get_width():
			var c := cutout.get_pixel(x, y)
			var p := origin + Vector2i(x, y)
			if not cell.has_point(p):
				clipped = clipped or c.a > 0.02
				continue
			dest.set_pixelv(p, c)
	return clipped


func _frame_boxes(src: Image, band: Rect2i) -> Array[Rect2i]:
	var boxes: Array[Rect2i] = []
	for run: Vector2i in _runs(_column_counts(src, band)):
		var columns := Rect2i(band.position.x + run.x, band.position.y, run.y - run.x, band.size.y)
		var rows := _runs(_row_counts(src, columns))
		var top := band.position.y + rows[0].x
		var bottom := band.position.y + rows[-1].y
		boxes.append(Rect2i(columns.position.x, top, columns.size.x, bottom - top))
	return boxes


func _hood_center_x(src: Image, box: Rect2i) -> float:
	var rows := int(box.size.y * HOOD_SHARE)
	var sum := 0.0
	var count := 0
	for y: int in range(box.position.y, box.position.y + rows):
		for x: int in range(box.position.x, box.end.x):
			if ImageMatte.ink(src.get_pixel(x, y)) > INK_THRESHOLD:
				sum += x
				count += 1
	return sum / count if count > 0 else box.get_center().x as float


func _centroid_x(src: Image, box: Rect2i) -> float:
	var sum := 0.0
	var count := 0
	for y: int in range(box.position.y, box.end.y):
		for x: int in range(box.position.x, box.end.x):
			if ImageMatte.ink(src.get_pixel(x, y)) > INK_THRESHOLD:
				sum += x
				count += 1
	return sum / count if count > 0 else box.get_center().x as float


func _row_counts(src: Image, rect: Rect2i) -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(rect.size.y)
	for y: int in rect.size.y:
		for x: int in rect.size.x:
			if (
				ImageMatte.ink(src.get_pixel(rect.position.x + x, rect.position.y + y))
				> INK_THRESHOLD
			):
				counts[y] += 1
	return counts


func _column_counts(src: Image, rect: Rect2i) -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(rect.size.x)
	for x: int in rect.size.x:
		for y: int in rect.size.y:
			if (
				ImageMatte.ink(src.get_pixel(rect.position.x + x, rect.position.y + y))
				> INK_THRESHOLD
			):
				counts[x] += 1
	return counts


## Отрезки [начало, конец) с заполненными строками/столбцами; короткие разрывы склеиваются.
## Возвращает координаты относительно начала массива.
func _runs(counts: PackedInt32Array) -> Array[Vector2i]:
	var runs: Array[Vector2i] = []
	var start := -1
	var last := -1
	for i: int in counts.size():
		if counts[i] < MIN_INK:
			continue
		if start >= 0 and i - last > MAX_GAP:
			runs.append(Vector2i(start, last + 1))
			start = -1
		if start < 0:
			start = i
		last = i
	if start >= 0:
		runs.append(Vector2i(start, last + 1))
	return runs
