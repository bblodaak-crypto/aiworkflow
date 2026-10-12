## Проверка готовых ассетов по design/SPRITE_SPEC.md («Общие правила», «Листы кадров»,
## «Окружение»): объект окружения и лист кадров. Возвращает список нарушений; пустой —
## ассет в порядке. Числа из SPRITE_SPEC — в одном месте здесь, рабочие пороги —
## в docs/TUNABLES.md.

const ImageMatte := preload("res://tools/image_matte.gd")

## Прозрачное поле вокруг объекта окружения, px (SPRITE_SPEC, «Окружение», «Холст и точка опоры»).
const PAD := 8
## Допуск поля и опоры, px: округление при масштабировании.
const MARGIN_TOLERANCE := 1
## Кадр листа и точка опоры в кадре (SPRITE_SPEC, «Листы кадров»).
const FRAME := 512
const PIVOT := Vector2(256, 480)
## Опору можно сдвинуть влево до этого x (`pivot_x` конфига нарезки), чтобы оружие
## в атаке врага, смотрящего вправо, не выходило за холст.
const MIN_PIVOT_X := 128.0
## Ореол: полупрозрачный пиксель края почти белого цвета. Альфа считается полупрозрачной
## между HALO_ALPHA_MIN и HALO_ALPHA_MAX, «почти белый» — ink меньше HALO_INK.
const HALO_ALPHA_MIN := 0.1
const HALO_ALPHA_MAX := 0.9
const HALO_INK := 0.08
## Доля светлых среди полупрозрачных пикселей, выше которой край считается с ореолом.
const HALO_MAX_SHARE := 0.15
## Меньше стольких полупрозрачных пикселей — доля не считается (жёсткий край).
const HALO_MIN_EDGE := 20
## Пиксель с альфой выше этой — фигура при поиске опоры кадра.
const FEET_ALPHA := 0.5
## Доля роста фигуры снизу, по центру масс которой ставится x опоры.
const FEET_SHARE := 1.0 / 3.0
## Допустимый разброс роста и x опоры кадров одной анимации — доля медианного роста
## (рабочие значения, docs/TUNABLES.md).
const HEIGHT_SPREAD_MAX := 0.06
const FEET_SPREAD_MAX := 0.08
## Шов плитки земли: насколько разница противоположных краёв (при повторе они встают
## рядом) больше обычной разницы соседних пикселей внутри, в долях цвета 0…1
## (рабочее значение, docs/TUNABLES.md).
const SEAM_MAX := 0.03


## Объект окружения: прозрачное поле PAD со всех сторон, опора — середина нижнего края
## формы, то есть (ширина / 2, высота − PAD): форма по центру и стоит на нижнем поле.
static func check_prop(image: Image) -> Array[String]:
	var problems := _check_alpha(image)
	if not problems.is_empty():
		return problems
	var used := image.get_used_rect()
	if used.size == Vector2i.ZERO:
		return ["пустая картинка"]
	var left := used.position.x
	var top := used.position.y
	var right := image.get_width() - used.end.x
	var bottom := image.get_height() - used.end.y
	if mini(mini(left, right), mini(top, bottom)) < PAD - MARGIN_TOLERANCE:
		problems.append(
			(
				"поле меньше %d px: слева %d, сверху %d, справа %d, снизу %d"
				% [PAD, left, top, right, bottom]
			)
		)
	elif absi(left - right) > MARGIN_TOLERANCE * 2 or absi(bottom - PAD) > MARGIN_TOLERANCE:
		(
			problems
			. append(
				(
					"опора сдвинута: форма не по центру (слева %d, справа %d) или не на нижнем поле (%d)"
					% [left, right, bottom]
				)
			)
		)
	problems.append_array(check_halo(image))
	return problems


## Лист кадров: ширина кратна FRAME, высота FRAME, метаданные с числом кадров и опорой
## (y — как у PIVOT, x — от MIN_PIVOT_X до PIVOT.x).
## `meta` — разобранный JSON рядом с листом или null, если файла нет.
static func check_sheet(image: Image, meta: Variant) -> Array[String]:
	var problems := _check_alpha(image)
	var width := image.get_width()
	if width % FRAME != 0 or image.get_height() != FRAME:
		problems.append(
			(
				"лист %d × %d: нужна ширина кратная %d и высота %d"
				% [width, image.get_height(), FRAME, FRAME]
			)
		)
	if not meta is Dictionary:
		problems.append("нет JSON с метаданными листа")
	else:
		var data: Dictionary = meta
		var frames := floori(width / float(FRAME))
		var count: float = data.get("frame_count", 0.0)
		if count != frames:
			problems.append("frame_count %s, а кадров на листе %d" % [count, frames])
		if _vector(data.get("frame_size")) != Vector2(FRAME, FRAME):
			problems.append(
				"frame_size %s, нужно [%d, %d]" % [data.get("frame_size"), FRAME, FRAME]
			)
		var pivot := _vector(data.get("pivot"))
		if pivot.y != PIVOT.y or pivot.x < MIN_PIVOT_X or pivot.x > PIVOT.x:
			problems.append(
				"pivot %s, нужно [%d…%d, %d]" % [data.get("pivot"), MIN_PIVOT_X, PIVOT.x, PIVOT.y]
			)
	if problems.is_empty():
		problems.append_array(check_halo(image))
	return problems


## Плитка земли: непрозрачная, без шва при повторе (`seam_error` не больше SEAM_MAX).
static func check_tile(image: Image) -> Array[String]:
	if image.detect_alpha() != Image.ALPHA_NONE:
		return ["плитка с прозрачностью: нужна непрозрачная картинка"]
	var error := seam_error(image)
	if error > SEAM_MAX:
		return ["шов при повторе: %.3f, допустимо %.3f" % [error, SEAM_MAX]]
	return []


## Шов плитки: средняя разница пикселей через стык при повторе (правый край — левый,
## нижний — верхний) минус средняя разница соседних пикселей внутри картинки; берётся
## худшее из направлений. У бесшовной плитки около 0, шум текстуры не считается швом.
static func seam_error(image: Image) -> float:
	var width := image.get_width()
	var height := image.get_height()
	if width < 2 or height < 2:
		return 0.0
	var inner_x := 0.0
	var inner_y := 0.0
	for y: int in height:
		for x: int in width - 1:
			inner_x += _color_diff(image.get_pixel(x, y), image.get_pixel(x + 1, y))
	for x: int in width:
		for y: int in height - 1:
			inner_y += _color_diff(image.get_pixel(x, y), image.get_pixel(x, y + 1))
	var seam_x := 0.0
	for y: int in height:
		seam_x += _color_diff(image.get_pixel(width - 1, y), image.get_pixel(0, y))
	var seam_y := 0.0
	for x: int in width:
		seam_y += _color_diff(image.get_pixel(x, height - 1), image.get_pixel(x, 0))
	return maxf(
		seam_x / height - inner_x / (height * (width - 1)),
		seam_y / width - inner_y / (width * (height - 1))
	)


## Белый ореол по краю альфы: доля почти белых среди полупрозрачных пикселей.
static func check_halo(image: Image) -> Array[String]:
	var share := halo_share(image)
	if share > HALO_MAX_SHARE:
		return [
			"светлый ореол по краю: %d %% полупрозрачных пикселей почти белые" % roundi(share * 100)
		]
	return []


static func halo_share(image: Image) -> float:
	var edge := 0
	var light := 0
	for y: int in image.get_height():
		for x: int in image.get_width():
			var c := image.get_pixel(x, y)
			if c.a <= HALO_ALPHA_MIN or c.a >= HALO_ALPHA_MAX:
				continue
			edge += 1
			if ImageMatte.ink(c) < HALO_INK:
				light += 1
	return 0.0 if edge < HALO_MIN_EDGE else float(light) / edge


## Опора кадра по альфе: y — нижний край силуэта (строка под последней строкой фигуры),
## x — центр масс нижней FEET_SHARE силуэта. Пустая картинка — центр нижнего края.
static func feet_anchor(image: Image) -> Vector2:
	var top := -1
	var bottom := -1
	for y: int in image.get_height():
		for x: int in image.get_width():
			if image.get_pixel(x, y).a > FEET_ALPHA:
				if top < 0:
					top = y
				bottom = y
				break
	if top < 0:
		return Vector2(image.get_width() / 2.0, image.get_height())
	var from := bottom + 1 - maxi(1, roundi((bottom + 1 - top) * FEET_SHARE))
	var sum := 0.0
	var count := 0
	for y: int in range(from, bottom + 1):
		for x: int in image.get_width():
			if image.get_pixel(x, y).a > FEET_ALPHA:
				sum += x
				count += 1
	return Vector2(sum / count, bottom + 1)


static func median(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var mid := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return sorted[mid]
	return (sorted[mid - 1] + sorted[mid]) / 2.0


## Разброс значений (максимум − минимум) в долях `base`; 0, если `base` не больше 0.
static func spread(values: PackedFloat32Array, base: float) -> float:
	if values.is_empty() or base <= 0.0:
		return 0.0
	var low := values[0]
	var high := values[0]
	for value: float in values:
		low = minf(low, value)
		high = maxf(high, value)
	return (high - low) / base


static func _color_diff(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0


static func _check_alpha(image: Image) -> Array[String]:
	if image.detect_alpha() == Image.ALPHA_NONE:
		return ["нет прозрачности: нужен PNG RGBA с прозрачным фоном"]
	return []


static func _vector(value: Variant) -> Vector2:
	if not value is Array:
		return -Vector2.ONE
	var items: Array = value
	if items.size() != 2:
		return -Vector2.ONE
	var x: float = items[0]
	var y: float = items[1]
	return Vector2(x, y)
