extends RefCounted
## Удаление белого фона у сгенерированных картинок: общий код инструментов нарезки
## (`slice_sheet.gd`, `slice_props.gd`).

## Матирование flood: фон — почти белые области, связанные с краем кадра, крупные
## замкнутые просветы (между лапами) и мелкие светлые островки у самого фона (в выемках
## шерсти). Светлые места внутри фигуры остаются непрозрачными.
const BG_INK := 0.05
const HOLE_MIN_AREA := 60
const NOTCH_DISTANCE := 3
## Ширина края фигуры, где альфа и цвет восстанавливаются по соседнему цвету тела.
const EDGE_WIDTH := 4
## Сколько пикселей прозрачного поля вокруг фигуры получают цвет тела: без этого
## масштабирование подмешивает белый фон к краю.
const COLOR_BLEED := 8


## Насколько пиксель отличается от белого: 0 — белый, 1 — насыщенный или тёмный.
static func ink(c: Color) -> float:
	return maxf(1.0 - c.r, maxf(1.0 - c.g, 1.0 - c.b))


## Прозрачный фон по маске заливки. Внутри фигуры — исходный цвет; на краю альфа
## считается как доля цвета тела в смеси с белым, а цвет берётся у тела, поэтому
## белого ореола нет ни на светлом, ни на тёмном фоне.
static func flood_cutout(crop: Image) -> Image:
	var w := crop.get_width()
	var h := crop.get_height()
	var background := _background_mask(crop)
	# Расстояние до фона в шагах (до EDGE_WIDTH + 1): край фигуры — первые EDGE_WIDTH.
	var depth := PackedInt32Array()
	depth.resize(w * h)
	depth.fill(EDGE_WIDTH + 1)
	for i: int in w * h:
		if background[i]:
			depth[i] = 0
	for step: int in range(1, EDGE_WIDTH + 1):
		var next := depth.duplicate()
		for y: int in h:
			for x: int in w:
				var i := y * w + x
				if depth[i] > step and _has_neighbor_depth(depth, w, h, x, y, step - 1):
					next[i] = step
		depth = next

	# Цвет тела: ядро фигуры, затем растекание наружу на край и поле вокруг.
	var colors: Array[Color] = []
	colors.resize(w * h)
	var known := PackedByteArray()
	known.resize(w * h)
	for i: int in w * h:
		if depth[i] > EDGE_WIDTH:
			colors[i] = crop.get_pixel(i % w, i / w)
			known[i] = 1
	for pass_index: int in EDGE_WIDTH + COLOR_BLEED:
		var next_known := known.duplicate()
		for y: int in h:
			for x: int in w:
				var i := y * w + x
				if known[i] == 1:
					continue
				var sum := Color(0, 0, 0, 0)
				var n := 0
				for dy: int in range(-1, 2):
					for dx: int in range(-1, 2):
						var nx := x + dx
						var ny := y + dy
						if nx < 0 or ny < 0 or nx >= w or ny >= h:
							continue
						if known[ny * w + nx] == 1:
							sum += colors[ny * w + nx]
							n += 1
				if n > 0:
					colors[i] = sum / n
					next_known[i] = 1
		known = next_known

	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	for y: int in h:
		for x: int in w:
			var i := y * w + x
			var body: Color = colors[i] if known[i] == 1 else Color(0.5, 0.5, 0.5)
			if depth[i] == 0:
				out.set_pixel(x, y, Color(body, 0.0))
			elif depth[i] > EDGE_WIDTH:
				out.set_pixel(x, y, Color(crop.get_pixel(x, y), 1.0))
			else:
				out.set_pixel(x, y, _unmix_edge(crop.get_pixel(x, y), body))
	return out


## Пиксель края = body · a + белый · (1 − a). Альфа — по методу наименьших квадратов
## по трём каналам; цвет — тело, к которому подмешан остаток исходного цвета.
static func _unmix_edge(c: Color, body: Color) -> Color:
	var num := (1.0 - c.r) * (1.0 - body.r) + (1.0 - c.g) * (1.0 - body.g)
	num += (1.0 - c.b) * (1.0 - body.b)
	var den := pow(1.0 - body.r, 2) + pow(1.0 - body.g, 2) + pow(1.0 - body.b, 2)
	var alpha := clampf(num / den, 0.0, 1.0) if den > 0.0001 else 1.0
	if alpha <= 0.0:
		return Color(body, 0.0)
	var own := Color(
		clampf((c.r - (1.0 - alpha)) / alpha, 0.0, 1.0),
		clampf((c.g - (1.0 - alpha)) / alpha, 0.0, 1.0),
		clampf((c.b - (1.0 - alpha)) / alpha, 0.0, 1.0)
	)
	return Color(body.lerp(own, alpha * alpha), alpha)


## Фон: почти белые области, связанные с краем кадра или крупнее HOLE_MIN_AREA.
static func _background_mask(crop: Image) -> PackedByteArray:
	var w := crop.get_width()
	var h := crop.get_height()
	var light := PackedByteArray()
	light.resize(w * h)
	for y: int in h:
		for x: int in w:
			light[y * w + x] = 1 if ink(crop.get_pixel(x, y)) < BG_INK else 0
	var mask := PackedByteArray()
	mask.resize(w * h)
	var seen := PackedByteArray()
	seen.resize(w * h)
	var small: Array[PackedInt32Array] = []
	for start: int in w * h:
		if light[start] == 0 or seen[start] == 1:
			continue
		var region := PackedInt32Array([start])
		seen[start] = 1
		var touches_edge := false
		var head := 0
		while head < region.size():
			var i := region[head]
			head += 1
			var x := i % w
			var y := i / w
			if x == 0 or y == 0 or x == w - 1 or y == h - 1:
				touches_edge = true
			for n: int in [i - 1, i + 1, i - w, i + w]:
				if n < 0 or n >= w * h or seen[n] == 1 or light[n] == 0:
					continue
				if (n == i - 1 and x == 0) or (n == i + 1 and x == w - 1):
					continue
				seen[n] = 1
				region.append(n)
		if touches_edge or region.size() >= HOLE_MIN_AREA:
			for i: int in region:
				mask[i] = 1
		else:
			small.append(region)
	# Мелкий островок у фона — просвет в выемке края, а не светлое место тела.
	for region: PackedInt32Array in small:
		if _near_mask(mask, w, h, region):
			for i: int in region:
				mask[i] = 1
	return mask


static func _near_mask(mask: PackedByteArray, w: int, h: int, region: PackedInt32Array) -> bool:
	for i: int in region:
		for dy: int in range(-NOTCH_DISTANCE, NOTCH_DISTANCE + 1):
			for dx: int in range(-NOTCH_DISTANCE, NOTCH_DISTANCE + 1):
				var nx := i % w + dx
				var ny := i / w + dy
				if nx >= 0 and ny >= 0 and nx < w and ny < h and mask[ny * w + nx] == 1:
					return true
	return false


static func _has_neighbor_depth(
	depth: PackedInt32Array, w: int, h: int, x: int, y: int, value: int
) -> bool:
	for dy: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var nx := x + dx
			var ny := y + dy
			if nx >= 0 and ny >= 0 and nx < w and ny < h and depth[ny * w + nx] == value:
				return true
	return false
